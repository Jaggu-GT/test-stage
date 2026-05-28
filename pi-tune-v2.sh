#!/bin/bash
# pi-tune-v2.sh — performance + brevity tuning for the sandboxed Pi agent.
# Applies ONLY:
#   (1) Global AGENTS.md brevity rules + read-only lock in the launcher
#   (4) Ollama service drop-in (keep-alive, sequential decode) +
#       derived model qwen2.5:0.5b-pi with num_ctx=3072
#
# Changes vs v1:
#   * MEDIUM 1 fix: models.json edit is now atomic (tempfile + os.replace).
#   * MEDIUM 2 fix: models[] is preserved — tuned model is upserted by id,
#                   any other entries are left untouched.
#   * num_ctx: 2048 → 3072 for larger messages (KV cache ~+50MB on 0.5B; fits).
#
# Assumes run-pi-secure-v4.sh setup has already completed.
# Idempotent. Backs up every file it modifies (.bak.<ts>). Fails closed.

set -euo pipefail
export LC_ALL=C LANG=C

AGENT_USER=piagent
AGENT_HOME=/srv/piagent
PI_DIR=$AGENT_HOME/.pi/agent
AGENTS_MD=$PI_DIR/AGENTS.md
LAUNCHER=/usr/local/bin/pi-jail
MODELS_JSON=$PI_DIR/models.json
BASE_MODEL=qwen2.5:0.5b
TUNED_MODEL=qwen2.5:0.5b-pi
OLLAMA_DROPIN=/etc/systemd/system/ollama.service.d/override.conf
TS=$(date +%Y%m%d-%H%M%S)

log()  { echo -e "\n\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*" >&2; }
fail() { echo -e "\033[1;31m[✗]\033[0m $*" >&2; exit 1; }
backup() { [[ -f "$1" ]] && cp -a "$1" "$1.bak.$TS"; }

[[ $EUID -eq 0 ]] || fail "Run with sudo."
id "$AGENT_USER" >/dev/null 2>&1 || fail "User $AGENT_USER missing. Run run-pi-secure-v4.sh setup first."
[[ -x "$LAUNCHER"   ]] || fail "Launcher $LAUNCHER missing."
[[ -f "$MODELS_JSON" ]] || fail "models.json missing at $MODELS_JSON."
command -v ollama  >/dev/null || fail "ollama not found."
command -v python3 >/dev/null || fail "python3 not found (needed for safe JSON edit)."

# ─── (1) AGENTS.md — global brevity rules ────────────────────────
log "Writing $AGENTS_MD (terse, token-cheap)…"
cat > "$AGENTS_MD" <<'EOF'
# Rules
- Be terse. ≤3 bullets, no preamble.
- Answer from knowledge. Tools only when needed.
- One tool call per step. No speculation.
- Stop when done. No summaries.
EOF
chown "$AGENT_USER":"$AGENT_USER" "$AGENTS_MD"
chmod 0640 "$AGENTS_MD"
sudo -u "$AGENT_USER" test -r "$AGENTS_MD" || fail "AGENTS.md not readable by $AGENT_USER."

# Pin AGENTS.md read-only in the launcher (idempotent + safe).
if grep -qF "ReadOnlyPaths=$AGENTS_MD" "$LAUNCHER"; then
    log "Launcher already pins AGENTS.md read-only."
else
    log "Patching $LAUNCHER (backup → $LAUNCHER.bak.$TS)…"
    backup "$LAUNCHER"
    awk -v ins="  -p ReadOnlyPaths=$AGENTS_MD \\\\" '
        !done && /-p ReadOnlyPaths=.*models\.json[[:space:]]+\\$/ { print; print ins; done=1; next }
        { print }
    ' "$LAUNCHER" > "$LAUNCHER.tmp"
    grep -qF "ReadOnlyPaths=$AGENTS_MD" "$LAUNCHER.tmp" \
        || { rm -f "$LAUNCHER.tmp"; fail "Anchor line not found in launcher; original untouched."; }
    bash -n "$LAUNCHER.tmp" \
        || { rm -f "$LAUNCHER.tmp"; fail "Patched launcher fails bash -n; original untouched."; }
    install -m 0755 -o root -g root "$LAUNCHER.tmp" "$LAUNCHER"
    rm -f "$LAUNCHER.tmp"
fi

# ─── (4a) Ollama service drop-in ─────────────────────────────────
log "Installing Ollama drop-in $OLLAMA_DROPIN…"
mkdir -p "$(dirname "$OLLAMA_DROPIN")"
backup "$OLLAMA_DROPIN"
cat > "$OLLAMA_DROPIN" <<'EOF'
[Service]
Environment="OLLAMA_KEEP_ALIVE=30m"
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
EOF
chmod 0644 "$OLLAMA_DROPIN"
systemctl daemon-reload
log "Restarting ollama…"
systemctl restart ollama
ok=0
for _ in 1 2 3 4 5 6 7 8; do
    if curl -fsS -m3 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then ok=1; break; fi
    sleep 2
done
[[ $ok -eq 1 ]] || fail "Ollama did not come back after restart.
Revert: restore $OLLAMA_DROPIN.bak.$TS (if present) or rm $OLLAMA_DROPIN, then daemon-reload + restart ollama."

