#!/bin/bash
# enable-buses.sh — enable SPI (CE0+CE1) and I2C for the OLED + e-ink + sensors.
# Idempotent: safe to re-run. Persists across reboots (config.txt is boot config).
# Run as your user, not root. A reboot is required for the changes to take effect.
#
# Usage:
#   chmod +x enable-buses.sh
#   ./enable-buses.sh
#   sudo reboot

set -euo pipefail
export LC_ALL=C LANG=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

log()  { echo -e "\033[1;32m[+]\033[0m $*"; }
fail() { echo -e "\033[1;31m[x]\033[0m $*" >&2; exit 1; }

# ─── Pre-flight ──────────────────────────────────────────────────
[[ $EUID -eq 0 ]] && fail "Run as your user, not root (needed for the group add)."
sudo -v || fail "sudo required."

# Locate config.txt (Bookworm: /boot/firmware; older: /boot)
CONFIG=""
for p in /boot/firmware/config.txt /boot/config.txt; do
    [[ -f "$p" ]] && { CONFIG="$p"; break; }
done
[[ -z "$CONFIG" ]] && fail "config.txt not found"
log "Using $CONFIG"

# ─── Back up, then idempotently add the overlays ─────────────────
sudo cp "$CONFIG" "$CONFIG.bak.$(date +%Y%m%d-%H%M%S)"
add_line() { sudo grep -qxF "$1" "$CONFIG" || echo "$1" | sudo tee -a "$CONFIG" >/dev/null; }
add_line "# --- enable-buses.sh additions ---"
add_line "dtparam=spi=on"                          # SPI0 -> spidev0.0 (CE0) + spidev0.1 (CE1)
add_line "dtparam=i2c_arm=on"                      # I2C1 -> /dev/i2c-1
add_line "dtoverlay=i2c-sensor,bmp280,addr=0x76"   # Coral BMP280 enumeration fix
log "Overlays present in $CONFIG"

# ─── Device access without root (least privilege) ───────────────
sudo usermod -aG spi,i2c "$USER"
log "Added $USER to groups: spi, i2c (active after reboot/re-login)"

# ─── Done ────────────────────────────────────────────────────────
log "Bus enable complete. Reboot required:"
echo "  sudo reboot"
echo
echo "Post-reboot verification:"
echo "  ls /dev/spidev0.*                       # expect spidev0.0 AND spidev0.1"
echo "  ls /dev/i2c-1"
echo "  i2cdetect -y 1                          # sensors at 0x40, 0x45, 0x76 ..."
echo "  id | tr ',' '\\n' | grep -E 'spi|i2c'    # both groups active"
