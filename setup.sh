#!/bin/bash
# =============================================================================
#  Raspberry Pi VideoPlayer — one-line installer
#  Compatible with Raspberry Pi 4 (Bullseye/Bookworm) and Pi 5 (Bookworm/Trixie)
#
#  Usage:
#    curl -fsSL https://raw.githubusercontent.com/stefanskotte/rpi-videoplayer/main/setup.sh | sudo WIFI_COUNTRY=GB bash
#    curl -fsSL https://raw.githubusercontent.com/stefanskotte/rpi-videoplayer/main/setup.sh | sudo WIFI_COUNTRY=DK bash
#    curl -fsSL https://raw.githubusercontent.com/stefanskotte/rpi-videoplayer/main/setup.sh | sudo WIFI_COUNTRY=DE bash
# =============================================================================
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✔]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✘]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[→]${NC} $1"; }

[ "$EUID" -ne 0 ] && err "Please run as root. Example:
  curl -fsSL https://raw.githubusercontent.com/stefanskotte/rpi-videoplayer/main/setup.sh | sudo WIFI_COUNTRY=GB bash"

# ── Raspberry Pi OS Lite check ────────────────────────────────────────────────
# The videoplayer uses mpv in DRM/KMS mode and takes over the display directly.
# A desktop environment (display manager, compositor, Wayland/X session) will
# conflict with DRM access and prevent video from showing on screen.
# This check runs BEFORE anything is installed so we fail fast.

check_lite_os() {
    local desktop_signals=0
    local reasons=()

    # Signal 1: pi-gen stage in issue.txt
    # stage2 = Lite, stage4 = Desktop, stage5 = Desktop + Recommended software
    local issue_file=""
    for f in /boot/firmware/issue.txt /boot/issue.txt; do
        [ -f "$f" ] && issue_file="$f" && break
    done
    if [ -n "$issue_file" ]; then
        if grep -q "stage4\|stage5" "$issue_file" 2>/dev/null; then
            desktop_signals=$((desktop_signals + 3))
            reasons+=("issue.txt reports $(grep -o 'stage[0-9]' "$issue_file") (Desktop)")
        elif grep -q "stage2" "$issue_file" 2>/dev/null; then
            log "OS variant: Raspberry Pi OS Lite (stage2) ✓"
        fi
    fi

    # Signal 2: systemd default target
    local target
    target=$(systemctl get-default 2>/dev/null || echo "unknown")
    if [ "$target" = "graphical.target" ]; then
        desktop_signals=$((desktop_signals + 3))
        reasons+=("systemd default target is graphical.target (desktop autostart enabled)")
    fi

    # Signal 3: active display manager
    for dm in lightdm gdm3 sddm xdm; do
        if systemctl is-active --quiet "$dm" 2>/dev/null; then
            desktop_signals=$((desktop_signals + 3))
            reasons+=("display manager '$dm' is running")
            break
        fi
    done

    # Signal 4: desktop packages installed
    for pkg in rpd-plym-splash lxde-core xfce4 gnome-shell labwc wayfire weston mutter openbox-lxde; do
        if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
            desktop_signals=$((desktop_signals + 2))
            reasons+=("desktop package '$pkg' is installed")
            break
        fi
    done

    # Signal 5: active display session
    if [ -n "$DISPLAY" ] || [ -n "$WAYLAND_DISPLAY" ]; then
        desktop_signals=$((desktop_signals + 2))
        reasons+=("active display session detected (DISPLAY=$DISPLAY WAYLAND_DISPLAY=$WAYLAND_DISPLAY)")
    fi

    # Score >= 3 means we're confident a desktop is present
    if [ "$desktop_signals" -ge 3 ]; then
        echo ""
        echo -e "${RED}  ╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}  ║  ✘  Desktop OS detected — Lite required                      ║${NC}"
        echo -e "${RED}  ╠══════════════════════════════════════════════════════════════╣${NC}"
        for reason in "${reasons[@]}"; do
            printf "${RED}  ║  • %-60s║${NC}\n" "$reason"
        done
        echo -e "${RED}  ╠══════════════════════════════════════════════════════════════╣${NC}"
        echo -e "${RED}  ║  VideoPlayer uses mpv in DRM/KMS mode and takes over the     ║${NC}"
        echo -e "${RED}  ║  display directly. A running desktop will block DRM access   ║${NC}"
        echo -e "${RED}  ║  and no video will appear on screen.                         ║${NC}"
        echo -e "${RED}  ║                                                              ║${NC}"
        echo -e "${RED}  ║  Please flash Raspberry Pi OS Lite (64-bit) and retry:       ║${NC}"
        echo -e "${RED}  ║  https://www.raspberrypi.com/software/                       ║${NC}"
        echo -e "${RED}  ╚══════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        # Allow override for advanced users who know what they're doing
        if [ "${FORCE_INSTALL:-0}" = "1" ]; then
            warn "FORCE_INSTALL=1 set — skipping OS check. You are on your own!"
        else
            echo -e "  To override (advanced):  ${YELLOW}curl ... | sudo WIFI_COUNTRY=XX FORCE_INSTALL=1 bash${NC}"
            echo ""
            exit 1
        fi
    else
        log "OS check passed — no desktop environment detected ✓"
    fi
}

