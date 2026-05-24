#!/bin/bash
# run-pi-secure.sh — companion to harden-pi.sh
# Sets up the Pi coding agent to run sandboxed on a Pi 3B+, talking to a
# LOCAL Ollama Qwen model. Assumes harden-pi.sh has already been run and that
# Ollama is installed with your Qwen model already pulled.
#
# Containment is done entirely by a systemd transient unit (systemd-run --pty):
#   - dedicated unprivileged UID, no sudo
#   - whole FS read-only except the project dir (+ session dir, private /tmp)
#   - self-extension frozen (extensions/config dir is read-only)
#   - seccomp syscall allowlist, all capabilities dropped, NoNewPrivileges
#   - egress locked to loopback only (the agent needs nothing but local Ollama)
#   - memory / task caps sized for 1GB alongside Ollama
# Pi contributes ZERO security of its own — this unit IS the boundary.
#
# Usage:
#   chmod +x run-pi-secure.sh
#   sudo ./run-pi-secure.sh setup     # one-time: user, config, launcher
#   sudo pi-jail                      # start a sandboxed Pi session
#   sudo pi-jail /srv/piagent/work    # ...in a specific project dir

set -euo pipefail
export LC_ALL=C LANG=C

# ─── Tunables ────────────────────────────────────────────────────
AGENT_USER=piagent
AGENT_HOME=/srv/piagent          # NOT under /home, so ProtectHome can hide /home
WORKDIR="$AGENT_HOME/work"       # the only writable project area
PI_DIR="$AGENT_HOME/.pi/agent"
OLLAMA_URL="http://127.0.0.1:11434/v1"
MODEL="qwen2.5:0.5b"             # <-- set to YOUR pulled tag (see: ollama list)
MEM_MAX=320M                     # Node/Pi + bash children; Ollama is separate
TASKS_MAX=96
LAUNCHER=/usr/local/bin/pi-jail

log()  { echo -e "\n\033[1;32m[+]\033[0m $*"; }
fail() { echo -e "\033[1;31m[✗]\033[0m $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || fail "Run with sudo (needs to create a user + system launcher)."

# ─── setup ───────────────────────────────────────────────────────
do_setup() {
    # 1. Dependencies: Node >=22 and the pi CLI, installed system-wide so the
    #    sandboxed user (whose home is hidden) can still reach the binary.
    command -v node >/dev/null || fail "Node.js not found. Install Node >=22 first."
    local nodemaj; nodemaj=$(node -p 'process.versions.node.split(".")[0]')
    [[ "$nodemaj" -ge 22 ]] || fail "Pi needs Node >=22 (found $(node -v))."
    command -v ollama >/dev/null || fail "Ollama not found (expected, per your setup)."

    if ! command -v pi >/dev/null; then
        log "Installing Pi globally…"
        npm install -g @mariozechner/pi-coding-agent
    fi
    PI_BIN=$(command -v pi) || fail "pi not on PATH after install."
    case "$PI_BIN" in
        /home/*|/root/*) fail "pi at $PI_BIN is under a user home; the sandboxed \
user can't reach it. Reinstall Node+Pi system-wide (e.g. /usr/local).";;
    esac
    log "Using pi at: $PI_BIN"

    # 2. Dedicated unprivileged user — no sudo, no login shell, home off /home.
    if ! id "$AGENT_USER" >/dev/null 2>&1; then
        log "Creating user $AGENT_USER…"
        useradd --system --create-home --home-dir "$AGENT_HOME" \
                --shell /usr/sbin/nologin "$AGENT_USER"
    fi
    # Ensure it is NOT in sudo/admin groups.
    gpasswd -d "$AGENT_USER" sudo  2>/dev/null || true

    # 3. Directory layout. extensions/ exists but stays read-only (frozen) under
    #    the unit's ProtectSystem=strict, killing the self-extension vector.
    install -d -o "$AGENT_USER" -g "$AGENT_USER" -m 0750 "$WORKDIR"
    install -d -o "$AGENT_USER" -g "$AGENT_USER" -m 0750 "$PI_DIR" \
            "$PI_DIR/extensions" "$PI_DIR/sessions"

    # 4. Pi -> local Ollama (verified schema: ~/.pi/agent/models.json).
    #    compat flags off: small/local OpenAI-compatible servers don't grok the
    #    developer role or reasoning_effort.
    log "Writing models.json for model: $MODEL"
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

    # 5. The launcher: one hardened systemd transient unit.
    log "Installing launcher at $LAUNCHER…"
    cat > "$LAUNCHER" <<LAUNCH
#!/bin/bash
# pi-jail — start a sandboxed Pi session as $AGENT_USER.
# All containment lives here; Pi itself has none.
set -euo pipefail
[[ \$EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }
PROJECT="\${1:-$WORKDIR}"
[[ -d "\$PROJECT" ]] || { echo "No such dir: \$PROJECT" >&2; exit 1; }

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
  -p ReadWritePaths=$PI_DIR/sessions \\
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

    log "Done. Verify Ollama has your model, then launch:"
    echo "  ollama list                 # confirm '$MODEL' (edit MODEL in this script if not)"
    echo "  sudo pi-jail                # sandboxed session in $WORKDIR"
    echo "  # in Pi:  /model            # select the ollama model"
    echo
    echo "Sandbox sanity-check (run inside a pi-jail bash tool call):"
    echo "  id                          # uid=$AGENT_USER, no sudo group"
    echo "  curl -m3 https://example.com   # MUST fail (egress = loopback only)"
    echo "  curl -m3 http://127.0.0.1:11434/api/tags  # MAY succeed (local Ollama)"
    echo "  touch /etc/x 2>&1 || echo RO  # RO: filesystem locked"
    echo "  touch \$HOME/.pi/agent/extensions/x 2>&1 || echo FROZEN  # self-extension blocked"
}

case "${1:-setup}" in
    setup) do_setup ;;
    *)     fail "Unknown command '$1'. Use: setup" ;;
esac
