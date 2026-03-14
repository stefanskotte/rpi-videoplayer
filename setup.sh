#!/bin/bash
# =============================================================================
#  Raspberry Pi VideoPlayer — one-line installer
#  Usage: curl -fsSL https://raw.githubusercontent.com/stefanskotte/rpi-videoplayer/main/setup.sh | sudo bash
# =============================================================================
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✔]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✘]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[→]${NC} $1"; }

[ "$EUID" -ne 0 ] && err "Please run as root:  curl -fsSL https://raw.githubusercontent.com/stefanskotte/rpi-videoplayer/main/setup.sh | sudo bash"

REPO="https://raw.githubusercontent.com/stefanskotte/rpi-videoplayer/main"
INSTALL_DIR="/opt/videoplayer"
SERVICE_USER="videoplayer"
SSID="VideoPlayer"
WIFI_PASS="videoplayer123"
AP_IP="192.168.4.1"

echo ""
echo "  ██╗   ██╗██╗██████╗ ███████╗ ██████╗ ██████╗ ██╗      █████╗ ██╗   ██╗███████╗██████╗ "
echo "  ██║   ██║██║██╔══██╗██╔════╝██╔═══██╗██╔══██╗██║     ██╔══██╗╚██╗ ██╔╝██╔════╝██╔══██╗"
echo "  ██║   ██║██║██║  ██║█████╗  ██║   ██║██████╔╝██║     ███████║ ╚████╔╝ █████╗  ██████╔╝"
echo "  ╚██╗ ██╔╝██║██║  ██║██╔══╝  ██║   ██║██╔═══╝ ██║     ██╔══██║  ╚██╔╝  ██╔══╝  ██╔══██╗"
echo "   ╚████╔╝ ██║██████╔╝███████╗╚██████╔╝██║     ███████╗██║  ██║   ██║   ███████╗██║  ██║"
echo "    ╚═══╝  ╚═╝╚═════╝ ╚══════╝ ╚═════╝ ╚═╝     ╚══════╝╚═╝  ╚═╝   ╚═╝   ╚══════╝╚═╝  ╚═╝"
echo ""
echo "  Raspberry Pi Endless Loop Video Kiosk"
echo "  https://github.com/stefanskotte/rpi-videoplayer"
echo "=================================================================="
echo ""

# ── System check ──────────────────────────────────────────────────────────────
info "Checking system..."
if ! grep -qi "raspberry pi\|raspbian\|debian" /proc/device-tree/model 2>/dev/null && \
   ! grep -qi "raspberry\|raspbian\|debian" /etc/os-release 2>/dev/null; then
    warn "This script is designed for Raspberry Pi OS. Proceeding anyway..."
fi

# Detect Pi model for DRM card selection
PI_MODEL=$(cat /proc/device-tree/model 2>/dev/null || echo "unknown")
if echo "$PI_MODEL" | grep -q "Raspberry Pi 5"; then
    DRM_CARD="/dev/dri/card1"
    log "Detected: Raspberry Pi 5 (DRM card1)"
else
    DRM_CARD="/dev/dri/card0"
    log "Detected: Raspberry Pi 4 or earlier (DRM card0)"
fi

# ── Dependencies ──────────────────────────────────────────────────────────────
info "Updating packages..."
apt-get update -qq

info "Installing dependencies..."
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    mpv python3 python3-pip python3-flask python3-watchdog python3-pil \
    hostapd dnsmasq curl git net-tools
log "Dependencies installed"

# ── User ──────────────────────────────────────────────────────────────────────
if ! id "$SERVICE_USER" &>/dev/null; then
    useradd -r -m -s /bin/bash "$SERVICE_USER"
    log "Created user: $SERVICE_USER"
else
    log "User $SERVICE_USER already exists"
fi
usermod -aG video,audio,input,tty,render "$SERVICE_USER"

# ── Directory structure ───────────────────────────────────────────────────────
info "Creating directory structure..."
mkdir -p "$INSTALL_DIR"/{videos,web/templates,web/static,logs}
chown -R "$SERVICE_USER":"$SERVICE_USER" "$INSTALL_DIR"
log "Directories created at $INSTALL_DIR"