check_lite_os

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

# ── WiFi Country ──────────────────────────────────────────────────────────────
# Required for legal WiFi operation. Controls which channels/power are permitted.
# Common codes: GB DK DE US FR NL SE NO FI AU CA JP

ask_wifi_country() {
    if [ ! -t 0 ]; then
        # Non-interactive (piped from curl) — must use env variable
        if [ -z "$WIFI_COUNTRY" ]; then
            echo ""
            echo -e "${RED}  ╔══════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${RED}  ║  WiFi country code required!                                 ║${NC}"
            echo -e "${RED}  ║  Re-run with your 2-letter ISO country code, e.g.:           ║${NC}"
            echo -e "${RED}  ║                                                              ║${NC}"
            echo -e "${RED}  ║  curl -fsSL .../setup.sh | sudo WIFI_COUNTRY=GB bash         ║${NC}"
            echo -e "${RED}  ║  curl -fsSL .../setup.sh | sudo WIFI_COUNTRY=DK bash         ║${NC}"
            echo -e "${RED}  ║  curl -fsSL .../setup.sh | sudo WIFI_COUNTRY=DE bash         ║${NC}"
            echo -e "${RED}  ║  curl -fsSL .../setup.sh | sudo WIFI_COUNTRY=US bash         ║${NC}"
            echo -e "${RED}  ╚══════════════════════════════════════════════════════════════╝${NC}"
            echo ""
            exit 1
        fi
    else
        # Interactive — prompt with auto-detected default
        echo "  WiFi Country Code"
        echo "  ─────────────────────────────────────────────────────────────"
        echo "  Common codes: GB  DK  DE  US  FR  NL  SE  NO  FI  AU  CA  JP"
        echo ""
        EXISTING=$(raspi-config nonint get_wifi_country 2>/dev/null \
            || grep "^country=" /etc/wpa_supplicant/wpa_supplicant.conf 2>/dev/null | cut -d= -f2 \
            || nmcli -t -f 802-11-wireless.reg-domain con show --active 2>/dev/null | cut -d: -f2 \
            || echo "")
        if [ -n "$EXISTING" ]; then
            echo -e "  Detected existing country: ${GREEN}${EXISTING}${NC}"
            echo -n "  Enter country code [${EXISTING}]: "
        else
            echo -n "  Enter your 2-letter country code (e.g. GB, DK, DE, US): "
        fi
        read -r INPUT
        INPUT=$(echo "$INPUT" | tr '[:lower:]' '[:upper:]' | tr -d ' ')
        [ -z "$INPUT" ] && [ -n "$EXISTING" ] && INPUT="$EXISTING"
        WIFI_COUNTRY="$INPUT"
    fi

    WIFI_COUNTRY=$(echo "$WIFI_COUNTRY" | tr '[:lower:]' '[:upper:]' | tr -d ' ')
    echo "$WIFI_COUNTRY" | grep -qE '^[A-Z]{2}$' \
        || err "Invalid country code '$WIFI_COUNTRY' — must be 2 letters (e.g. GB, DK, US)"
    log "WiFi country: $WIFI_COUNTRY"
}

ask_wifi_country

# ── Detect hardware ───────────────────────────────────────────────────────────
info "Detecting hardware..."
PI_MODEL=$(cat /proc/device-tree/model 2>/dev/null || echo "unknown")