# ─── (4b) Derived model with num_ctx=3072 ────────────────────────
ollama show "$BASE_MODEL" >/dev/null 2>&1 \
    || fail "Base model $BASE_MODEL not present. Run: ollama pull $BASE_MODEL"

log "Creating/refreshing $TUNED_MODEL (num_ctx=3072)…"
MF=$(mktemp)
cat > "$MF" <<EOF
FROM $BASE_MODEL
PARAMETER num_ctx 3072
PARAMETER num_predict 256
PARAMETER temperature 0.2
EOF
ollama create "$TUNED_MODEL" -f "$MF" >/dev/null
rm -f "$MF"
ollama show "$TUNED_MODEL" >/dev/null 2>&1 \
    || fail "ollama create did not produce $TUNED_MODEL."

# Upsert the tuned model into models.json — preserve any other entries.
# Atomic: write to .tmp in the same dir, fsync, os.replace (POSIX-atomic).
log "Upserting $TUNED_MODEL into $MODELS_JSON (backup → $MODELS_JSON.bak.$TS)…"
backup "$MODELS_JSON"

python3 - "$MODELS_JSON" "$TUNED_MODEL" <<'PY' \
    || fail "models.json edit failed; original preserved at $MODELS_JSON.bak.$TS"
import json, os, sys, tempfile

path, new_id = sys.argv[1], sys.argv[2]

with open(path) as f:
    data = json.load(f)

# Walk to providers.ollama.models[], creating missing scaffolding only if absent.
providers = data.setdefault("providers", {})
ollama = providers.setdefault("ollama", {})
models = ollama.setdefault("models", [])
if not isinstance(models, list):
    raise SystemExit(f"providers.ollama.models is not a list (got {type(models).__name__})")

# Upsert by id. Preserve every other entry untouched.
found = False
for m in models:
    if isinstance(m, dict) and m.get("id") == new_id:
        m.setdefault("input", ["text"])
        found = True
        break
if not found:
    models.append({"id": new_id, "input": ["text"]})

# Atomic write: same-directory tempfile → fsync → os.replace.
# Preserve original mode + ownership on the new file before renaming.
st = os.stat(path)
dir_ = os.path.dirname(path) or "."
fd, tmp = tempfile.mkstemp(dir=dir_, prefix=".models.json.", suffix=".tmp")
try:
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp, st.st_mode & 0o7777)
    try:
        os.chown(tmp, st.st_uid, st.st_gid)
    except PermissionError:
        pass  # running as root in practice; harmless if not
    os.replace(tmp, path)
except Exception:
    try: os.unlink(tmp)
    except OSError: pass
    raise

print(f"upsert ok ({'updated' if found else 'added'}); models[] now has {len(models)} entr{'y' if len(models)==1 else 'ies'}.")
PY

# Post-write validation.
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$MODELS_JSON" \
    || fail "models.json no longer valid JSON; restore $MODELS_JSON.bak.$TS"

# ─── Summary ─────────────────────────────────────────────────────
log "Verification:"
printf "  %-32s %s\n" "AGENTS.md readable as $AGENT_USER:" \
    "$(sudo -u "$AGENT_USER" cat "$AGENTS_MD" >/dev/null 2>&1 && echo yes || echo NO)"
printf "  %-32s %s\n" "Launcher pins AGENTS.md RO:" \
    "$(grep -qF "ReadOnlyPaths=$AGENTS_MD" "$LAUNCHER" && echo yes || echo NO)"
printf "  %-32s %s\n" "Ollama responding:" \
    "$(curl -fsS -m3 http://127.0.0.1:11434/api/tags >/dev/null && echo yes || echo NO)"
printf "  %-32s %s\n" "$TUNED_MODEL present:" \
    "$(ollama show "$TUNED_MODEL" >/dev/null 2>&1 && echo yes || echo NO)"
printf "  %-32s %s\n" "models.json valid + has tuned:" \
    "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); ids=[m["id"] for m in d["providers"]["ollama"]["models"]]; print("yes" if sys.argv[2] in ids else "NO")' "$MODELS_JSON" "$TUNED_MODEL")"
printf "  %-32s %s\n" "models.json model count:" \
    "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["providers"]["ollama"]["models"]))' "$MODELS_JSON")"

for v in /usr/local/bin/run-pi-secure-v4.sh "$(dirname "$0")/run-pi-secure-v4.sh"; do
    [[ -x "$v" ]] && { log "Re-running sandbox verify…"; "$v" verify || warn "verify reported issues — see above."; break; }
done

log "Done. Inside Pi (sudo pi-jail) type /reload to pick up AGENTS.md.
     Pick the tuned model: Ctrl+L (or /model) → select $TUNED_MODEL."
echo "Backups saved with suffix .bak.$TS"
echo "Revert quick-ref:"
echo "  Ollama:      install -m 0644 $OLLAMA_DROPIN.bak.$TS $OLLAMA_DROPIN  (if backup exists)"
echo "               # if no backup existed: rm $OLLAMA_DROPIN"
echo "               systemctl daemon-reload && systemctl restart ollama"
echo "  Launcher:    install -m 0755 $LAUNCHER.bak.$TS $LAUNCHER            (if backup exists)"
echo "  Model tag:   install -o $AGENT_USER -g $AGENT_USER -m 0640 $MODELS_JSON.bak.$TS $MODELS_JSON"
echo "  Drop model:  ollama rm $TUNED_MODEL"
