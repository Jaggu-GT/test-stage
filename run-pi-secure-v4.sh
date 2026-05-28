#!/bin/bash
# run-pi-secure-v4.sh — companion to harden-pi.sh
# Sandboxes the Pi coding agent on a Pi 3B+, talking to a LOCAL Ollama Qwen model.
#
# Assumes:
#   * harden-pi.sh already run
#   * Ollama installed with your Qwen model pulled
#   * Pi pre-installed via its official channel (https://pi.dev) and run ONCE
#     interactively as your normal user, so its helper binaries (fd, rg) are
#     cached at ~/.pi/agent/bin/ — the sandbox cannot fetch them itself because
#     egress is locked.
#
# Subcommands:
#   relocate          Move Pi tree from <user>/.local/share/pi-node to /opt/pi-node
#                     and install /usr/local/bin/{node,npm,pi} system wrappers.
#                     Pi's official installer drops it under your home; the
#                     sandboxed user cannot traverse /home (ProtectHome=yes).
#   setup             Main: create piagent user, write models.json, install the
#                     nftables egress backstop, install the launcher, copy
#                     fd/rg helpers in from $SUDO_USER, verify containment.
#   populate-helpers  Re-copy fd/rg from $SUDO_USER's ~/.pi/agent/bin/ into the
#                     piagent home (if Pi added new helpers later).
#   verify            Re-run egress + filesystem containment probes; pass/fail.
#
# Containment is purely external — Pi itself contributes ZERO security.
# Layers in this unit:
#   - dedicated unprivileged UID (piagent), no sudo, nologin, home off /home
#   - whole FS read-only except project dir, Pi config, private /tmp
#   - extensions/, models.json, AND bin/ held read-only at runtime
#     (so the agent cannot self-extend or swap fd/rg)
#   - seccomp allowlist, all caps dropped, NoNewPrivileges, native syscall ABI
#   - egress: systemd IP filter (loopback) + nftables owner-match (Ollama port)
#     verified by probe at setup; setup FAILS CLOSED if not enforced
#   - memory/task caps sized for 1GB alongside Ollama

set -euo pipefail
export LC_ALL=C LANG=C

# ─── Tunables ────────────────────────────────────────────────────
AGENT_USER=piagent
AGENT_HOME=/srv/piagent
WORKDIR="$AGENT_HOME/work"
PI_DIR="$AGENT_HOME/.pi/agent"
OLLAMA_HOST=127.0.0.1
OLLAMA_PORT=11434
OLLAMA_URL="http://$OLLAMA_HOST:$OLLAMA_PORT/v1"
MODEL="qwen2.5:0.5b"          # <-- match `ollama list`
MEM_MAX=320M
TASKS_MAX=96
LAUNCHER=/usr/local/bin/pi-jail
PI_ROOT_SYS=/opt/pi-node      # where `relocate` puts Pi
NFT_FILE=/etc/piagent-egress.nft
NFT_UNIT=/etc/systemd/system/piagent-egress.service

log()  { echo -e "\n\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*" >&2; }
fail() { echo -e "\033[1;31m[✗]\033[0m $*" >&2; exit 1; }
ok()   { echo -e "    \033[1;32m✓\033[0m $*"; }
bad()  { echo -e "    \033[1;31m✗\033[0m $*"; }

[[ $EUID -eq 0 ]] || fail "Run with sudo."

# Source user — the human who ran Pi interactively, owner of the fd/rg cache.
SRC_USER="${SUDO_USER:-}"
[[ -n "$SRC_USER" && "$SRC_USER" != "root" ]] || \
    warn "No SUDO_USER set (running as root directly). Helper auto-copy will be skipped."