# Detect if this is a WiFi-only device (no ethernet, e.g. RPi 3)
# On such devices we CANNOT start the AP now because wlan0 is the only network
# interface — starting AP would kill this SSH session mid-install.
WIFI_ONLY=0
if ! ip link show eth0 &>/dev/null && ! ip link show end0 &>/dev/null; then
    # No ethernet interface found — check if we're connected via wlan0
    if ip route | grep -q wlan0; then
        WIFI_ONLY=1
        warn "WiFi-only device detected (no ethernet) — AP will NOT be started now."
        warn "Run 'sudo bash ${INSTALL_DIR}/activate-ap.sh' when ready to switch to player mode."
    fi
fi

# DRM card: RPi 5 uses card1 for HDMI output, RPi 3/4 use card0
if echo "$PI_MODEL" | grep -q "Raspberry Pi 5"; then
    DRM_CARD="/dev/dri/card1"
    log "Detected: Raspberry Pi 5 (DRM: card1)"
elif echo "$PI_MODEL" | grep -q "Raspberry Pi 3"; then
    DRM_CARD="/dev/dri/card0"
    log "Detected: Raspberry Pi 3 (DRM: card0) — use H.264 content at 1080p or lower"
else
    DRM_CARD="/dev/dri/card0"
    log "Detected: Raspberry Pi 4 (DRM: card0)"
fi

# Network stack: Bookworm/Trixie (RPi 5, newer RPi 4) uses NetworkManager.
# Bullseye and older (most RPi 4) use dhcpcd.
# We detect which is active and use the right AP configuration method.
if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    NET_STACK="networkmanager"
    log "Network stack: NetworkManager (Bookworm/Trixie)"
elif systemctl is-active --quiet dhcpcd 2>/dev/null || \
     systemctl is-enabled --quiet dhcpcd 2>/dev/null; then
    NET_STACK="dhcpcd"
    log "Network stack: dhcpcd (Bullseye)"
else
    # Default to NetworkManager on fresh installs — it's the modern default
    NET_STACK="networkmanager"
    warn "Could not detect network stack — assuming NetworkManager"
fi

# Boot config paths: RPi 5 uses /boot/firmware/, RPi 4 uses /boot/
BOOT_DIR=""
for d in /boot/firmware /boot; do
    [ -f "$d/config.txt" ] && BOOT_DIR="$d" && break
done
[ -z "$BOOT_DIR" ] && warn "Could not find boot config directory" || log "Boot config: $BOOT_DIR"

# ── Dependencies ──────────────────────────────────────────────────────────────
info "Updating packages..."
apt-get update -qq

info "Installing dependencies..."
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    mpv python3 python3-pip python3-flask python3-watchdog python3-pil \
    hostapd dnsmasq curl git net-tools iw
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
mkdir -p "$INSTALL_DIR"/{videos,web/templates,web/static,logs}

# ── Download application files ────────────────────────────────────────────────
info "Downloading application files from GitHub..."
download() { curl -fsSL "$REPO/$1" -o "$2" || err "Failed to download $1"; }
download "player.py"                "$INSTALL_DIR/player.py"
download "generate_splash.py"       "$INSTALL_DIR/generate_splash.py"
download "web/app.py"               "$INSTALL_DIR/web/app.py"
download "web/templates/index.html" "$INSTALL_DIR/web/templates/index.html"
download "activate-ap.sh"           "$INSTALL_DIR/activate-ap.sh"
download "deactivate-ap.sh"         "$INSTALL_DIR/deactivate-ap.sh"
chmod +x "$INSTALL_DIR/player.py" \
         "$INSTALL_DIR/activate-ap.sh" \
         "$INSTALL_DIR/deactivate-ap.sh"

# Pre-create runtime files so systemd doesn't create them as root on first write.
# The chown -R below transfers ownership to the service user.
touch "$INSTALL_DIR/logs/player.log" \
      "$INSTALL_DIR/logs/web.log" \
      "$INSTALL_DIR/state.json" \
      "$INSTALL_DIR/.reload" \
      "$INSTALL_DIR/.stop"

chown -R "$SERVICE_USER":"$SERVICE_USER" "$INSTALL_DIR"
log "Application files installed"

