#!/bin/bash
# =============================================================================
# Raspberry Pi Endless Loop Video Player - Installation Script
# Run as root: sudo bash install.sh
# Tested on: Raspberry Pi 4/5, Raspberry Pi OS Lite 64-bit
# =============================================================================
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✔]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✘]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[i]${NC} $1"; }

[ "$EUID" -ne 0 ] && err "Please run as root: sudo bash install.sh"

INSTALL_DIR="/opt/videoplayer"
SERVICE_USER="videoplayer"
SSID="VideoPlayer"
WIFI_PASS="videoplayer123"
AP_IP="192.168.4.1"

echo ""
echo "=================================================="
echo "  Raspberry Pi Endless Loop Video Player Setup"
echo "=================================================="

# ── Dependencies ──────────────────────────────────────────────────────────────
info "Updating packages and installing dependencies..."
apt-get update -qq
apt-get install -y -qq \
    mpv python3 python3-pip python3-flask \
    hostapd dnsmasq python3-watchdog \
    git curl net-tools
log "Dependencies installed"

# ── User ──────────────────────────────────────────────────────────────────────
if ! id "$SERVICE_USER" &>/dev/null; then
    useradd -r -m -s /bin/bash "$SERVICE_USER"
    log "Created user: $SERVICE_USER"
fi
# Add to all required groups for DRM/GPU access
usermod -aG video,audio,input,tty,render "$SERVICE_USER"
log "User groups configured"

# ── Install files ─────────────────────────────────────────────────────────────
mkdir -p "$INSTALL_DIR"/{videos,web/templates,web/static,logs}
cp player.py                "$INSTALL_DIR/player.py"
cp web/app.py               "$INSTALL_DIR/web/app.py"
cp web/templates/index.html "$INSTALL_DIR/web/templates/index.html"
cp generate_splash.py       "$INSTALL_DIR/generate_splash.py"
chown -R "$SERVICE_USER":"$SERVICE_USER" "$INSTALL_DIR"
chmod +x "$INSTALL_DIR/player.py"
log "Files installed to $INSTALL_DIR"

info "Generating splash screen..."
apt-get install -y -qq python3-pil
python3 "$INSTALL_DIR/generate_splash.py" && log "Splash screen generated" || warn "Splash generation failed (non-fatal)"

# ── Access Point ──────────────────────────────────────────────────────────────
info "Configuring WiFi access point ($SSID)..."
systemctl stop hostapd dnsmasq wpa_supplicant 2>/dev/null || true

# Unmask and enable hostapd (masked by default on Raspberry Pi OS)
systemctl unmask hostapd
systemctl enable hostapd

grep -q "VideoPlayer" /etc/dhcpcd.conf || cat >> /etc/dhcpcd.conf << EOF

# VideoPlayer Access Point
interface wlan0
    static ip_address=${AP_IP}/24
    nohook wpa_supplicant
EOF

cat > /etc/hostapd/hostapd.conf << EOF
interface=wlan0
driver=nl80211
ssid=${SSID}
hw_mode=g
channel=6
wmm_enabled=0
auth_algs=1
wpa=2
wpa_passphrase=${WIFI_PASS}
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF

sed -i 's|#DAEMON_CONF=""|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd

cat > /etc/dnsmasq.conf << EOF
interface=wlan0
dhcp-range=192.168.4.10,192.168.4.50,255.255.255.0,24h
domain=local
address=/videoplayer.local/${AP_IP}
EOF

log "Access point configured"

# ── AP helper scripts ─────────────────────────────────────────────────────────
cat > "$INSTALL_DIR/ap-start.sh" << APEOF
#!/bin/bash
ip link set wlan0 up
ip addr add ${AP_IP}/24 dev wlan0 2>/dev/null || true
systemctl start hostapd && systemctl start dnsmasq
APEOF

cat > "$INSTALL_DIR/ap-stop.sh" << 'APEOF'
#!/bin/bash
systemctl stop hostapd dnsmasq
ip addr del 192.168.4.1/24 dev wlan0 2>/dev/null || true
APEOF

chmod +x "$INSTALL_DIR/ap-start.sh" "$INSTALL_DIR/ap-stop.sh"

# ── systemd services ──────────────────────────────────────────────────────────
info "Creating systemd services..."

cat > /etc/systemd/system/videoplayer-ap.service << EOF
[Unit]
Description=VideoPlayer WiFi Access Point
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash ${INSTALL_DIR}/ap-start.sh
ExecStop=/bin/bash ${INSTALL_DIR}/ap-stop.sh

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/videoplayer-web.service << EOF
[Unit]
Description=VideoPlayer Web Interface
After=videoplayer-ap.service

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}/web
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/web/app.py
Restart=always
RestartSec=5
StandardOutput=append:${INSTALL_DIR}/logs/web.log
StandardError=append:${INSTALL_DIR}/logs/web.log

[Install]
WantedBy=multi-user.target
EOF

# Display service: uses mpv with direct DRM/KMS output — no X11 needed.
# This works on RPi 4 and RPi 5 without a desktop environment.
# RPi 5 uses /dev/dri/card1 for HDMI output; RPi 4 typically uses card0.
# The player.py script auto-detects the correct card at runtime.
cat > /etc/systemd/system/videoplayer-display.service << EOF
[Unit]
Description=VideoPlayer Display (mpv DRM direct — no X11)
After=videoplayer-ap.service

[Service]
Type=simple
User=${SERVICE_USER}
Environment=HOME=/home/${SERVICE_USER}
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/player.py
Restart=always
RestartSec=5
StandardOutput=append:${INSTALL_DIR}/logs/player.log
StandardError=append:${INSTALL_DIR}/logs/player.log

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable videoplayer-ap.service
systemctl enable videoplayer-web.service
systemctl enable videoplayer-display.service
log "Services enabled"

# ── Boot config ───────────────────────────────────────────────────────────────
# Disable rainbow splash and console blanking
if [ -f /boot/config.txt ]; then
    grep -q "disable_splash" /boot/config.txt || echo "disable_splash=1" >> /boot/config.txt
fi
if [ -f /boot/firmware/config.txt ]; then
    grep -q "disable_splash" /boot/firmware/config.txt || echo "disable_splash=1" >> /boot/firmware/config.txt
fi
if [ -f /boot/cmdline.txt ]; then
    grep -q "consoleblank" /boot/cmdline.txt || sed -i 's/$/ quiet logo.nologo consoleblank=0/' /boot/cmdline.txt
fi
if [ -f /boot/firmware/cmdline.txt ]; then
    grep -q "consoleblank" /boot/firmware/cmdline.txt || sed -i 's/$/ quiet logo.nologo consoleblank=0/' /boot/firmware/cmdline.txt
fi

echo ""
echo "=================================================="
echo -e "  ${GREEN}Installation Complete!${NC}"
echo "=================================================="
echo ""
echo "  WiFi SSID:     $SSID"
echo "  WiFi Password: $WIFI_PASS"
echo "  Web UI:        http://$AP_IP"
echo "  Video folder:  $INSTALL_DIR/videos"
echo ""
echo "  → sudo reboot"
echo ""
