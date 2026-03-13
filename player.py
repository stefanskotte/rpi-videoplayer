#!/usr/bin/env python3
"""
player.py - Endless loop video player controller.
Uses mpv with direct DRM/KMS output — no X11 or desktop environment needed.
Automatically detects the correct DRM card for RPi 4 and RPi 5.
Watches /opt/videoplayer/videos and reacts to playlist changes live.

Control flags (touch file to trigger):
  .reload  — reload playlist from scratch
  .skip    — skip to next video immediately
  .pause   — toggle pause/resume
"""

import sys
import json
import time
import signal
import subprocess
import threading
import logging
from pathlib import Path
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler

VIDEO_DIR     = Path("/opt/videoplayer/videos")
PLACEHOLDER   = Path("/opt/videoplayer/web/static/placeholder.jpg")
LOG_FILE      = Path("/opt/videoplayer/logs/player.log")
RELOAD_FLAG   = Path("/opt/videoplayer/.reload")
SKIP_FLAG     = Path("/opt/videoplayer/.skip")
PAUSE_FLAG    = Path("/opt/videoplayer/.pause")
STATE_FILE    = Path("/opt/videoplayer/state.json")
ORDER_FILE    = Path("/opt/videoplayer/playlist_order.json")
SUPPORTED_EXT = {".mp4", ".mkv", ".avi", ".mov", ".webm", ".ts", ".m4v"}


def detect_drm_card() -> str:
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

MPV_BASE_ARGS = [
    "mpv", "--vo=drm", f"--drm-device={DRM_CARD}",
    "--fullscreen", "--no-osc", "--no-input-default-bindings",
    "--no-terminal", "--really-quiet", "--hwdec=auto",
    "--loop-file=no", "--keep-open=no",
]

LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.FileHandler(LOG_FILE), logging.StreamHandler(sys.stdout)]
)
log = logging.getLogger("player")

current_proc  = None
reload_event  = threading.Event()
skip_event    = threading.Event()
stop_event    = threading.Event()
paused        = False
paused_lock   = threading.Lock()


# ── State file ────────────────────────────────────────────────────────────────

def write_state(video: str | None, status: str):
    """Write current playback state for the web UI to read."""
    try:
        STATE_FILE.write_text(json.dumps({
            "now_playing": video,
            "status": status,   # playing | paused | idle
            "ts": time.time()
        }))
    except Exception:
        pass


def read_state() -> dict:
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


# ── mpv control ───────────────────────────────────────────────────────────────

def kill_mpv():
    global current_proc
    if current_proc and current_proc.poll() is None:
        current_proc.terminate()
        try:
            current_proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            current_proc.kill()
    current_proc = None


def pause_mpv():
    """Send SIGSTOP to freeze mpv (pause without seeking)."""
    if current_proc and current_proc.poll() is None:
        current_proc.send_signal(signal.SIGSTOP)
        log.info("Paused")


def resume_mpv():
    """Send SIGCONT to unfreeze mpv."""
    if current_proc and current_proc.poll() is None:
        current_proc.send_signal(signal.SIGCONT)
        log.info("Resumed")


# ── Playback loop ─────────────────────────────────────────────────────────────

def play_placeholder():
    global current_proc
    log.info("No videos found — waiting for uploads...")
    write_state(None, "idle")
    if PLACEHOLDER.exists():
        current_proc = subprocess.Popen(
            MPV_BASE_ARGS + ["--image-display-duration=inf", str(PLACEHOLDER)]
        )
        while not reload_event.is_set() and not stop_event.is_set():
            if current_proc.poll() is not None:
                break
            time.sleep(1)
        kill_mpv()
    else:
        time.sleep(5)


def play_loop():
    global current_proc, paused
    log.info(f"Using DRM device: {DRM_CARD}")
    write_state(None, "idle")

    while not stop_event.is_set():
        reload_event.clear()
        skip_event.clear()
        playlist = get_playlist()

        if not playlist:
            play_placeholder()
            continue

        log.info(f"Playlist: {len(playlist)} video(s)")
        for video in playlist:
            if reload_event.is_set() or stop_event.is_set():
                break

            skip_event.clear()
            if not video.exists():
                continue

            log.info(f"Playing: {video.name}")
            write_state(video.name, "paused" if paused else "playing")
            current_proc = subprocess.Popen(MPV_BASE_ARGS + [str(video)])

            # Apply paused state immediately if already paused
            with paused_lock:
                if paused:
                    time.sleep(0.3)
                    pause_mpv()

            while not reload_event.is_set() and not stop_event.is_set() and not skip_event.is_set():
                if current_proc.poll() is not None:
                    break
                time.sleep(0.3)

            kill_mpv()

        # Clean up flag files
        for flag in [RELOAD_FLAG, SKIP_FLAG, PAUSE_FLAG]:
            try:
                flag.unlink(missing_ok=True)
            except Exception:
                pass

    write_state(None, "idle")


# ── Flag file watcher ─────────────────────────────────────────────────────────

class ControlFlagHandler(FileSystemEventHandler):
    """Watches the install dir for .reload, .skip, .pause flag files."""

    def on_created(self, event):
        name = Path(event.src_path).name
        if name == ".reload":
            log.info("Reload flag detected")
            reload_event.set()
        elif name == ".skip":
            log.info("Skip flag detected")
            skip_event.set()
            try: SKIP_FLAG.unlink(missing_ok=True)
            except: pass
        elif name == ".pause":
            self._toggle_pause()
            try: PAUSE_FLAG.unlink(missing_ok=True)
            except: pass

    on_modified = on_created

    def _toggle_pause(self):
        global paused
        with paused_lock:
            paused = not paused
            if paused:
                pause_mpv()
                state = read_state()
                write_state(state.get("now_playing"), "paused")
                log.info("Toggled: paused")
            else:
                resume_mpv()
                state = read_state()
                write_state(state.get("now_playing"), "playing")
                log.info("Toggled: playing")


class VideoFolderHandler(FileSystemEventHandler):
    def _trigger(self, event):
        if Path(event.src_path).suffix.lower() in SUPPORTED_EXT:
            log.info(f"Change detected: {Path(event.src_path).name}")
            reload_event.set()
    def on_created(self, e): self._trigger(e)
    def on_deleted(self, e): self._trigger(e)
    def on_moved(self, e):   self._trigger(e)


# ── Signal handling ───────────────────────────────────────────────────────────

def handle_signal(signum, frame):
    log.info(f"Signal {signum} received, shutting down...")
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
