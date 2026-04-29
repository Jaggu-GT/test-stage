#!/bin/bash
# harden-pi.sh — Pi 3B+ baseline hardening
# Target: fresh Raspberry Pi OS Lite (64-bit) post-first-boot.
# Run as your user, not root.
#
# Usage:
#   chmod +x harden-pi.sh
#   ./harden-pi.sh 2>&1 | tee harden.log
#   sudo reboot

set -euo pipefail
export LC_ALL=C LANG=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

log()  { echo -e "\n\033[1;32m[+]\033[0m $*"; }
fail() { echo -e "\033[1;31m[✗]\033[0m $*" >&2; exit 1; }

# ─── Pre-flight ──────────────────────────────────────────────────
[[ $EUID -eq 0 ]] && fail "Run as your user, not root."
ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 || fail "No internet."
sudo -v || fail "sudo required."
log "Pre-flight OK. User: $(whoami)."

# Sudo keepalive — refresh credential cache while script runs (FIX #1)
( while true; do sudo -n true 2>/dev/null; sleep 60; kill -0 "$$" 2>/dev/null || exit; done ) &
KEEPALIVE_PID=$!
trap 'kill $KEEPALIVE_PID 2>/dev/null || true' EXIT

# ─── 1. System update — apply latest security patches ────────────
log "Updating system…"
sudo apt update 2>&1 | tee /tmp/apt-update.log
grep -qE "^(W|E):" /tmp/apt-update.log && fail "apt update had errors (signature/repo)"  # FIX #3
sudo apt full-upgrade -y
sudo apt autoremove --purge -y
sudo apt clean

# ─── 2. Purge cloud-init — unused phone-home boot agent ──────────
log "Purging cloud-init…"
sudo apt purge cloud-init -y 2>/dev/null || true
sudo rm -rf /etc/cloud /var/lib/cloud

# ─── 3. ufw firewall — default deny inbound, allow outbound ──────
log "Configuring ufw…"
sudo apt install -y --no-install-recommends ufw
sudo ufw --force default deny incoming
sudo ufw --force default allow outgoing
sudo ufw logging medium
sudo ufw --force enable
sudo ufw status verbose | grep -q "Status: active" || fail "ufw not active"

# ─── 4. Disable unneeded services — reduce attack surface ────────
log "Disabling unneeded services…"
for svc in bluetooth.service hciuart.service \
           avahi-daemon.service avahi-daemon.socket \
           triggerhappy.service triggerhappy.socket \
           ModemManager.service; do
    sudo systemctl disable --now "$svc" 2>/dev/null || true
done
sudo systemctl disable NetworkManager-wait-online.service 2>/dev/null || true

# ─── 5. SSH masked — no remote login surface ─────────────────────
log "Masking SSH (re-enable with: systemctl unmask ssh && systemctl enable --now ssh)…"
sudo systemctl disable --now ssh.service 2>/dev/null || true
sudo systemctl mask ssh.service 2>/dev/null || true

# ─── 6. Kernel hardening — sysctl: net + kernel + fs protections ─
log "Applying sysctl hardening…"
sudo tee /etc/sysctl.d/99-hardening.conf > /dev/null <<'EOF'
# Network: drop spoofed/redirected/source-routed packets
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.log_martians = 1
# Kernel: hide internals from non-root
kernel.yama.ptrace_scope = 1
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.unprivileged_bpf_disabled = 1
# FS: protect against symlink/hardlink TOCTOU + SUID dumps
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
fs.suid_dumpable = 0
# SD wear + zram-friendly swap behavior  (FIX #2: 60 not 100)
vm.dirty_writeback_centisecs = 1500
vm.dirty_expire_centisecs = 6000
vm.swappiness = 60
EOF
sudo sysctl --system >/dev/null
[[ "$(sysctl -n kernel.yama.ptrace_scope)" == "1" ]] || fail "sysctl not applied"

# ─── 7. zram — compressed RAM swap, replaces SD-wearing disk swap ─
log "Setting up zram…"
sudo apt install -y --no-install-recommends zram-tools
sudo tee /etc/default/zramswap > /dev/null <<'EOF'
ALGO=zstd
PERCENT=50
PRIORITY=100
EOF
sudo systemctl enable --now zramswap
sudo swapoff -a 2>/dev/null || true
sudo systemctl disable --now dphys-swapfile 2>/dev/null || true

# ─── 8. Firmware tuning — disable unused hardware ────────────────
log "Tuning firmware (config.txt)…"
CONFIG=""
for path in /boot/firmware/config.txt /boot/config.txt; do
    [[ -f "$path" ]] && { CONFIG="$path"; break; }
