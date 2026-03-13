#!/usr/bin/env python3
"""
app.py - Flask web interface for the VideoPlayer.
Serves on port 80. Allows uploading, reordering, and deleting videos.
"""

import os
import json
import time
import logging
import subprocess
from pathlib import Path
from threading import Lock
from flask import (
    Flask, render_template, request, redirect,
    url_for, flash, jsonify, send_from_directory
)
from werkzeug.utils import secure_filename

VIDEO_DIR      = Path("/opt/videoplayer/videos")
RELOAD_FLAG    = Path("/opt/videoplayer/.reload")
ORDER_FILE     = Path("/opt/videoplayer/playlist_order.json")
LOG_FILE       = Path("/opt/videoplayer/logs/web.log")
UPLOAD_MAX_MB  = 4096
SUPPORTED_EXT  = {".mp4", ".mkv", ".avi", ".mov", ".webm", ".ts", ".m4v"}
PORT           = 80

app = Flask(__name__, template_folder="templates", static_folder="static")
app.secret_key = os.urandom(24)
app.config["MAX_CONTENT_LENGTH"] = UPLOAD_MAX_MB * 1024 * 1024

VIDEO_DIR.mkdir(parents=True, exist_ok=True)
LOG_FILE.parent.mkdir(parents=True, exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.FileHandler(LOG_FILE), logging.StreamHandler()]
)
log = logging.getLogger("web")
lock = Lock()


def allowed_file(filename):
    return Path(filename).suffix.lower() in SUPPORTED_EXT


def get_ordered_playlist():
    files = {p.name: p for p in VIDEO_DIR.iterdir()
             if p.suffix.lower() in SUPPORTED_EXT}
    order = []
    if ORDER_FILE.exists():
        try:
            order = json.loads(ORDER_FILE.read_text())
        except Exception:
            order = []
    result = []
    seen = set()
    for name in order:
        if name in files:
            p = files[name]
            result.append({"name": name,
                           "size_mb": round(p.stat().st_size / 1_048_576, 1)})
            seen.add(name)
    for name, p in sorted(files.items()):
        if name not in seen:
            result.append({"name": name,
                           "size_mb": round(p.stat().st_size / 1_048_576, 1)})
    return result


def save_order(names):
    with lock:
        ORDER_FILE.write_text(json.dumps(names, indent=2))


def trigger_reload():
    try:
        RELOAD_FLAG.touch()
    except Exception as e:
        log.warning(f"Could not write reload flag: {e}")


def get_player_status():
    try:
        result = subprocess.run(["pgrep", "-x", "mpv"], capture_output=True, text=True)
        return "playing" if result.returncode == 0 else "idle"
    except Exception:
        return "unknown"


@app.route("/")
def index():
    return render_template("index.html",
                           playlist=get_ordered_playlist(),
                           status=get_player_status())


@app.route("/upload", methods=["POST"])
def upload():
    if "videos" not in request.files:
        flash("No files selected.", "error")
        return redirect(url_for("index"))
    files = request.files.getlist("videos")
    uploaded, errors = [], []
    for f in files:
        if not f or not f.filename:
            continue
        if not allowed_file(f.filename):
            errors.append(f"{f.filename}: unsupported format")
            continue
        filename = secure_filename(f.filename)
        try:
            with lock:
                f.save(str(VIDEO_DIR / filename))
            uploaded.append(filename)
            log.info(f"Uploaded: {filename}")
        except Exception as e:
            errors.append(f"{filename}: {e}")
    if uploaded:
        trigger_reload()
        flash(f"Uploaded: {', '.join(uploaded)}", "success")
    for e in errors:
        flash(e, "error")
    return redirect(url_for("index"))


@app.route("/delete/<filename>", methods=["POST"])
def delete(filename):
    safe = secure_filename(filename)
    target = VIDEO_DIR / safe
    if target.exists():
        with lock:
            target.unlink()
        if ORDER_FILE.exists():
            order = json.loads(ORDER_FILE.read_text())
            ORDER_FILE.write_text(json.dumps([n for n in order if n != safe], indent=2))
        trigger_reload()
        flash(f"Deleted: {safe}", "success")
    else:
        flash("File not found.", "error")
    return redirect(url_for("index"))


@app.route("/reorder", methods=["POST"])
def reorder():
    data = request.get_json()
    if not data or "order" not in data:
        return jsonify({"error": "Invalid data"}), 400
    save_order([secure_filename(n) for n in data["order"]])
    trigger_reload()
    return jsonify({"ok": True})


@app.route("/restart", methods=["POST"])
def restart():
    trigger_reload()
    flash("Playback restarting...", "info")
    return redirect(url_for("index"))


@app.route("/api/status")
def api_status():
    return jsonify({"status": get_player_status(),
                    "count": len(get_ordered_playlist()),
                    "ts": time.time()})


if __name__ == "__main__":
    log.info(f"Starting web server on port {PORT}...")
    app.run(host="0.0.0.0", port=PORT, debug=False, threaded=True)
