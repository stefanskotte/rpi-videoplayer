# rpi-videoplayer

A fully autonomous video kiosk running on a Raspberry Pi 4/5 that:
- Plays videos in an **endless fullscreen loop** from boot — no interaction needed
- Hosts its own **WiFi access point** (`VideoPlayer`)
- Serves a **web UI at `http://192.168.4.1`** for uploading and managing the playlist
- Requires no keyboard, mouse, or internet connection after setup

---

## Quick Start

### 1. Flash the OS
Flash **Raspberry Pi OS Lite 64-bit** using Raspberry Pi Imager. Enable SSH in the advanced settings.

### 2. Transfer files to the Pi
```bash
scp -r rpi-videoplayer/ pi@raspberrypi.local:~/
```

### 3. Run the installer
```bash
ssh pi@raspberrypi.local
cd ~/rpi-videoplayer
sudo bash install.sh
```

### 4. Reboot
```bash
sudo reboot
```

After reboot the Pi boots directly into fullscreen video playback and hosts the `VideoPlayer` WiFi network.

---

## Usage

1. Connect your phone or laptop to WiFi: **`VideoPlayer`** / password: **`videoplayer123`**
2. Open a browser and go to **`http://192.168.4.1`**
3. Upload videos — playback updates immediately
4. Drag rows in the playlist to reorder

---

## File Structure

```
/opt/videoplayer/
├── player.py               # Playlist engine (runs inside X/Openbox)
├── ap-start.sh             # Brings up the WiFi access point
├── ap-stop.sh              # Tears down the WiFi access point
├── playlist_order.json     # Persisted playlist order
├── .reload                 # Touch this file to force a playlist reload
├── logs/
│   ├── player.log
│   ├── web.log
│   └── display.log
├── videos/                 # ← Drop videos here
└── web/
    ├── app.py              # Flask web server (port 80)
    └── templates/
        └── index.html      # Web UI
```

---

## Default Credentials

| Setting       | Value              |
|---------------|--------------------|
| WiFi SSID     | `VideoPlayer`      |
| WiFi Password | `videoplayer123`   |
| Web UI        | `http://192.168.4.1` |

To change SSID/password: edit `/etc/hostapd/hostapd.conf` then `sudo systemctl restart hostapd`.

---

## Supported Video Formats

MP4, MKV, AVI, MOV, WEBM, TS, M4V — **H.264 MP4 recommended** for best hardware decode performance on the RPi GPU.

---

## Troubleshooting

| Issue | Fix |
|---|---|
| No WiFi AP visible | `sudo systemctl status videoplayer-ap` — check hostapd logs |
| Web UI not loading | `sudo systemctl status videoplayer-web` — check `logs/web.log` |
| Black screen / no video | `sudo systemctl status videoplayer-display` — check `logs/display.log` |
| Video stuttering | Use H.264 MP4 files for best hardware decode |
| RPi 5 WiFi issues | Check `dmesg` — interface may be `wlan1` instead of `wlan0` |

### Useful commands
```bash
# View live logs
tail -f /opt/videoplayer/logs/player.log
tail -f /opt/videoplayer/logs/web.log

# Force playlist reload
touch /opt/videoplayer/.reload

# Restart all services
sudo systemctl restart videoplayer-ap videoplayer-web videoplayer-display
```
