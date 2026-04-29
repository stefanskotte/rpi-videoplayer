#!/usr/bin/env python3
"""
player.py - Endless loop video player controller.
Uses a single persistent mpv process with IPC socket for seamless transitions.
No process restarts between videos = no console flicker between clips.
"""

import sys
import json
import time
import socket
import signal
import subprocess
import threading
import logging
import tempfile
import os
from pathlib import Path
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler

VIDEO_DIR     = Path("/opt/videoplayer/videos")
PLACEHOLDER   = Path("/opt/videoplayer/web/static/placeholder.jpg")
SPLASH_FILE   = Path("/opt/videoplayer/web/static/splash.jpg")
LOG_FILE      = Path("/opt/videoplayer/logs/player.log")
RELOAD_FLAG   = Path("/opt/videoplayer/.reload")
SKIP_FLAG     = Path("/opt/videoplayer/.skip")
PAUSE_FLAG    = Path("/opt/videoplayer/.pause")
STOP_FLAG     = Path("/opt/videoplayer/.stop")
STATE_FILE    = Path("/opt/videoplayer/state.json")
ORDER_FILE    = Path("/opt/videoplayer/playlist_order.json")
SETTINGS_FILE = Path("/opt/videoplayer/settings.json")
MPV_SOCKET    = Path("/tmp/mpv-videoplayer.sock")
PLAYLIST_FILE = Path("/tmp/mpv-playlist.m3u")
SUPPORTED_EXT = {".mp4", ".mkv", ".avi", ".mov", ".webm", ".ts", ".m4v"}


def detect_drm_card() -> str:
    """Pick the DRM card whose connector is actually connected.

    The model-based heuristic (Pi 5 → card1, otherwise card0) is unreliable
    on Trixie / kernel 6.12+, where the v3d (GPU) device may enumerate as
    card0 and the vc4 display controller as card1 even on a Pi 4. Probe
    /sys/class/drm for a connected connector and use that card; fall back
    to the legacy heuristic only if probing yields nothing.
    """
    drm = Path("/sys/class/drm")
    if drm.is_dir():
        for status_file in sorted(drm.glob("card*-*/status")):
            try:
                if status_file.read_text().strip() == "connected":
                    # e.g. /sys/class/drm/card1-HDMI-A-2 → /dev/dri/card1
                    card_name = status_file.parent.name.split("-", 1)[0]
                    dev = Path("/dev/dri") / card_name
                    if dev.exists():
                        return str(dev)
            except Exception:
                continue
    try:
        model = Path("/proc/device-tree/model").read_text()
        card = "/dev/dri/card1" if "Raspberry Pi 5" in model else "/dev/dri/card0"
    except Exception:
        card = "/dev/dri/card0"
    if not Path(card).exists():
        for fallback in ["/dev/dri/card0", "/dev/dri/card1"]:
            if Path(fallback).exists():
                card = fallback
                break
    return card


DRM_CARD = detect_drm_card()

LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.FileHandler(LOG_FILE), logging.StreamHandler(sys.stdout)]
)
log = logging.getLogger("player")

mpv_proc     = None
stop_event   = threading.Event()
reload_event = threading.Event()
skip_event   = threading.Event()
paused       = False
user_stopped = False  # True after Stop — stay on splash until Restart/Skip
paused_lock  = threading.Lock()

# ── State file ────────────────────────────────────────────────────────────────

def get_rotation() -> int:
    """Read display rotation from settings.json (0/90/180/270)."""
    try:
        s = json.loads(SETTINGS_FILE.read_text())
        r = int(s.get("rotation", 0))
        return r if r in (0, 90, 180, 270) else 0
    except Exception:
        return 0


def write_state(video, status):
    try:
        STATE_FILE.write_text(json.dumps({
            "now_playing": video,
            "status": status,
            "ts": time.time()
        }))
    except Exception:
        pass


def read_state():
    try:
        return json.loads(STATE_FILE.read_text())
    except Exception:
        return {"now_playing": None, "status": "idle", "ts": 0}


# ── Playlist ──────────────────────────────────────────────────────────────────

def get_playlist():
    VIDEO_DIR.mkdir(parents=True, exist_ok=True)
    files = {p.name: p for p in VIDEO_DIR.iterdir() if p.suffix.lower() in SUPPORTED_EXT}
    order = []
    if ORDER_FILE.exists():
        try:
            order = json.loads(ORDER_FILE.read_text())
        except Exception:
            order = []
    result, seen = [], set()
    for name in order:
        if name in files:
            result.append(files[name])
            seen.add(name)
    for name in sorted(files):
        if name not in seen:
            result.append(files[name])
    return result


def write_playlist_file(playlist):
    """Write an m3u playlist file for mpv to load."""
    with open(PLAYLIST_FILE, "w") as f:
        for p in playlist:
            f.write(str(p) + "\n")


