#!/bin/bash
# pi-tune-v3.sh — performance + brevity tuning for the sandboxed Pi agent.
# Applies ONLY:
#   (1) Global AGENTS.md brevity rules + read-only lock in the launcher
#   (4) Ollama service drop-in (keep-alive, sequential decode, memory cap) +
#       derived model qwen2.5:0.5b-pi with num_ctx=3072
#
# v3 fixes:
#   C1: symlink TOCTOU on agent-writable paths — assert_safe_target + write to
#       a same-dir tempfile then rename(2) (atomic, does not follow symlinks
#       on dest); Python edit uses O_NOFOLLOW on the source open.
#   C2: hardened PATH at script start (no inherited PATH from caller).
#   H1: Ollama MemoryMax=800M — runaway gets killed in its own cgroup, not the
#       whole Pi. (Decision to keep num_ctx=3072 was deliberate; zram absorbs.)
#   H2: AGENTS.md and models.json now root:piagent 0640 — piagent can read but
#       cannot write the policy files even if it ever ran outside the jail.
#   H3: Ollama restart auto-rolls back on health-check failure (restores .bak
#       or removes our drop-in, restarts, re-probes). Fails closed only if BOTH
#       the new config and the rollback fail.

set -euo pipefail
export LC_ALL=C LANG=C
# C2: pin PATH so root never executes through caller-controlled env.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

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

# C1: assert a target path is safe to write to from root.
# Refuses if the parent dir is a symlink, owned by an unexpected user, or if
# the target itself is a symlink / non-regular file. Run BEFORE every write.
assert_safe_target() {
    local path="$1" exp_parent_owner="$2"
    local parent; parent="$(dirname -- "$path")"
    [[ -L "$parent" ]] && fail "Refusing: parent dir is a symlink: $parent"
    [[ -d "$parent" ]] || fail "Parent dir missing: $parent"
    local actual; actual="$(stat -c '%U' "$parent")"
    [[ "$actual" == "$exp_parent_owner" ]] \
        || fail "Refusing: $parent owned by '$actual', expected '$exp_parent_owner'"
    if [[ -e "$path" ]]; then
        [[ -L "$path" ]] && fail "Refusing: target is a symlink: $path"
        [[ -f "$path" ]] || fail "Refusing: target exists but is not a regular file: $path"
    fi
}

# C1: write stdin to $1 via a same-dir tempfile + rename(2). rename does not
# follow symlinks on the destination, so even a race-inserted symlink at $1
# would just be replaced (not written through).
# Args: dest, owner, group, mode_octal.   stdin = content.
write_safely() {
    local dest="$1" owner="$2" group="$3" mode="$4"
    local dir; dir="$(dirname -- "$dest")"
    local tmp; tmp="$(mktemp -p "$dir" .tmp.pi-tune.XXXXXX)" || fail "mktemp failed in $dir"
    # Set perms BEFORE writing content (small attack-window minimisation).
    chown "$owner":"$group" "$tmp"
    chmod "$mode" "$tmp"
    if ! cat > "$tmp"; then rm -f "$tmp"; fail "write to $tmp failed"; fi
    mv -f "$tmp" "$dest"
}

[[ $EUID -eq 0 ]] || fail "Run with sudo."
id "$AGENT_USER" >/dev/null 2>&1 || fail "User $AGENT_USER missing. Run run-pi-secure-v4.sh setup first."
[[ -x "$LAUNCHER"   ]] || fail "Launcher $LAUNCHER missing."
[[ -L "$LAUNCHER"   ]] && fail "Refusing: $LAUNCHER is a symlink."
[[ -f "$MODELS_JSON" ]] || fail "models.json missing at $MODELS_JSON."
command -v ollama  >/dev/null || fail "ollama not found."
command -v python3 >/dev/null || fail "python3 not found (needed for safe JSON edit)."