# ── Download application files ────────────────────────────────────────────────
info "Downloading application files from GitHub..."

download() {
    local src="$1" dst="$2"
    curl -fsSL "$REPO/$src" -o "$dst" || err "Failed to download $src"
}

download "player.py"               "$INSTALL_DIR/player.py"
download "generate_splash.py"      "$INSTALL_DIR/generate_splash.py"
download "web/app.py"              "$INSTALL_DIR/web/app.py"
download "web/templates/index.html" "$INSTALL_DIR/web/templates/index.html"

chmod +x "$INSTALL_DIR/player.py"
chown -R "$SERVICE_USER":"$SERVICE_USER" "$INSTALL_DIR"
log "Application files installed"

# ── Generate splash screen ────────────────────────────────────────────────────
info "Generating splash screen..."
sudo -u "$SERVICE_USER" python3 "$INSTALL_DIR/generate_splash.py" \
    && log "Splash screen generated" \
    || warn "Splash generation failed (non-fatal, will show black screen when idle)"

# ── WiFi Access Point ─────────────────────────────────────────────────────────
info "Configuring WiFi access point ($SSID)..."
systemctl stop hostapd dnsmasq 2>/dev/null || true
systemctl unmask hostapd
systemctl unmask dnsmasq

# Static IP for wlan0
if ! grep -q "VideoPlayer" /etc/dhcpcd.conf 2>/dev/null; then
    cat >> /etc/dhcpcd.conf << EOF

# VideoPlayer Access Point
interface wlan0
    static ip_address=${AP_IP}/24
    nohook wpa_supplicant
EOF
fi

# hostapd config
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

sed -i 's|#DAEMON_CONF=""|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd 2>/dev/null || true

# dnsmasq config
cat > /etc/dnsmasq.conf << EOF
interface=wlan0
dhcp-range=192.168.4.10,192.168.4.50,255.255.255.0,24h
domain=local
address=/videoplayer.local/${AP_IP}
EOF

log "Access point configured (SSID: $SSID, IP: $AP_IP)"

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
chown "$SERVICE_USER":"$SERVICE_USER" "$INSTALL_DIR/ap-start.sh" "$INSTALL_DIR/ap-stop.sh"

# ── systemd services ──────────────────────────────────────────────────────────
info "Installing systemd services..."

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

cat > /etc/systemd/system/videoplayer-display.service << EOF
[Unit]
Description=VideoPlayer Display (mpv DRM direct)
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
systemctl enable hostapd dnsmasq
systemctl enable videoplayer-ap.service
systemctl enable videoplayer-web.service
systemctl enable videoplayer-display.service
log "Services enabled"

# ── Boot config ───────────────────────────────────────────────────────────────
info "Configuring boot settings..."

# RPi 4 uses /boot, RPi 5 uses /boot/firmware
for CFG in /boot/config.txt /boot/firmware/config.txt; do
    [ -f "$CFG" ] && grep -q "disable_splash" "$CFG" \
        || echo "disable_splash=1" >> "$CFG" 2>/dev/null || true
done
for CMD in /boot/cmdline.txt /boot/firmware/cmdline.txt; do
    [ -f "$CMD" ] && grep -q "consoleblank" "$CMD" \
        || sed -i 's/$/ quiet logo.nologo consoleblank=0/' "$CMD" 2>/dev/null || true
done

# ── Fix Xwrapper (in case X is ever needed) ───────────────────────────────────
mkdir -p /etc/X11
echo -e "allowed_users=anybody\nneeds_root_rights=yes" > /etc/X11/Xwrapper.config

# ── Final summary ─────────────────────────────────────────────────────────────
echo ""
echo "=================================================================="
echo -e "  ${GREEN}Installation complete!${NC}"
echo "=================================================================="
echo ""
echo "  WiFi SSID  :  $SSID"
echo "  Password   :  $WIFI_PASS"
echo "  Web UI     :  http://$AP_IP"
echo "  Videos     :  $INSTALL_DIR/videos"
echo ""
echo "  Next step  :  sudo reboot"
echo ""
echo "  After reboot:"
echo "    1. Connect to '$SSID' WiFi"
echo "    2. Open http://$AP_IP in your browser"
echo "    3. Upload videos — they play immediately"
echo ""