# ── mpv IPC ───────────────────────────────────────────────────────────────────

def mpv_command(*args):
    """Send a JSON IPC command to the running mpv process."""
    if not MPV_SOCKET.exists():
        return None
    try:
        cmd = json.dumps({"command": list(args)}) + "\n"
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(2)
            s.connect(str(MPV_SOCKET))
            s.sendall(cmd.encode())
            resp = s.recv(4096).decode().strip()
            return json.loads(resp.split("\n")[0]) if resp else None
    except Exception:
        return None


def mpv_get(prop):
    """Get an mpv property value."""
    resp = mpv_command("get_property", prop)
    if resp and resp.get("error") == "success":
        return resp.get("data")
    return None


def mpv_set(prop, value):
    """Set an mpv property."""
    mpv_command("set_property", prop, value)


def wait_for_socket(timeout=10):
    """Wait until the mpv IPC socket is ready."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if MPV_SOCKET.exists():
            try:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
                    s.settimeout(1)
                    s.connect(str(MPV_SOCKET))
                    return True
            except Exception:
                pass
        time.sleep(0.1)
    return False

# ── mpv process management ────────────────────────────────────────────────────

def start_mpv(playlist):
    """Launch a single persistent mpv process with IPC socket."""
    global mpv_proc
    kill_mpv()

    write_playlist_file(playlist)
    MPV_SOCKET.unlink(missing_ok=True)

    rotation = get_rotation()
    log.info(f"Starting mpv with rotation={rotation}°")

    args = [
        "mpv",
        "--vo=gpu",
        "--gpu-context=drm",
        "--gpu-api=opengl",
        f"--drm-device={DRM_CARD}",
        "--fullscreen",
        "--no-osc",
        "--no-input-default-bindings",
        "--no-terminal",
        "--really-quiet",
        "--hwdec=v4l2m2m-copy,drm-copy,auto-safe",
        "--ao=alsa",
        f"--video-rotate={rotation}",
        "--loop-playlist=inf",
        "--loop-file=no",
        f"--input-ipc-server={MPV_SOCKET}",
        f"--playlist={PLAYLIST_FILE}",
    ]
    mpv_proc = subprocess.Popen(args)
    log.info(f"mpv started (PID {mpv_proc.pid}), waiting for IPC socket...")

    if not wait_for_socket(timeout=10):
        log.error("mpv IPC socket never appeared")
        return False

    log.info("mpv IPC socket ready")
    return True


def kill_mpv():
    global mpv_proc
    if mpv_proc and mpv_proc.poll() is None:
        mpv_proc.terminate()
        try:
            mpv_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            mpv_proc.kill()
    mpv_proc = None
    MPV_SOCKET.unlink(missing_ok=True)


def get_current_filename():
    """Ask mpv which file it's currently playing."""
    path = mpv_get("path")
    if path:
        return Path(path).name
    return None


# ── State tracker thread ──────────────────────────────────────────────────────

def state_tracker():
    """Polls mpv every second to keep state.json up to date."""
    last = None
    while not stop_event.is_set():
        try:
            if mpv_proc and mpv_proc.poll() is None:
                name = get_current_filename()
                with paused_lock:
                    if user_stopped:
                        status = "stopped"
                    elif paused:
                        status = "paused"
                    else:
                        status = "playing" if name else "idle"
                if name != last:
                    hwdec = mpv_get("hwdec-current")
                    codec = mpv_get("video-format")
                    log.info(f"Now playing: {name} | codec={codec} hwdec={hwdec}")
                    last = name
                write_state(name, status)
            else:
                write_state(None, "idle")
                last = None
        except Exception:
            pass
        time.sleep(1)

# ── Main play loop ────────────────────────────────────────────────────────────