# ─── relocate ────────────────────────────────────────────────────
do_relocate() {
    [[ -n "$SRC_USER" && "$SRC_USER" != "root" ]] || \
        fail "relocate needs SUDO_USER (the user whose ~/.local/share/pi-node holds Pi). \
Run via 'sudo' from that user's shell, not as root directly."
    local src; src="$(getent passwd "$SRC_USER" | cut -d: -f6)/.local/share/pi-node"
    [[ -d "$src" ]] || fail "Source not found: $src
Run Pi's official installer as $SRC_USER first (https://pi.dev)."

    if [[ -d "$PI_ROOT_SYS" ]]; then
        warn "$PI_ROOT_SYS already exists; refusing to overwrite. \
Remove it first if you really want to re-relocate."
        return 0
    fi

    log "Copying $src → $PI_ROOT_SYS …"
    cp -a "$src" "$PI_ROOT_SYS"
    chown -R root:root "$PI_ROOT_SYS"
    find "$PI_ROOT_SYS" -type d -exec chmod 0755 {} \;
    find "$PI_ROOT_SYS" -type f ! -perm -u+x -exec chmod 0644 {} \;
    find "$PI_ROOT_SYS" -type f   -perm -u+x -exec chmod 0755 {} \;

    log "Installing /usr/local/bin/{node,npm,pi} …"
    ln -sf "$PI_ROOT_SYS/current/bin/node" /usr/local/bin/node
    ln -sf "$PI_ROOT_SYS/current/bin/npm"  /usr/local/bin/npm
    cat > /usr/local/bin/pi <<EOF
#!/bin/sh
# System wrapper: ensure Pi's bundled Node is on PATH for the pi shim,
# even under systemd-run's scrubbed environment.
PI_ROOT=$PI_ROOT_SYS/current
export PATH="\$PI_ROOT/bin:\$PATH"
exec "\$PI_ROOT/bin/pi" "\$@"
EOF
    chmod 0755 /usr/local/bin/pi

    # Smoke-test as nobody (any unprivileged UID): can we exec it?
    sudo -u nobody /usr/local/bin/pi --version >/dev/null 2>&1 \
        || fail "Relocated pi is not executable by an unprivileged user. Check perms on $PI_ROOT_SYS."
    log "Relocated. Confirm: sudo -u $AGENT_USER /usr/local/bin/pi --version (after setup creates the user)."
}

