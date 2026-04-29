#!/bin/bash
# harden-ollama.sh v2 — applies hardening drop-in to existing Ollama install
# Run AFTER `curl -fsSL https://ollama.com/install.sh | sh` succeeds.
#
# Usage:
#   chmod +x harden-ollama.sh
#   ./harden-ollama.sh 2>&1 | tee harden-ollama.log

set -euo pipefail
export LC_ALL=C LANG=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

log()  { echo -e "\n\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*" >&2; }
fail() { echo -e "\033[1;31m[✗]\033[0m $*" >&2; exit 1; }

# ─── Pre-flight ──────────────────────────────────────────────────
[[ $EUID -eq 0 ]] && fail "Run as your user, not root."
sudo -v || fail "sudo required."
systemctl list-unit-files | grep -q "^ollama.service" || fail "ollama.service not installed"

# Version compatibility note (env vars below need recent Ollama)
OLLAMA_VER=$(ollama --version 2>/dev/null | head -1 || true)
log "Pre-flight OK. ${OLLAMA_VER:-Ollama version unknown}"

DROPIN_DIR=/etc/systemd/system/ollama.service.d
DROPIN=${DROPIN_DIR}/override.conf

# ─── Backup existing override (FIX #1) ───────────────────────────
sudo mkdir -p "$DROPIN_DIR"
if [[ -f "$DROPIN" ]]; then
    BACKUP="${DROPIN}.bak.$(date +%Y%m%d-%H%M%S)"
    sudo cp "$DROPIN" "$BACKUP"
    log "Backed up existing override to $BACKUP"
fi

# ─── Write hardening drop-in ─────────────────────────────────────
log "Writing $DROPIN…"
sudo tee "$DROPIN" > /dev/null <<'EOF'
[Service]
# Telemetry / phone-home OFF
Environment="OLLAMA_NOHISTORY=1"
Environment="DO_NOT_TRACK=1"
Environment="OLLAMA_NOPRUNE=1"

# Localhost-only API (critical — prevents LAN exposure)
Environment="OLLAMA_HOST=127.0.0.1:11434"
Environment="OLLAMA_ORIGINS=http://127.0.0.1:*,http://localhost:*"

# Pi 3B+ sizing
Environment="OLLAMA_MAX_LOADED_MODELS=1"
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_KEEP_ALIVE=5m"
Environment="OLLAMA_FLASH_ATTENTION=0"

# Resource caps (1GB Pi, FunctionGemma needs ~786MB)
MemoryMax=800M
MemorySwapMax=200M
TasksMax=64
CPUQuota=350%

# Process / kernel hardening
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
SystemCallArchitectures=native
MemoryDenyWriteExecute=yes

# Network family restriction (FIX #5)
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

# Seccomp filter — drop privileged/dangerous syscalls (FIX #6)
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources @mount @debug @cpu-emulation @obsolete @raw-io @reboot @swap

# Egress lockdown (FIX #11) — allow loopback + GitHub/Cloudflare for model pulls
# After pulling models, comment IPAddressAllow lines to fully airgap.
IPAddressDeny=any
IPAddressAllow=127.0.0.0/8
IPAddressAllow=::1/128
IPAddressAllow=140.82.112.0/20
IPAddressAllow=185.199.108.0/22

# Allow model storage write (FIX #4)
ReadWritePaths=/usr/share/ollama

# File creation hygiene
UMask=0027

# Log rate limiting
LogRateLimitIntervalSec=30s
LogRateLimitBurst=200
EOF

sudo chown root:root "$DROPIN"
sudo chmod 0640 "$DROPIN"          # FIX #15 — tighter perms

# ─── Validate unit before restart (FIX #2 partial) ───────────────
log "Validating unit syntax…"
sudo systemd-analyze verify ollama.service 2>&1 | tee /tmp/sd-verify.log
grep -qE "Failed|error" /tmp/sd-verify.log && {
    warn "Unit validation reported issues — review /tmp/sd-verify.log before restart"
    fail "Refusing to restart with invalid unit"
}

# ─── Reload + restart ────────────────────────────────────────────
log "Reloading systemd and restarting ollama…"
sudo systemctl daemon-reload
sudo systemctl restart ollama

# Poll for active state (FIX #14)
log "Waiting for ollama to become active…"
for _ in {1..15}; do
    systemctl is-active --quiet ollama && break
    sleep 1
done
systemctl is-active --quiet ollama || {
    sudo journalctl -u ollama -n 30 --no-pager
    fail "ollama failed to become active within 15s"
}
echo "  ✓ ollama active"

# ─── Verify hardening flags actually applied (FIX #3) ────────────
log "Verifying hardening flags applied to runtime unit…"
check_flag() {
    local prop="$1" expected="$2"
    local actual
    actual=$(systemctl show -p "$prop" --value ollama)
    if [[ "$actual" == "$expected" ]]; then
        echo "  ✓ $prop=$actual"
    else
        fail "$prop expected=$expected actual=$actual"
    fi
}
check_flag NoNewPrivileges "yes"
check_flag ProtectSystem "strict"
check_flag ProtectHome "yes"
check_flag PrivateTmp "yes"
check_flag LockPersonality "yes"
check_flag MemoryDenyWriteExecute "yes"
[[ "$(systemctl show -p MemoryMax --value ollama)" != "infinity" ]] \
    || fail "MemoryMax not applied"
echo "  ✓ MemoryMax=$(systemctl show -p MemoryMax --value ollama)"

# ─── Verify localhost-only binding ───────────────────────────────
log "Verifying localhost-only binding…"
LISTEN=$(sudo ss -tlnp 2>/dev/null | grep ':11434' || true)
if echo "$LISTEN" | grep -q "127.0.0.1:11434"; then
    echo "  ✓ bound to 127.0.0.1:11434"
else
    echo "$LISTEN"
    fail "Not bound to 127.0.0.1 — hardening failed"
fi

# ─── Verify not LAN-reachable (FIX #7 — robust IP detection) ─────
log "Verifying not reachable on LAN…"
PI_IP=$(ip -4 -o addr show scope global 2>/dev/null \
    | awk '{print $4}' | cut -d/ -f1 | head -1)
if [[ -z "$PI_IP" ]]; then
    warn "No LAN IP detected, skipping reachability test"
elif curl -s --max-time 3 "http://$PI_IP:11434/api/version" >/dev/null 2>&1; then
    fail "API reachable at $PI_IP — should be localhost-only!"
else
    echo "  ✓ not reachable on $PI_IP"
fi

# ─── Verify API responds locally ─────────────────────────────────
log "Verifying API responds locally…"
curl --max-time 5 -fsS http://127.0.0.1:11434/api/version || fail "API did not respond"

# ─── Done ────────────────────────────────────────────────────────
log "Ollama hardening complete."
echo
echo "Pull FunctionGemma (~290MB):"
echo "  ollama pull functiongemma"
echo
echo "After pulling models, OPTIONAL: airgap egress fully:"
echo "  sudo systemctl edit ollama  # comment IPAddressAllow lines for GitHub/Cloudflare"
echo "  sudo systemctl restart ollama"
echo
echo "Logs:    sudo journalctl -u ollama -f"
echo "Status:  systemctl status ollama"