def play_loop():
    global paused, mpv_proc, user_stopped
    log.info(f"Using DRM device: {DRM_CARD}")
    write_state(None, "idle")

    # Start state tracker thread
    tracker = threading.Thread(target=state_tracker, daemon=True)
    tracker.start()

    while not stop_event.is_set():
        reload_event.clear()
        skip_event.clear()
        playlist = get_playlist()

        # Show splash if no videos OR user explicitly stopped
        if not playlist or user_stopped:
            if not playlist:
                log.info("No videos — showing splash screen")
            else:
                log.info("Stopped — showing splash screen, waiting for user action")
            write_state(None, "stopped" if user_stopped else "idle")

            # Start splash if not already showing
            splash = SPLASH_FILE if SPLASH_FILE.exists() else (PLACEHOLDER if PLACEHOLDER.exists() else None)
            if (mpv_proc is None or mpv_proc.poll() is not None) and splash:
                MPV_SOCKET.unlink(missing_ok=True)
                mpv_proc = subprocess.Popen([
                    "mpv", "--vo=gpu", "--gpu-context=drm", "--gpu-api=opengl",
                    f"--drm-device={DRM_CARD}",
                    "--fullscreen", "--no-osc", "--no-terminal",
                    "--really-quiet", "--image-display-duration=inf",
                    f"--video-rotate={get_rotation()}",
                    f"--input-ipc-server={MPV_SOCKET}", str(splash)
                ])
                wait_for_socket()

            # Wait until: new video uploaded (if idle), or skip/restart clears user_stopped
            while not stop_event.is_set():
                if skip_event.is_set() or reload_event.is_set():
                    user_stopped = False
                    break
                # If no videos, also wake on reload (new upload)
                if not user_stopped and reload_event.is_set():
                    break
                time.sleep(0.5)

            kill_mpv()
            continue

        log.info(f"Starting mpv with {len(playlist)} video(s)")
        if not start_mpv(playlist):
            time.sleep(3)
            continue

        # Re-apply paused state if needed
        with paused_lock:
            if paused:
                mpv_command("set_property", "pause", True)

        # Monitor: wait for reload/skip/stop signals, or mpv dying unexpectedly
        while not reload_event.is_set() and not stop_event.is_set():
            # Handle skip: tell mpv to go to next item in its internal playlist
            if skip_event.is_set():
                skip_event.clear()
                log.info("Skipping to next video")
                mpv_command("playlist-next", "force")

            # If mpv died unexpectedly, restart it
            if mpv_proc and mpv_proc.poll() is not None:
                log.warning("mpv exited unexpectedly, restarting...")
                break

            time.sleep(0.3)

        kill_mpv()

        # Clean up flag files
        for flag in [RELOAD_FLAG, SKIP_FLAG, PAUSE_FLAG]:
            try:
                flag.unlink(missing_ok=True)
            except Exception:
                pass


# ── Filesystem watchers ───────────────────────────────────────────────────────

class ControlFlagHandler(FileSystemEventHandler):
    def on_created(self, event):
        name = Path(event.src_path).name
        if name == ".reload":
            log.info("Reload flag — restarting playlist")
            user_stopped = False
            reload_event.set()
        elif name == ".skip":
            user_stopped = False
            skip_event.set()
            try: SKIP_FLAG.unlink(missing_ok=True)
            except: pass
        elif name == ".pause":
            self._toggle_pause()
            try: PAUSE_FLAG.unlink(missing_ok=True)
            except: pass
        elif name == ".stop":
            self._do_stop()
            try: STOP_FLAG.unlink(missing_ok=True)
            except: pass

    on_modified = on_created

    def _toggle_pause(self):
        global paused
        with paused_lock:
            paused = not paused
            if paused:
                mpv_command("set_property", "pause", True)
                state = read_state()
                write_state(state.get("now_playing"), "paused")
                log.info("Paused")
            else:
                mpv_command("set_property", "pause", False)
                state = read_state()
                write_state(state.get("now_playing"), "playing")
                log.info("Resumed")

    def _do_stop(self):
        global paused, user_stopped
        log.info("Stop requested — showing splash, waiting for user action")
        with paused_lock:
            paused = False
        user_stopped = True
        kill_mpv()
        write_state(None, "stopped")
        reload_event.set()  # wake play_loop so it enters the splash wait


class VideoFolderHandler(FileSystemEventHandler):
    def _trigger(self, event):
        if Path(event.src_path).suffix.lower() in SUPPORTED_EXT:
            log.info(f"Video change: {Path(event.src_path).name} — reloading")
            reload_event.set()
    def on_created(self, e): self._trigger(e)
    def on_deleted(self, e): self._trigger(e)
    def on_moved(self, e):   self._trigger(e)


# ── Signal handling ───────────────────────────────────────────────────────────

def handle_signal(signum, frame):
    log.info(f"Signal {signum} — shutting down")
    stop_event.set()
    kill_mpv()
    write_state(None, "idle")
    sys.exit(0)


signal.signal(signal.SIGTERM, handle_signal)
signal.signal(signal.SIGINT, handle_signal)


# ── Entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    log.info("=== VideoPlayer starting ===")
    VIDEO_DIR.mkdir(parents=True, exist_ok=True)

    # Clean up any stale flag files left over from before a reboot.
    # Without this, a .stop or .pause file written before shutdown
    # would immediately trigger that action again on startup.
    for stale in [RELOAD_FLAG, SKIP_FLAG, PAUSE_FLAG, STOP_FLAG]:
        try:
            stale.unlink(missing_ok=True)
        except Exception:
            pass

    observer = Observer()
    observer.schedule(VideoFolderHandler(), str(VIDEO_DIR), recursive=False)
    observer.schedule(ControlFlagHandler(), str(VIDEO_DIR.parent), recursive=False)
    observer.start()
    try:
        play_loop()
    finally:
        observer.stop()
        observer.join()
        kill_mpv()
        log.info("=== VideoPlayer stopped ===")
