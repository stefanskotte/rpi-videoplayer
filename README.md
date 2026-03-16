![Alt text](./images/videoplayer-splash.jpg) "a title")

# rpi-videoplayer

A fully autonomous video kiosk for Raspberry Pi 4/5 that:
- Plays videos in an **endless fullscreen loop** from boot — no interaction needed
- Hosts its own **WiFi access point** (`VideoPlayer`)
- Serves a **web UI at `http://192.168.4.1`** for uploading and managing the playlist
- Requires no keyboard, mouse, or internet connection after setup

---

## Install (one line)

Flash **Raspberry Pi OS Lite 64-bit**, boot, SSH in, then run with your 2-letter [ISO country code](https://en.wikipedia.org/wiki/ISO_3166-1_alpha-2):

```bash
# United Kingdom
curl -fsSL https://raw.githubusercontent.com/stefanskotte/rpi-videoplayer/main/setup.sh | sudo WIFI_COUNTRY=GB bash

# Denmark
curl -fsSL https://raw.githubusercontent.com/stefanskusercontent/rpi-videoplayer/main/setup.sh | sudo WIFI_COUNTRY=DK bash

# Germany
curl -fsSL https://raw.githubusercontent.com/stefanskotte/rpi-videoplayer/main/setup.sh | sudo WIFI_COUNTRY=DE bash
```

> **Why is this required?**  WiFi operates on licensed radio frequencies. The country code tells the Pi which channels and power levels are legal in your region. Without it, `hostapd` will refuse to broadcast.

If you run the script interactively (not piped from curl), it will **prompt you** to enter the code instead.

Then reboot:
```bash
sudo reboot
```

That's it. The Pi will boot into fullscreen video playback and host the `VideoPlayer` WiFi.

---

## Usage

1. Connect to WiFi: **`VideoPlayer`** / password: **`videoplayer123`**
2. Open **`http://192.168.4.1`** in your browser
3. Upload videos — playback starts immediately
4. Use the web UI to reorder, skip, pause, stop, or restart

---

## Web UI

| Control | Action |
|---|---|
| ⏸ Pause / ▶ Resume | Freeze/unfreeze current video |
| ⏭ Skip | Jump to next video |
| ⏹ Stop | Stop playback, show splash screen |
| ↺ Restart | Restart playlist from beginning |
| Drag rows | Reorder playlist |
| ✕ | Delete a video |

The **Now Playing** banner shows the current video with an animated equalizer. The status dot shows green (playing), gold (paused), red (stopped), or grey (idle).

---

## Supported Formats

MP4, MKV, AVI, MOV, WEBM, TS, M4V

**H.265/HEVC recommended** for hardware-accelerated decode on RPi 5.

To convert H.264 → H.265 on your Mac:
```bash
ffmpeg -i input.mp4 -c:v libx265 -preset fast -crf 28 -c:a aac output.mp4
```

---

## Default Credentials

| Setting | Value |
|---|---|
| WiFi SSID | `VideoPlayer` |
| WiFi Password | `videoplayer123` |
| Web UI | `http://192.168.4.1` |

To change SSID/password: edit `/etc/hostapd/hostapd.conf`, then `sudo systemctl restart hostapd`.

---

## File Structure

```
/opt/videoplayer/
├── player.py               # Playlist engine (mpv IPC, DRM direct output)
├── generate_splash.py      # Generates idle splash screen
├── ap-start.sh / ap-stop.sh
├── playlist_order.json     # Persisted playlist order
├── state.json              # Live playback state (polled by web UI)
├── .reload / .skip / .pause / .stop   # Control flag files
├── logs/
│   ├── player.log
│   └── web.log
├── videos/                 # ← Drop videos here
└── web/
    ├── app.py              # Flask web server (port 80)
    └── templates/
        └── index.html
```

---

## Troubleshooting

| Issue | Fix |
|---|---|
| No WiFi AP visible | `sudo systemctl status videoplayer-ap` |
| Web UI not loading | `sudo systemctl status videoplayer-web` |
| Black screen / no video | `sudo systemctl status videoplayer-display` |
| RPi 5 WiFi issues | Interface may be `wlan1` — update `/etc/hostapd/hostapd.conf` |

```bash
# View live logs
tail -f /opt/videoplayer/logs/player.log

# Restart all services
sudo systemctl restart videoplayer-ap videoplayer-web videoplayer-display

# Force playlist reload
touch /opt/videoplayer/.reload
```