# ── Generate splash screen ────────────────────────────────────────────────────
info "Generating splash screen..."
sudo -u "$SERVICE_USER" python3 "$INSTALL_DIR/generate_splash.py" \
    && log "Splash screen generated" \
    || warn "Splash generation failed (non-fatal)"

# ── WiFi country — set system-wide ───────────────────────────────────────────
info "Setting WiFi regulatory domain to $WIFI_COUNTRY..."
raspi-config nonint do_wifi_country "$WIFI_COUNTRY" 2>/dev/null || true
iw reg set "$WIFI_COUNTRY" 2>/dev/null || true
if [ -f /etc/default/crda ]; then
    sed -i "s/^REGDOMAIN=.*/REGDOMAIN=${WIFI_COUNTRY}/" /etc/default/crda \
        || echo "REGDOMAIN=${WIFI_COUNTRY}" >> /etc/default/crda
fi
log "Regulatory domain set"

# ── Access Point configuration ────────────────────────────────────────────────
info "Configuring WiFi access point (stack: $NET_STACK)..."
systemctl stop hostapd dnsmasq 2>/dev/null || true
systemctl unmask hostapd dnsmasq

# hostapd config (same for both stacks)
cat > /etc/hostapd/hostapd.conf << EOF
interface=wlan0
driver=nl80211
ssid=${SSID}
hw_mode=g
channel=6
country_code=${WIFI_COUNTRY}
ieee80211d=1
wmm_enabled=0
auth_algs=1
wpa=2
wpa_passphrase=${WIFI_PASS}
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF
sed -i 's|#DAEMON_CONF=""|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' \
    /etc/default/hostapd 2>/dev/null || true

# dnsmasq config (same for both stacks)
cat > /etc/dnsmasq.conf << EOF
interface=wlan0
dhcp-range=192.168.4.10,192.168.4.50,255.255.255.0,24h
domain=local
address=/videoplayer.local/${AP_IP}
EOF

if [ "$NET_STACK" = "networkmanager" ]; then
    # ── NetworkManager path (RPi 5 / Bookworm / Trixie) ──────────────────────
    # Tell NM to leave wlan0 alone so hostapd can manage it directly.
    # We create an unmanaged rule for wlan0.
    mkdir -p /etc/NetworkManager/conf.d
    cat > /etc/NetworkManager/conf.d/99-videoplayer-unmanaged.conf << EOF
[keyfile]
unmanaged-devices=interface-name:wlan0
EOF

    # Set static IP via ip command on boot (NM won't do it for unmanaged iface)
    cat > "$INSTALL_DIR/ap-start.sh" << APEOF
#!/bin/bash
# On WiFi-only devices (no ethernet), ap-start.sh only activates
# if .ap-active flag exists (set by activate-ap.sh).
# This prevents killing the only network connection on reboot
# before the user is ready to switch to kiosk mode.
HAS_ETH=0
ip link show eth0 &>/dev/null && HAS_ETH=1
ip link show end0 &>/dev/null && HAS_ETH=1

if [ "\$HAS_ETH" = "0" ] && [ ! -f /opt/videoplayer/.ap-active ]; then
    echo "[videoplayer-ap] WiFi-only device, .ap-active not set — skipping AP startup."
    echo "[videoplayer-ap] Run: sudo bash /opt/videoplayer/activate-ap.sh when ready."
    exit 0
fi

iw reg set ${WIFI_COUNTRY} 2>/dev/null || true
ip link set wlan0 up
ip addr flush dev wlan0 2>/dev/null || true
ip addr add ${AP_IP}/24 dev wlan0 2>/dev/null || true
systemctl restart NetworkManager 2>/dev/null || true
sleep 1
systemctl start hostapd
systemctl start dnsmasq
APEOF

    log "NetworkManager: wlan0 set to unmanaged"

else
    # ── dhcpcd path (RPi 4 / Bullseye) ───────────────────────────────────────
    # Static IP via dhcpcd.conf, suppress wpa_supplicant hook on wlan0
    if ! grep -q "VideoPlayer" /etc/dhcpcd.conf 2>/dev/null; then
        cat >> /etc/dhcpcd.conf << EOF

# VideoPlayer Access Point
interface wlan0
    static ip_address=${AP_IP}/24
    nohook wpa_supplicant
EOF
    fi

    cat > "$INSTALL_DIR/ap-start.sh" << APEOF
