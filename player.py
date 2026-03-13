#!/usr/bin/env python3
"""
player.py - Endless loop video player controller.
Uses mpv with direct DRM/KMS output — no X11 or desktop environment needed.
Automatically detects the correct DRM card for RPi 4 and RPi 5.
Watches /opt/videoplayer/videos and reacts to playlist changes live.
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
ORDER_FILE    = Path("/opt/videoplayer/playlist_order.json")
SUPPORTED_EXT = {".mp4", ".mkv", ".avi", ".mov", ".webm", ".ts", ".m4v"}


def detect_drm_card() -> str:
    """
    Detect the correct DRM card for video output.
    RPi 5 uses card1 for HDMI; RPi 4 uses card0.
    Falls back to card0 if detection fails.
    """
    try:
        model = Path("/proc/device-tree/model").read_text()
        if "Raspberry Pi 5" in model:
            card = "/dev/dri/card1"
        else:
            card = "/dev/dri/card0"
    except Exception:
        card = "/dev/dri/card0"
    # Verify the card actually exists
    if not Path(card).exists():
        for fallback in ["/dev/dri/card0", "/dev/dri/card1"]:
            if Path(fallback).exists():
                card = fallback
                break
    return card


DRM_CARD = detect_drm_card()

MPV_BASE_ARGS = [
    "mpv",
    "--vo=drm",
    f"--drm-device={DRM_CARD}",
    "--fullscreen",
    "--no-osc",
    "--no-input-default-bindings",
    "--no-terminal",
    "--really-quiet",
    "--hwdec=auto",
    "--loop-file=no",
    "--keep-open=no",
]

# ── Logging ───────────────────────────────────────────────────────────────────
LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.FileHandler(LOG_FILE), logging.StreamHandler(sys.stdout)]
)
log = logging.getLogger("player")

# ── State ─────────────────────────────────────────────────────────────────────
current_proc = None
reload_event = threading.Event()
stop_event   = threading.Event()


def get_playlist():
    """Return playlist in saved order, falling back to alphabetical for new files."""
    VIDEO_DIR.mkdir(parents=True, exist_ok=True)
    files = {p.name: p for p in VIDEO_DIR.iterdir() if p.suffix.lower() in SUPPORTED_EXT}

    # Load saved order if it exists
    order = []
    if ORDER_FILE.exists():
        try:
            order = json.loads(ORDER_FILE.read_text())
        except Exception:
            order = []

    result = []
    seen = set()
    # First: files in saved order
    for name in order:
        if name in files:
            result.append(files[name])
            seen.add(name)
    # Then: any new files not yet in the order file (alphabetical)
    for name in sorted(files):
        if name not in seen:
            result.append(files[name])
    return result


def kill_mpv():
    global current_proc
    if current_proc and current_proc.poll() is None:
        current_proc.terminate()
        try:
            current_proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            current_proc.kill()
    current_proc = None


def play_placeholder():
    """Show placeholder image when no videos are available."""
    global current_proc
    log.info("No videos found — waiting for uploads...")
    if PLACEHOLDER.exists():
        args = MPV_BASE_ARGS + ["--image-display-duration=inf", str(PLACEHOLDER)]
        current_proc = subprocess.Popen(args)
        while not reload_event.is_set() and not stop_event.is_set():
            if current_proc.poll() is not None:
                break
            time.sleep(1)
        kill_mpv()
    else:
        # No placeholder either — just wait
        time.sleep(5)


def play_loop():
    global current_proc
    log.info(f"Using DRM device: {DRM_CARD}")
    while not stop_event.is_set():
        reload_event.clear()
        playlist = get_playlist()
        if not playlist:
            play_placeholder()
            continue
        log.info(f"Playlist: {len(playlist)} video(s)")
        for video in playlist:
            if reload_event.is_set() or stop_event.is_set():
                break
            if not video.exists():
                continue
            log.info(f"Playing: {video.name}")
            current_proc = subprocess.Popen(MPV_BASE_ARGS + [str(video)])
            while not reload_event.is_set() and not stop_event.is_set():
                if current_proc.poll() is not None:
                    break
                time.sleep(0.5)
            kill_mpv()
        try:
            RELOAD_FLAG.unlink(missing_ok=True)
        except Exception:
            pass


# ── Filesystem watchers ───────────────────────────────────────────────────────

class VideoFolderHandler(FileSystemEventHandler):
    def _trigger(self, event):
        if Path(event.src_path).suffix.lower() in SUPPORTED_EXT:
            log.info(f"Change detected: {Path(event.src_path).name}")
            reload_event.set()
    def on_created(self, e): self._trigger(e)
    def on_deleted(self, e): self._trigger(e)
    def on_moved(self, e):   self._trigger(e)


class ReloadFlagHandler(FileSystemEventHandler):
    def on_created(self, event):
        if Path(event.src_path).name == ".reload":
            log.info("Reload flag detected")
            reload_event.set()
    on_modified = on_created


# ── Signal handling ───────────────────────────────────────────────────────────

def handle_signal(signum, frame):
    log.info(f"Signal {signum} received, shutting down...")
    stop_event.set()
    kill_mpv()
    sys.exit(0)


signal.signal(signal.SIGTERM, handle_signal)
signal.signal(signal.SIGINT, handle_signal)


# ── Entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    log.info("=== VideoPlayer starting ===")
    VIDEO_DIR.mkdir(parents=True, exist_ok=True)
    observer = Observer()
    observer.schedule(VideoFolderHandler(), str(VIDEO_DIR), recursive=False)
    observer.schedule(ReloadFlagHandler(), str(VIDEO_DIR.parent), recursive=False)
    observer.start()
    try:
        play_loop()
    finally:
        observer.stop()
        observer.join()
        kill_mpv()
        log.info("=== VideoPlayer stopped ===")