# ─── populate-helpers ────────────────────────────────────────────
# Copies fd/rg (and any other binaries Pi has cached) from the source user's
# ~/.pi/agent/bin/ into piagent's bin/. The sandbox cannot fetch them itself.
do_populate_helpers() {
    id "$AGENT_USER" >/dev/null 2>&1 || fail "User $AGENT_USER does not exist yet. Run 'setup' first."
    [[ -n "$SRC_USER" && "$SRC_USER" != "root" ]] || \
        fail "populate-helpers needs SUDO_USER. Run via 'sudo' from the user who ran Pi interactively."

    local src; src="$(getent passwd "$SRC_USER" | cut -d: -f6)/.pi/agent/bin"
    local dst="$PI_DIR/bin"

    [[ -d "$src" ]] || fail "Source not found: $src
Run 'pi' once as $SRC_USER so it downloads fd/rg into ~/.pi/agent/bin/, then retry."

    log "Copying helper binaries $src/* → $dst/ …"
    install -d -o "$AGENT_USER" -g "$AGENT_USER" -m 0755 "$dst"
    local copied=0 missing_critical=1
    for f in "$src"/*; do
        [[ -f "$f" && -x "$f" ]] || continue
        install -m 0755 -o "$AGENT_USER" -g "$AGENT_USER" "$f" "$dst/$(basename "$f")"
        copied=$((copied+1))
        [[ "$(basename "$f")" == "fd" || "$(basename "$f")" == "rg" ]] && missing_critical=0
    done
    [[ $copied -gt 0 ]] || fail "No helpers found to copy in $src."

    # Sanity-check the criticals execute as piagent.
    for bin in fd rg; do
        if [[ -x "$dst/$bin" ]]; then
            sudo -u "$AGENT_USER" "$dst/$bin" --version >/dev/null 2>&1 \
                && ok "$bin executable as $AGENT_USER" \
                || bad "$bin present but not runnable as $AGENT_USER"
        else
            bad "$bin missing in $dst (Pi may try to re-download it inside the jail and fail)"
        fi
    done
    [[ $missing_critical -eq 0 ]] || warn "fd and/or rg not found; Pi may behave oddly. \
Make sure you ran 'pi' as $SRC_USER first."
}

# ─── setup ───────────────────────────────────────────────────────
do_setup() {
    # 1. Dependencies — verified, never installed.
    command -v node >/dev/null   || fail "Node.js not found. Run 'relocate' first or install Node >=22."
    local nodemaj; nodemaj=$(node -p 'process.versions.node.split(".")[0]')
    [[ "$nodemaj" -ge 22 ]]      || fail "Pi needs Node >=22 (found $(node -v))."
    command -v ollama >/dev/null || fail "Ollama not found."
    command -v curl >/dev/null   || fail "curl not found (needed for egress verification)."

    command -v pi >/dev/null || fail \
"Pi is not on the system PATH. Install Pi via https://pi.dev as $SRC_USER, then run:
  sudo ./run-pi-secure-v4.sh relocate
to move it into $PI_ROOT_SYS."
    PI_BIN=$(command -v pi)
    case "$PI_BIN" in
        /home/*|/root/*) fail \
"pi at $PI_BIN is under a user home; the sandboxed user can't reach it.
Run:  sudo ./run-pi-secure-v4.sh relocate";;
    esac
    log "Using pi at: $PI_BIN"

    if ! command -v nft >/dev/null; then
        log "Installing nftables (OS package) for the egress backstop…"
        apt-get install -y --no-install-recommends nftables
    fi
    NFT_BIN=$(command -v nft) || fail "nft missing after install."

    # 2. Dedicated unprivileged user.
    if ! id "$AGENT_USER" >/dev/null 2>&1; then
        log "Creating user $AGENT_USER…"
        useradd --system --create-home --home-dir "$AGENT_HOME" \
                --shell /usr/sbin/nologin "$AGENT_USER"
    fi
    gpasswd -d "$AGENT_USER" sudo 2>/dev/null || true
    AGENT_UID=$(id -u "$AGENT_USER")
    log "Agent uid = $AGENT_UID"

    # 3. Directory layout.
    install -d -o "$AGENT_USER" -g "$AGENT_USER" -m 0750 "$WORKDIR"
    install -d -o "$AGENT_USER" -g "$AGENT_USER" -m 0750 "$PI_DIR" \
            "$PI_DIR/extensions" "$PI_DIR/sessions" "$PI_DIR/bin"

    # 4. Pi -> local Ollama config.
    log "Writing models.json (model: $MODEL)"
    cat > "$PI_DIR/models.json" <<EOF
{
  "providers": {
    "ollama": {
      "baseUrl": "$OLLAMA_URL",
      "api": "openai-completions",
      "apiKey": "ollama",
      "compat": { "supportsDeveloperRole": false, "supportsReasoningEffort": false },
      "models": [ { "id": "$MODEL", "input": ["text"] } ]
    }
  }
}
EOF
    chown "$AGENT_USER":"$AGENT_USER" "$PI_DIR/models.json"
    chmod 0640 "$PI_DIR/models.json"

    # 5. Egress backstop: nftables owner-match, agent UID → Ollama port only.
    log "Installing nftables egress backstop (agent → $OLLAMA_HOST:$OLLAMA_PORT only)…"
    cat > "$NFT_FILE" <<NFT
#!/usr/sbin/nft -f
add table inet piagent_jail
delete table inet piagent_jail
table inet piagent_jail {
    chain output {
        type filter hook output priority 0; policy accept;
        meta skuid != $AGENT_UID accept
        ip  daddr $OLLAMA_HOST tcp dport $OLLAMA_PORT accept
        ip6 daddr ::1          tcp dport $OLLAMA_PORT accept
        drop
    }
}
NFT
    chmod 0644 "$NFT_FILE"
    "$NFT_BIN" -f "$NFT_FILE" || fail "Failed to load nftables egress rules."

    cat > "$NFT_UNIT" <<UNIT
[Unit]
Description=piagent egress lockdown (nftables owner-match backstop)
Wants=network-pre.target
Before=network.target
[Service]
Type=oneshot
ExecStart=$NFT_BIN -f $NFT_FILE
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable --now piagent-egress.service >/dev/null 2>&1 || \
        warn "Could not enable piagent-egress.service; rule is loaded for now but check persistence."

    # 6. Report BPF availability (defense-in-depth indicator).
    local bpf="unknown"
    if zcat /proc/config.gz 2>/dev/null | grep -q '^CONFIG_CGROUP_BPF=y'; then bpf=yes
    elif grep -qs '^CONFIG_CGROUP_BPF=y' "/boot/config-$(uname -r)"; then bpf=yes
    else bpf=no/unknown; fi
    log "systemd IP filter (CONFIG_CGROUP_BPF): $bpf  (nftables backstop covers egress regardless)"

    # 7. Auto-populate fd/rg from $SUDO_USER if available.
    if [[ -n "$SRC_USER" && "$SRC_USER" != "root" ]] \
       && [[ -d "$(getent passwd "$SRC_USER" | cut -d: -f6)/.pi/agent/bin" ]]; then
        do_populate_helpers
    else
        warn "Skipping helper auto-copy: no source available. After running 'pi' once as your \
normal user, run:  sudo ./run-pi-secure-v4.sh populate-helpers"
    fi

    # 8. Install launcher.
    log "Installing launcher at $LAUNCHER…"
    cat > "$LAUNCHER" <<LAUNCH
#!/bin/bash
# pi-jail — start a sandboxed Pi session as $AGENT_USER.
set -euo pipefail
[[ \$EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }

# Validate PROJECT: must resolve to a real dir UNDER $AGENT_HOME,
# and must NOT be the home root or the Pi config tree.
PROJECT="\${1:-$WORKDIR}"
PROJECT="\$(realpath -e -- "\$PROJECT" 2>/dev/null)" || { echo "No such dir: \${1:-$WORKDIR}" >&2; exit 1; }
case "\$PROJECT/" in
    "$AGENT_HOME"/.pi/*|"$AGENT_HOME"/) echo "Refusing: project may not be the home root or Pi config dir." >&2; exit 1;;
    "$AGENT_HOME"/*) : ;;
    *) echo "Refusing: project must be under $AGENT_HOME (got \$PROJECT)." >&2; exit 1;;
esac
[[ -d "\$PROJECT" ]] || { echo "Not a directory: \$PROJECT" >&2; exit 1; }
install -d -m 0755 "\$PROJECT/.pi/extensions" 2>/dev/null || true

exec systemd-run --pty --collect --quiet \\
  --unit="pi-jail-\$\$" \\
  --uid=$AGENT_USER --gid=$AGENT_USER \\
  --working-directory="\$PROJECT" \\
  --setenv=HOME=$AGENT_HOME \\
  --setenv=TERM="\$TERM" \\
  -p NoNewPrivileges=yes \\
  -p ProtectSystem=strict \\
  -p ProtectHome=yes \\
  -p ReadWritePaths="\$PROJECT" \\
  -p ReadWritePaths=$PI_DIR \\
  -p ReadOnlyPaths=$PI_DIR/extensions \\
  -p ReadOnlyPaths=$PI_DIR/bin \\
  -p ReadOnlyPaths=$PI_DIR/models.json \\
  -p ReadOnlyPaths=-\$PROJECT/.pi/extensions \\
  -p PrivateTmp=yes \\
  -p PrivateDevices=yes \\
  -p ProtectKernelTunables=yes \\
  -p ProtectKernelModules=yes \\
  -p ProtectKernelLogs=yes \\
  -p ProtectControlGroups=yes \\
  -p ProtectClock=yes \\
  -p ProtectHostname=yes \\
  -p RestrictNamespaces=yes \\
  -p RestrictSUIDSGID=yes \\
  -p RestrictRealtime=yes \\
  -p LockPersonality=yes \\
  -p MemoryDenyWriteExecute=no \\
  -p CapabilityBoundingSet= \\
  -p AmbientCapabilities= \\
  -p SystemCallArchitectures=native \\
  -p SystemCallFilter="@system-service" \\
  -p SystemCallFilter="~@privileged @resources @mount @swap @reboot @raw-io @module @debug @cpu-emulation @obsolete @clock" \\
  -p RestrictAddressFamilies="AF_UNIX AF_INET AF_INET6" \\
  -p IPAddressAllow=localhost \\
  -p IPAddressDeny=any \\
  -p MemoryMax=$MEM_MAX \\
  -p TasksMax=$TASKS_MAX \\
  "$PI_BIN"
LAUNCH
    chmod 0755 "$LAUNCHER"

    # 9. Verify (fails closed).
    do_verify
    log "Done. Launch:  sudo pi-jail"
}

# ─── verify ──────────────────────────────────────────────────────
do_verify() {
    id "$AGENT_USER" >/dev/null 2>&1 || fail "User $AGENT_USER does not exist. Run 'setup' first."
    log "Verifying containment…"
    local pass=0 fail_=0

    # A. Pi binary reachable by piagent.
    if sudo -u "$AGENT_USER" /usr/local/bin/pi --version >/dev/null 2>&1; then
        ok "pi executable as $AGENT_USER"; pass=$((pass+1))
    else
        bad "pi NOT executable as $AGENT_USER (check 'relocate')"; fail_=$((fail_+1))
    fi

    # B. fd / rg present.
    for bin in fd rg; do
        if sudo -u "$AGENT_USER" "$PI_DIR/bin/$bin" --version >/dev/null 2>&1; then
            ok "$bin present for $AGENT_USER"; pass=$((pass+1))
        else
            bad "$bin missing for $AGENT_USER (run 'populate-helpers')"; fail_=$((fail_+1))
        fi
    done

    # C. nftables rule loaded.
    if nft list table inet piagent_jail >/dev/null 2>&1; then
        ok "nftables egress rule loaded"; pass=$((pass+1))
    else
        bad "nftables rule missing"; fail_=$((fail_+1))
    fi

    # D. Egress probe: external destinations must be unreachable.
    if systemd-run --pipe --quiet --uid="$AGENT_USER" --gid="$AGENT_USER" \
         -p IPAddressDeny=any -p IPAddressAllow=localhost \
         "$(command -v curl)" -m5 -sf https://1.1.1.1 >/dev/null 2>&1; then
        bad "EGRESS REACHED INTERNET — containment FAILED. Do not run Pi."; fail_=$((fail_+1))
    else
        ok "external egress blocked for $AGENT_USER"; pass=$((pass+1))
    fi

    # E. Ollama reachable (informational, non-fatal).
    if systemd-run --pipe --quiet --uid="$AGENT_USER" --gid="$AGENT_USER" \
         -p IPAddressDeny=any -p IPAddressAllow=localhost \
         "$(command -v curl)" -m5 -sf "http://$OLLAMA_HOST:$OLLAMA_PORT/api/tags" >/dev/null 2>&1; then
        ok "Ollama reachable from sandbox"
    else
        warn "Ollama not reachable from sandbox — is the service up and the model pulled?"
    fi

    # F. models.json sane.
    if [[ -f "$PI_DIR/models.json" ]] && grep -q "\"$MODEL\"" "$PI_DIR/models.json"; then
        ok "models.json references $MODEL"; pass=$((pass+1))
    else
        bad "models.json missing or model tag mismatch (edit MODEL and re-run setup)"; fail_=$((fail_+1))
    fi

    echo
    if [[ $fail_ -eq 0 ]]; then
        log "Verify: $pass checks passed, no failures."
    else
        fail "Verify: $fail_ checks FAILED ($pass passed). Resolve before launching Pi."
    fi
}

# ─── dispatch ────────────────────────────────────────────────────
case "${1:-}" in
    relocate)         do_relocate ;;
    setup)            do_setup ;;
    populate-helpers) do_populate_helpers ;;
    verify)           do_verify ;;
    *) fail "Usage: $0 {relocate|setup|populate-helpers|verify}" ;;
esac
