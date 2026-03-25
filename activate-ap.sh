#!/bin/bash
# =============================================================================
#  VideoPlayer — Activate Access Point (RPi 3 / WiFi-only setup)
#
#  Use this script if you set up your Pi over WiFi (no ethernet).
#  Running setup.sh will have configured everything correctly, but the AP
#  cannot start while wlan0 is connected to your home WiFi.
#
#  When you are ready to switch the Pi into kiosk/player mode:
#
#    sudo bash /opt/videoplayer/activate-ap.sh
#
#  WARNING: This will disconnect you from WiFi immediately.
#  Make sure you have finished all setup before running this.
#  After running, connect to the 'VideoPlayer' WiFi to manage the player.
#
#  To reverse this (go back to normal WiFi client mode):
#    sudo bash /opt/videoplayer/deactivate-ap.sh
# =============================================================================
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✔]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✘]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[→]${NC} $1"; }

[ "$EUID" -ne 0 ] && err "Please run as root: sudo bash /opt/videoplayer/activate-ap.sh"

INSTALL_DIR="/opt/videoplayer"
AP_IP="192.168.4.1"
SSID=$(grep "^ssid=" /etc/hostapd/hostapd.conf 2>/dev/null | cut -d= -f2 || echo "VideoPlayer")
WIFI_COUNTRY=$(grep "^country_code=" /etc/hostapd/hostapd.conf 2>/dev/null | cut -d= -f2 || echo "")

[ -f /etc/hostapd/hostapd.conf ] || err "hostapd not configured. Did setup.sh complete successfully?"

echo ""
echo "  ╔══════════════════════════════════════════════════════════════╗"
echo "  ║  VideoPlayer — Activating Access Point Mode                  ║"
echo "  ╠══════════════════════════════════════════════════════════════╣"
echo "  ║  WARNING: Your WiFi connection will be dropped immediately.  ║"
echo "  ║  This is expected. Connect to '$SSID' afterwards.       ║"
echo "  ╚══════════════════════════════════════════════════════════════╝"
echo ""

# Give the user 5 seconds to see the warning (and a chance to Ctrl+C)
echo -n "  Starting in 5 seconds... (Ctrl+C to cancel)"
for i in 5 4 3 2 1; do
    echo -n " $i"
    sleep 1
done
echo ""
echo ""

# ── Detect network stack ──────────────────────────────────────────────────────
if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    NET_STACK="networkmanager"
else
    NET_STACK="dhcpcd"
fi
info "Network stack: $NET_STACK"

# ── Apply regulatory domain ───────────────────────────────────────────────────
if [ -n "$WIFI_COUNTRY" ]; then
    iw reg set "$WIFI_COUNTRY" 2>/dev/null || true
fi

# ── Disconnect from existing WiFi client connection ───────────────────────────
info "Disconnecting from WiFi client..."

if [ "$NET_STACK" = "networkmanager" ]; then
    # Tell NM to stop managing wlan0 entirely
    # (the unmanaged rule from setup.sh should already be in place,
    #  but we force a reload here to make sure it takes effect)
    nmcli dev disconnect wlan0 2>/dev/null || true
    systemctl reload NetworkManager 2>/dev/null || true
    sleep 2
else
    # dhcpcd: remove any existing wlan0 lease and stop wpa_supplicant on wlan0
    wpa_cli -i wlan0 disconnect 2>/dev/null || true
    wpa_cli -i wlan0 terminate 2>/dev/null || true
    dhclient -r wlan0 2>/dev/null || true
    ip addr flush dev wlan0 2>/dev/null || true
fi

# ── Bring up the AP ───────────────────────────────────────────────────────────
info "Configuring wlan0 as access point ($AP_IP)..."
ip link set wlan0 up
ip addr flush dev wlan0 2>/dev/null || true
ip addr add "${AP_IP}/24" dev wlan0 2>/dev/null || true

info "Starting hostapd..."
systemctl stop hostapd 2>/dev/null || true
sleep 1
systemctl start hostapd

info "Starting dnsmasq..."
systemctl stop dnsmasq 2>/dev/null || true
sleep 1
systemctl start dnsmasq

# ── Enable and start all videoplayer services ─────────────────────────────────
info "Starting VideoPlayer services..."
systemctl start videoplayer-ap.service  2>/dev/null || true
systemctl start videoplayer-web.service
systemctl start videoplayer-display.service

# ── Verify ────────────────────────────────────────────────────────────────────
sleep 2
AP_OK=0
WEB_OK=0
PLAYER_OK=0

systemctl is-active --quiet hostapd && AP_OK=1
systemctl is-active --quiet videoplayer-web.service && WEB_OK=1
systemctl is-active --quiet videoplayer-display.service && PLAYER_OK=1

echo ""
echo "  ╔══════════════════════════════════════════════════════════════╗"
echo "  ║  Status                                                      ║"
echo "  ╠══════════════════════════════════════════════════════════════╣"
[ "$AP_OK"     = "1" ] && echo -e "  ║  ${GREEN}✔${NC} Access point (hostapd)        active                     ║" \
                       || echo -e "  ║  ${RED}✘${NC} Access point (hostapd)        FAILED                     ║"
[ "$WEB_OK"    = "1" ] && echo -e "  ║  ${GREEN}✔${NC} Web interface                  active                     ║" \
                       || echo -e "  ║  ${RED}✘${NC} Web interface                  FAILED                     ║"
[ "$PLAYER_OK" = "1" ] && echo -e "  ║  ${GREEN}✔${NC} Video player                   active                     ║" \
                       || echo -e "  ║  ${RED}✘${NC} Video player                   FAILED                     ║"
echo "  ╠══════════════════════════════════════════════════════════════╣"
echo "  ║                                                              ║"
printf "  ║  WiFi SSID : %-47s║\n" "$SSID"
printf "  ║  Web UI    : %-47s║\n" "http://$AP_IP"
echo "  ║                                                              ║"
echo "  ║  Connect your device to '$SSID' WiFi, then          ║"
echo "  ║  open http://$AP_IP to upload and manage videos.        ║"
echo "  ║                                                              ║"
echo "  ╚══════════════════════════════════════════════════════════════╝"
echo ""

# Hint if anything failed
if [ "$AP_OK" = "0" ] || [ "$WEB_OK" = "0" ] || [ "$PLAYER_OK" = "0" ]; then
    warn "One or more services failed to start. Check logs:"
    echo "  sudo journalctl -u hostapd -n 20"
    echo "  tail -20 /opt/videoplayer/logs/web.log"
    echo "  tail -20 /opt/videoplayer/logs/player.log"
fi