# ─── (1) AGENTS.md — global brevity rules ────────────────────────
assert_safe_target "$AGENTS_MD" "$AGENT_USER"
log "Writing $AGENTS_MD (root:$AGENT_USER 0640, terse, token-cheap)…"
backup "$AGENTS_MD"
write_safely "$AGENTS_MD" root "$AGENT_USER" 0640 <<'EOF'
# Rules
- Be terse. ≤3 bullets, no preamble.
- Answer from knowledge. Tools only when needed.
- One tool call per step. No speculation.
- Stop when done. No summaries.
EOF
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

# ─── (4a) Ollama service drop-in (with auto-rollback on health fail) ─
check_ollama() {
    for _ in 1 2 3 4 5 6 7 8; do
        if curl -fsS -m3 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then return 0; fi
        sleep 2
    done
    return 1
}

assert_safe_target "$OLLAMA_DROPIN" root
mkdir -p "$(dirname "$OLLAMA_DROPIN")"
log "Installing Ollama drop-in $OLLAMA_DROPIN (with MemoryMax cap)…"
backup "$OLLAMA_DROPIN"
write_safely "$OLLAMA_DROPIN" root root 0644 <<'EOF'
[Service]
Environment="OLLAMA_KEEP_ALIVE=30m"
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
# H1: hard ceiling. If Ollama runs away, its own cgroup gets killed — not the
# whole Pi. Sized for Qwen 0.5B + num_ctx=3072 + runtime overhead with headroom.
MemoryMax=800M
EOF

systemctl daemon-reload
log "Restarting ollama…"
systemctl restart ollama || warn "systemctl restart returned non-zero; checking health anyway."

if ! check_ollama; then
    warn "Ollama did not come back. Auto-rolling back the drop-in…"
    if [[ -f "$OLLAMA_DROPIN.bak.$TS" ]]; then
        cp -a "$OLLAMA_DROPIN.bak.$TS" "$OLLAMA_DROPIN"
        log "Restored previous drop-in from .bak.$TS."
    else
        rm -f "$OLLAMA_DROPIN"
        log "Removed new drop-in (no prior version existed)."
    fi
    systemctl daemon-reload
    systemctl restart ollama || true
    if check_ollama; then
        fail "Ollama would not start with the new drop-in; ROLLED BACK to previous state. Investigate new settings before retrying."
    fi
    fail "Ollama would not start AND rollback failed. SYSTEM DEGRADED. Investigate: journalctl -u ollama -n 50"
fi
log "Ollama is up with new settings."

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

# ─── Upsert tuned model into models.json (atomic + O_NOFOLLOW) ───
assert_safe_target "$MODELS_JSON" "$AGENT_USER"
log "Upserting $TUNED_MODEL into $MODELS_JSON (backup → $MODELS_JSON.bak.$TS)…"
backup "$MODELS_JSON"

python3 - "$MODELS_JSON" "$TUNED_MODEL" "$AGENT_USER" <<'PY' \
    || fail "models.json edit failed; original preserved at $MODELS_JSON.bak.$TS"
import grp, json, os, stat, sys, tempfile
path, new_id, group_name = sys.argv[1], sys.argv[2], sys.argv[3]
parent = os.path.dirname(path) or "."

# C1: refuse if parent or target is a symlink / not regular.
if os.path.islink(parent):
    sys.exit(f"refusing: parent is a symlink: {parent}")
try:
    st = os.lstat(path)
    if not stat.S_ISREG(st.st_mode):
        sys.exit(f"refusing: {path} is not a regular file")
except FileNotFoundError:
    sys.exit(f"missing: {path}")

# C1: O_NOFOLLOW read — even if a symlink were spliced in between checks, we
# would get ELOOP rather than reading the wrong file.
fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
with os.fdopen(fd, "rb") as f:
    data = json.load(f)

providers = data.setdefault("providers", {})
ollama = providers.setdefault("ollama", {})
models = ollama.setdefault("models", [])
if not isinstance(models, list):
    sys.exit(f"providers.ollama.models is not a list (got {type(models).__name__})")