done
[[ -z "$CONFIG" ]] && fail "config.txt not found"
sudo cp "$CONFIG" "$CONFIG.bak.$(date +%Y%m%d-%H%M%S)"
add_line() { sudo grep -qxF "$1" "$CONFIG" || echo "$1" | sudo tee -a "$CONFIG" >/dev/null; }
add_line "# --- harden-pi.sh additions ---"
add_line "dtparam=audio=off"
add_line "dtoverlay=disable-bt"
add_line "dtparam=watchdog=on"

# ─── 9. Auto security updates — patches applied nightly ──────────
log "Enabling unattended-upgrades…"
sudo apt install -y --no-install-recommends unattended-upgrades
sudo tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
sudo tee /etc/apt/apt.conf.d/50unattended-upgrades.local > /dev/null <<'EOF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";
EOF

# ─── 10. Sudo tightening — short cache, log, fewer retries ───────
log "Tightening sudo…"
sudo tee /etc/sudoers.d/timeout > /dev/null <<'EOF'
Defaults timestamp_timeout=5
Defaults passwd_tries=3
Defaults logfile="/var/log/sudo.log"
EOF
sudo chmod 0440 /etc/sudoers.d/timeout
sudo visudo -c -f /etc/sudoers.d/timeout >/dev/null || fail "sudoers syntax invalid"

# ─── 11. umask 027 — new files not world-readable ────────────────
log "Setting umask 027…"
sudo sed -i 's/^UMASK\s\+.*/UMASK\t\t027/' /etc/login.defs
echo 'umask 027' | sudo tee /etc/profile.d/umask.sh > /dev/null
sudo chmod +x /etc/profile.d/umask.sh

# ─── 12. AppArmor — mandatory access control on top of DAC ───────
log "Ensuring AppArmor active…"
sudo apt install -y --no-install-recommends apparmor apparmor-utils apparmor-profiles
sudo systemctl enable --now apparmor

# ─── 13. Hardware watchdog — auto-reboot on hang ─────────────────
log "Configuring watchdog…"
sudo apt install -y --no-install-recommends watchdog
[[ -f /etc/watchdog.conf ]] && {
    sudo sed -i \
        -e 's|^#\s*watchdog-device.*|watchdog-device = /dev/watchdog|' \
        -e 's|^#\s*max-load-1.*|max-load-1 = 24|' \
        /etc/watchdog.conf
    sudo systemctl enable watchdog
}

# ─── 14. auditd — kernel-level syscall + file-watch logging ──────
log "Setting up auditd…"
sudo apt install -y --no-install-recommends auditd audispd-plugins
sudo tee /etc/audit/rules.d/hardening.rules > /dev/null <<'EOF'
-D
-b 8192
-f 1
# Identity files
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/sudoers -p wa -k privilege
-w /etc/sudoers.d/ -p wa -k privilege
# Network/SSH config
-w /etc/ssh/sshd_config -p wa -k ssh_config
-w /etc/NetworkManager/ -p wa -k network
# Kernel modules + sensitive syscalls
-a always,exit -F arch=b64 -S init_module,delete_module,finit_module -k modules
-a always,exit -F arch=b64 -S execve -F euid=0 -k root_exec
-a always,exit -F arch=b64 -S mount,umount2 -k mount_changes
-a always,exit -F arch=b64 -S ptrace -k ptrace_calls
-a always,exit -F arch=b64 -S setuid,setgid -k privilege_change
# Time tampering
-a always,exit -F arch=b64 -S adjtimex,settimeofday,clock_settime -k time_change
EOF
sudo systemctl enable --now auditd
sudo augenrules --load 2>/dev/null || true

# ─── 15. debsums — verify package files match Debian signatures ──
log "Installing debsums (run scan manually after reboot: sudo debsums -s)…"
sudo apt install -y --no-install-recommends debsums
sudo tee /etc/cron.weekly/debsums-check > /dev/null <<'EOF'
#!/bin/sh
debsums -s 2>&1 | logger -t debsums
EOF
sudo chmod +x /etc/cron.weekly/debsums-check

# ─── 16. NetworkManager Wi-Fi creds locked to root ───────────────
log "Locking NetworkManager creds…"
NM_DIR=/etc/NetworkManager/system-connections
[[ -d "$NM_DIR" ]] && {
    sudo chmod 700 "$NM_DIR"
    sudo find "$NM_DIR" -type f -exec chmod 600 {} \;
}

# ─── Done ────────────────────────────────────────────────────────
log "Hardening complete. Reboot required:"
echo "  sudo reboot"
echo
echo "Post-reboot verification:"
echo "  sudo ss -tulnp                          # nothing listening"
echo "  sudo ufw status                         # active"
echo "  swapon --show                           # /dev/zram0"
echo "  sudo auditctl -l | head                 # audit rules loaded"
echo "  sudo aa-status | head                   # apparmor profiles"
