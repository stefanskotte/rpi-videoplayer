![Splash](https://github.com/stefanskotte/rpi-videoplayer/blob/main/images/videplayer-splash.jpg "the splash")

# rpi-videoplayer

A fully autonomous video kiosk for Raspberry Pi 3/4/5 that:
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
curl -fsSL https://raw.githubusercontent.com/stefanskotte/rpi-videoplayer/main/setup.sh | sudo WIFI_COUNTRY=DK bash

# Germany
curl -fsSL https://raw.githubusercontent.com/stefanskotte/rpi-videoplayer/main/setup.sh | sudo WIFI_COUNTRY=DE bash
```

> **Why is the country code required?** WiFi operates on licensed radio frequencies. The country code tells the Pi which channels and power levels are legal in your region. Without it, `hostapd` will refuse to broadcast.

If you run the script interactively (not piped from curl), it will **prompt you** to enter the code instead.

Then reboot:
```bash
sudo reboot
```

> **RPi 3 only (no ethernet):** The installer will detect that WiFi is your only connection and will *not* start the AP automatically — doing so would kill your SSH session. Instead, run this when you are ready to switch to kiosk mode:
> ```bash
> sudo bash /opt/videoplayer/activate-ap.sh
> ```
> To temporarily return to WiFi client mode (e.g. for maintenance): `sudo bash /opt/videoplayer/deactivate-ap.sh`

---

## Hardware Compatibility

### Raspberry Pi 5

| Feature | Detail |
|---|---|
| **CPU** | Quad-core Cortex-A76 @ 2.4 GHz |
| **DRM device** | `/dev/dri/card1` (auto-detected) |
| **Network stack** | NetworkManager (Bookworm/Trixie) |
| **Boot config** | `/boot/firmware/config.txt` |
| **H.264 decode** | ⚠️ **Software only** — the VideoCore VII GPU does not expose an H.264 decoder to Linux. The RPi 5's fast CPU handles 1080p H.264 in software with ~40% CPU usage. |
| **H.265/HEVC decode** | ⚠️ **Hardware available but limited** — `rpi-hevc-dec` exists as a V4L2 device but uses a proprietary Media Controller pipeline incompatible with mpv's `v4l2m2m` backend. Falls back to software decode in this player. |
| **Recommended format** | **H.264 MP4** for compatibility, or H.265 if you transcode via a pipeline that uses `rpi-hevc-dec` directly |
| **Max resolution** | 4K capable in software |

### Raspberry Pi 4

| Feature | Detail |
|---|---|
| **CPU** | Quad-core Cortex-A72 @ 1.8 GHz |
| **DRM device** | `/dev/dri/card0` (auto-detected) |
| **Network stack** | dhcpcd (Bullseye) or NetworkManager (Bookworm) — both handled |
| **Boot config** | `/boot/config.txt` |
| **H.264 decode** | ✅ **Hardware accelerated** — VideoCore VI VPU decodes H.264 via `v4l2m2m`. mpv uses `--hwdec=auto` which picks this up automatically. |
| **H.265/HEVC decode** | ✅ **Hardware accelerated** — same VPU supports HEVC via `v4l2m2m`. |
| **Recommended format** | **H.264 MP4** (hardware decode, widest compatibility) or H.265 |
| **Max resolution** | 4K @ 30fps H.264, 4K @ 60fps H.265 |

### Raspberry Pi 3

| Feature | Detail |
|---|---|
| **CPU** | Quad-core Cortex-A53 @ 1.2 GHz |
| **DRM device** | `/dev/dri/card0` (auto-detected) |
| **Network stack** | dhcpcd (Bullseye) or NetworkManager (Bookworm) |
| **Boot config** | `/boot/config.txt` |
| **Ethernet** | ❌ **None** — WiFi-only device, requires special setup (see above) |
| **H.264 decode** | ⚠️ **Software only in DRM/KMS mode** — the VideoCore IV VPU supports H.264 hardware decode, but mpv's DRM output mode cannot use it. Software decode is used instead. |
| **H.265/HEVC decode** | ❌ **Not supported** — no HEVC decoder on VideoCore IV. CPU is also too slow for software HEVC at 1080p. |
| **Recommended format** | **H.264 MP4 at 1080p or lower** — this is the only reliable option |
| **Max resolution** | 1080p H.264 (software decode, expect ~70-90% CPU) |

### Quick comparison

| | RPi 3 | RPi 4 | RPi 5 |
|---|---|---|---|
| H.264 hardware decode | ❌ (SW) | ✅ | ❌ (SW) |
| H.265 hardware decode | ❌ | ✅ | ❌ (SW)* |
| Ethernet | ❌ | ✅ | ✅ |
| Recommended format | H.264 ≤1080p | H.264 or H.265 | H.264 ≤1080p |
| 4K playback | ❌ | ✅ | ✅ (SW) |

*RPi 5 has a HEVC decoder (`rpi-hevc-dec`) but it uses a proprietary driver pipeline not compatible with mpv's standard V4L2 backend.

### Converting video for best compatibility

To convert any video to H.264 MP4 (works well on all three models):
```bash
ffmpeg -i input.mp4 -c:v libx264 -preset fast -crf 23 -c:a aac output_h264.mp4
```

To convert to H.265 (recommended for RPi 4 hardware decode):
```bash
ffmpeg -i input.mp4 -c:v libx265 -preset fast -crf 28 -c:a aac output_h265.mp4
```

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
| 🖥️ / 📱 Landscape/Portrait | Toggle display rotation (persists across reboots) |
| Drag rows | Reorder playlist |
| ✕ | Delete a video |

The **Now Playing** banner shows the current video with an animated equalizer. The status dot shows green (playing), gold (paused), red (stopped), or grey (idle).

---

## Supported Formats

MP4, MKV, AVI, MOV, WEBM, TS, M4V

See the [Hardware Compatibility](#hardware-compatibility) section above for per-model codec recommendations.

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
├── player.py                  # Playlist engine (mpv IPC, DRM direct output)
├── generate_splash.py         # Generates idle splash screen
├── activate-ap.sh             # RPi 3: switch to AP/kiosk mode
├── deactivate-ap.sh           # RPi 3: return to WiFi client mode
├── ap-start.sh / ap-stop.sh   # AP bring-up/tear-down (called by systemd)
├── playlist_order.json        # Persisted playlist order
├── settings.json              # Persisted settings (rotation etc.)
├── state.json                 # Live playback state (polled by web UI)
├── .ap-active                 # Flag: AP mode persists across reboots (RPi 3)
├── .reload / .skip / .pause / .stop   # Runtime control flag files
├── logs/
│   ├── player.log
│   └── web.log
├── videos/                    # ← Drop videos here
└── web/
    ├── app.py                 # Flask web server (port 80)
    └── templates/
        └── index.html
```

---

## Troubleshooting

| Issue | Fix |
|---|---|
| No WiFi AP visible | `sudo systemctl status videoplayer-ap` — check hostapd logs |
| Web UI not loading | `sudo systemctl status videoplayer-web` — check `logs/web.log` |
| Black screen / no video | `sudo systemctl status videoplayer-display` — check `logs/player.log` |
| Video stuttering on RPi 3 | Use H.264 MP4 at 1080p or lower — H.265 is not supported |
| Video stuttering on RPi 5 | Normal — RPi 5 uses software decode; H.264 is fine up to 4K |
| RPi 3 AP not starting on boot | Run `sudo bash /opt/videoplayer/activate-ap.sh` first |

```bash
# View live logs
tail -f /opt/videoplayer/logs/player.log

# Check what codec and hwdec is being used for current video
# (shown in player.log when each video starts)
grep "Now playing" /opt/videoplayer/logs/player.log | tail -5

# Restart all services
sudo systemctl restart videoplayer-ap videoplayer-web videoplayer-display

# Force playlist reload
touch /opt/videoplayer/.reload
```
