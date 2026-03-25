#!/bin/bash
# =============================================================================
#  VideoPlayer — Deactivate Access Point (return to WiFi client mode)
#
#  Use this to temporarily switch back to normal WiFi client mode,
#  e.g. to update software, change settings, or re-run setup.
#
#    sudo bash /opt/videoplayer/deactivate-ap.sh
#
#  To re-enable the player AP afterwards:
#    sudo bash /opt/videoplayer/activate-ap.sh
#    or simply: sudo reboot
# =============================================================================
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✔]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
info() { echo -e "${BLUE}[→]${NC} $1"; }

[ "$EUID" -ne 0 ] && { echo "Please run as root: sudo bash /opt/videoplayer/deactivate-ap.sh"; exit 1; }

echo ""
info "Stopping VideoPlayer AP services..."
systemctl stop videoplayer-display.service 2>/dev/null || true
systemctl stop videoplayer-web.service     2>/dev/null || true
systemctl stop hostapd                     2>/dev/null || true
systemctl stop dnsmasq                     2>/dev/null || true

info "Releasing wlan0 AP address..."
ip addr flush dev wlan0 2>/dev/null || true

# Remove the AP-active flag so reboot stays in WiFi client mode
rm -f /opt/videoplayer/.ap-active
log "AP mode deactivated (will not restart on reboot)"

# ── Restore WiFi client mode ──────────────────────────────────────────────────
if systemctl is-active --quiet NetworkManager 2>/dev/null || \
   systemctl is-enabled --quiet NetworkManager 2>/dev/null; then
    info "Restoring NetworkManager control of wlan0..."
    # Remove the unmanaged rule temporarily so NM takes wlan0 back
    if [ -f /etc/NetworkManager/conf.d/99-videoplayer-unmanaged.conf ]; then
        mv /etc/NetworkManager/conf.d/99-videoplayer-unmanaged.conf \
           /etc/NetworkManager/conf.d/99-videoplayer-unmanaged.conf.disabled
    fi
    systemctl reload NetworkManager
    sleep 2
    log "NetworkManager is now managing wlan0"
    echo ""
    echo "  WiFi is now in client mode. Reconnect using:"
    echo "  sudo nmtui"
    echo ""
else
    info "Restoring wpa_supplicant WiFi client..."
    systemctl start wpa_supplicant 2>/dev/null || true
    dhclient wlan0 2>/dev/null || true
    log "wpa_supplicant started"
    echo ""
    echo "  WiFi is now in client mode. Check connection with: ip addr show wlan0"
    echo ""
fi

warn "Run 'sudo bash /opt/videoplayer/activate-ap.sh' or reboot to re-enable the player AP."
echo ""