#!/bin/bash
# On WiFi-only devices (no ethernet), ap-start.sh only activates
# if .ap-active flag exists (set by activate-ap.sh).
HAS_ETH=0
ip link show eth0 &>/dev/null && HAS_ETH=1
ip link show end0 &>/dev/null && HAS_ETH=1

if [ "\$HAS_ETH" = "0" ] && [ ! -f /opt/videoplayer/.ap-active ]; then
    echo "[videoplayer-ap] WiFi-only device, .ap-active not set — skipping AP startup."
    echo "[videoplayer-ap] Run: sudo bash /opt/videoplayer/activate-ap.sh when ready."
    exit 0
fi

iw reg set ${WIFI_COUNTRY} 2>/dev/null || true
ip link set wlan0 up
ip addr add ${AP_IP}/24 dev wlan0 2>/dev/null || true
systemctl start hostapd
systemctl start dnsmasq
APEOF

    log "dhcpcd: wlan0 static IP configured"
fi

cat > "$INSTALL_DIR/ap-stop.sh" << 'APEOF'
#!/bin/bash
systemctl stop hostapd dnsmasq
ip addr del 192.168.4.1/24 dev wlan0 2>/dev/null || true
APEOF

chmod +x "$INSTALL_DIR/ap-start.sh" "$INSTALL_DIR/ap-stop.sh"
chown "$SERVICE_USER":"$SERVICE_USER" \
    "$INSTALL_DIR/ap-start.sh" "$INSTALL_DIR/ap-stop.sh"
log "Access point configured"

# ── systemd services ──────────────────────────────────────────────────────────
info "Installing systemd services..."

cat > /etc/systemd/system/videoplayer-ap.service << EOF
[Unit]
Description=VideoPlayer WiFi Access Point
After=network.target
$([ "$NET_STACK" = "networkmanager" ] && echo "After=NetworkManager.service")

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
systemctl enable videoplayer-ap.service videoplayer-web.service videoplayer-display.service
log "Services enabled"

# ── Boot config ───────────────────────────────────────────────────────────────
info "Configuring boot settings..."
if [ -n "$BOOT_DIR" ]; then
    grep -q "disable_splash" "$BOOT_DIR/config.txt" \
        || echo "disable_splash=1" >> "$BOOT_DIR/config.txt"
    grep -q "consoleblank" "$BOOT_DIR/cmdline.txt" \
        || sed -i 's/$/ quiet logo.nologo consoleblank=0/' "$BOOT_DIR/cmdline.txt"
    log "Boot config updated ($BOOT_DIR)"
fi

mkdir -p /etc/X11
echo -e "allowed_users=anybody\nneeds_root_rights=yes" > /etc/X11/Xwrapper.config

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=================================================================="
echo -e "  ${GREEN}Installation complete!${NC}"
echo "=================================================================="
echo ""
echo "  Hardware     :  $PI_MODEL"
echo "  Network      :  $NET_STACK"
echo "  DRM device   :  $DRM_CARD"
echo "  WiFi Country :  $WIFI_COUNTRY"
echo "  WiFi SSID    :  $SSID"
echo "  WiFi Password:  $WIFI_PASS"
echo "  Web UI       :  http://$AP_IP"
echo ""

if [ "$WIFI_ONLY" = "1" ]; then
    echo -e "  ${YELLOW}WiFi-only device (no ethernet) — special steps required:${NC}"
    echo ""
    echo "  You are currently connected via WiFi. Starting the access"
    echo "  point now would disconnect you. Instead:"
    echo ""
    echo "  1. When ready to use the player, run:"
    echo -e "     ${GREEN}sudo bash $INSTALL_DIR/activate-ap.sh${NC}"
    echo ""
    echo "  2. This will drop your WiFi connection and start the AP."
    echo "     Connect to '$SSID' WiFi and open http://$AP_IP"
    echo ""
    echo "  To temporarily return to WiFi client mode later:"
    echo "     sudo bash $INSTALL_DIR/deactivate-ap.sh"
else
    echo "  → sudo reboot"
    echo ""
    echo "  After reboot:"
    echo "    1. Connect to '$SSID' WiFi"
    echo "    2. Open http://$AP_IP in your browser"
    echo "    3. Upload videos — they play immediately"
fi
echo ""