# Upsert by id; preserve every other entry untouched.
found = False
for m in models:
    if isinstance(m, dict) and m.get("id") == new_id:
        m.setdefault("input", ["text"])
        found = True
        break
if not found:
    models.append({"id": new_id, "input": ["text"]})

# H2: write as root:piagent 0640 (group can read, only root can write).
uid = 0
gid = grp.getgrnam(group_name).gr_gid

# Atomic write: same-dir tempfile → fsync → os.replace (rename(2), no symlink follow on dest).
fd, tmp = tempfile.mkstemp(dir=parent, prefix=".tmp.pi-tune.", text=False)
try:
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp, 0o640)
    os.chown(tmp, uid, gid)
    os.replace(tmp, path)
except Exception:
    try: os.unlink(tmp)
    except OSError: pass
    raise

print(f"upsert ok ({'updated' if found else 'added'}); models[] count = {len(models)}.")
PY

python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$MODELS_JSON" \
    || fail "models.json no longer valid JSON; restore $MODELS_JSON.bak.$TS"

# ─── Summary ─────────────────────────────────────────────────────
log "Verification:"
printf "  %-34s %s\n" "AGENTS.md owner+mode:" "$(stat -c '%U:%G %a' "$AGENTS_MD")"
printf "  %-34s %s\n" "models.json owner+mode:"  "$(stat -c '%U:%G %a' "$MODELS_JSON")"
printf "  %-34s %s\n" "AGENTS.md readable as $AGENT_USER:" \
    "$(sudo -u "$AGENT_USER" cat "$AGENTS_MD" >/dev/null 2>&1 && echo yes || echo NO)"
printf "  %-34s %s\n" "Launcher pins AGENTS.md RO:" \
    "$(grep -qF "ReadOnlyPaths=$AGENTS_MD" "$LAUNCHER" && echo yes || echo NO)"
printf "  %-34s %s\n" "Ollama responding:" \
    "$(curl -fsS -m3 http://127.0.0.1:11434/api/tags >/dev/null && echo yes || echo NO)"
printf "  %-34s %s\n" "Ollama MemoryMax set:" \
    "$(systemctl show ollama --property=MemoryMax --value)"
printf "  %-34s %s\n" "$TUNED_MODEL present:" \
    "$(ollama show "$TUNED_MODEL" >/dev/null 2>&1 && echo yes || echo NO)"
printf "  %-34s %s\n" "models.json has tuned id:" \
    "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("yes" if sys.argv[2] in [m["id"] for m in d["providers"]["ollama"]["models"]] else "NO")' "$MODELS_JSON" "$TUNED_MODEL")"
printf "  %-34s %s\n" "models.json model count:" \
    "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["providers"]["ollama"]["models"]))' "$MODELS_JSON")"

for v in /usr/local/bin/run-pi-secure-v4.sh "$(dirname "$0")/run-pi-secure-v4.sh"; do
    [[ -x "$v" ]] && { log "Re-running sandbox verify…"; "$v" verify || warn "verify reported issues — see above."; break; }
done

log "Done. Inside Pi (sudo pi-jail): /reload to pick up AGENTS.md.
     Pick the tuned model: Ctrl+L (or /model) → select $TUNED_MODEL."
echo "Backups saved with suffix .bak.$TS"
echo "Revert quick-ref:"
echo "  Ollama:    install -m 0644 $OLLAMA_DROPIN.bak.$TS $OLLAMA_DROPIN  (if backup exists, else rm)"
echo "             systemctl daemon-reload && systemctl restart ollama"
echo "  Launcher:  install -m 0755 $LAUNCHER.bak.$TS $LAUNCHER             (if backup exists)"
echo "  Model tag: install -o root -g $AGENT_USER -m 0640 $MODELS_JSON.bak.$TS $MODELS_JSON"
echo "  Drop model: ollama rm $TUNED_MODEL"
