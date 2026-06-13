#!/usr/bin/env bash
# sensor-read-debug-secure-v4.sh — Coral Env Sensor Board readout
#
# Changes from sensor-read-debug-secure-v3.sh:
#   * Sensor read failures now preserve the existing placeholder fallback values
#     instead of exiting under set -e.
#   * Runtime lock directory is validated before the lock file is opened.
#
# Preserved from v3:
#   * SPI0 BUS LOCK: OLED transfers now wrapped in an flock(2) advisory lock on
#     the shared bus token /dev/spidev0.0 — the SAME lock the e-ink driver's
#     Spi0BusLock takes (fcntl.flock and flock(1) are the same flock(2) syscall,
#     so they interoperate). Lock is held PER TRANSACTION (init + each frame),
#     released during the cycle sleep, so a co-resident e-ink display can use
#     the bus between frames. Configurable via SPI_LOCK_WAIT (seconds).
#   * Single-instance lockfile moved /tmp -> $XDG_RUNTIME_DIR (squat-resistant;
#     /tmp is world-writable and exploitable for a privileged/long-running job).
#
# Preserved from v2:
#   * H1 hex regex validation before every $((..)) arithmetic context
#   * Pinned PATH, PYTHONSAFEPATH + isolated Python, atexit GPIO/SPI/OLED cleanup
#   * hello/bye splashes, bottom-anchored auto-scaling text, --cycle/--loop/--help
#
# Sensors (per pinout.xyz):
#   HDC2010 @ 0x40 raw I2C   |   OPT3002 @ 0x45 raw I2C   |   BMP280 IIO sysfs
#
# OLED:
#   SSD1306 128x32, SPI0 CE0 (/dev/spidev0.0), DC=GPIO24, RST=GPIO25
#
# BUS-SHARING NOTE: SPI0 (SCLK/MOSI) is shared. spidev does NOT enforce
#   exclusivity, so concurrent transfers corrupt both devices. The lock here is
#   ADVISORY — it only protects against processes that take the same lock on the
#   same token. The e-ink side already does (Spi0BusLock -> /dev/spidev0.0).
#   The two displays MUST be on different chip-selects (OLED CE0, e-ink CE1) and
#   different DC/RST/BUSY GPIOs — see the pin map. The lock solves BUS contention,
#   not GPIO-pin overlap; that is solved by wiring.
#
# Requires:
#   - bash, i2c-tools, awk, timeout, flock
#   - python3 (>=3.11 for PYTHONSAFEPATH), python3-spidev, python3-gpiozero, python3-pil
#   - /dev/i2c-1 and /dev/spidev0.0; user in 'i2c' and 'spi' groups
#
# Usage:
#   chmod +x sensor-read-debug-secure-v4.sh
#   ./sensor-read-debug-secure-v4.sh                 # hello -> sensors -> bye
#   ./sensor-read-debug-secure-v4.sh --loop          # hello -> forever -> (Ctrl-C) -> bye
#   ./sensor-read-debug-secure-v4.sh --cycle 5       # 5s per reading
#   ./sensor-read-debug-secure-v4.sh --test-pattern  # hello + bye only
#   SPI_LOCK_WAIT=15 ./sensor-read-debug-secure-v4.sh  # wait up to 15s for the bus

set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C

BUS=1
LOOP_MODE="once"
CYCLE_SECONDS="3"
TEST_PATTERN_ONLY=0

# Shared SPI0 bus token. MUST match _SPI_NODE in epd2in7v2.py (Spi0BusLock).
# Even if the e-ink transfers on CE1 (/dev/spidev0.1), both sides agree to lock
# THIS node as the bus token. If a 3rd SPI device appears, keep one token.
readonly SPI_BUS_TOKEN="/dev/spidev0.0"
SPI_LOCK_WAIT="${SPI_LOCK_WAIT:-10}"   # seconds to wait for the bus before giving up

# Single-instance lock in the user runtime dir (mode 0700, owned by us) — not /tmp.
LOCK_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
LOCK_FILE="$LOCK_DIR/sensor-read-debug-secure.lock"

# H1 fix: regex used for every hex byte from i2ctransfer/i2cget before it is fed
# into $((..)) arithmetic context (which recursively evaluates).
readonly HEX_BYTE_RE='^0x[0-9a-fA-F]{1,2}$'

while [[ $# -gt 0 ]]; do
  case "$1" in
    --loop)         LOOP_MODE="forever"; shift ;;
    --cycle)        [[ $# -ge 2 ]] || { echo "Missing value for --cycle" >&2; exit 2; }
                    CYCLE_SECONDS="$2"; shift 2 ;;
    --cycle=*)      CYCLE_SECONDS="${1#*=}"; shift ;;
    --test-pattern) TEST_PATTERN_ONLY=1; shift ;;
    --help|-h)      sed -n '/^# /,/^$/{s/^# \{0,1\}//;p}' "$0" | sed '/^!/d'; exit 0 ;;
    *)              echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ─── Colors ────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  C_OK=$'\033[1;32m'; C_WARN=$'\033[1;33m'; C_ERR=$'\033[1;31m'
  C_DIM=$'\033[0;90m'; C_HDR=$'\033[1;36m'; C_RST=$'\033[0m'
else
  C_OK=''; C_WARN=''; C_ERR=''; C_DIM=''; C_HDR=''; C_RST=''
fi
log()  { echo "${C_DIM}[+]${C_RST} $*" >&2; }
warn() { echo "${C_WARN}[!]${C_RST} $*" >&2; }
fail() { echo "${C_ERR}[x]${C_RST} $*" >&2; exit 1; }

validate_cycle_seconds() {
  awk -v v="$CYCLE_SECONDS" '
    BEGIN {
      if (v !~ /^([0-9]+([.][0-9]*)?|[.][0-9]+)$/) exit 1
      n = v + 0
      if (n <= 0 || n > 60) exit 1
    }' || fail "--cycle must be a finite positive number no greater than 60 seconds"
}

validate_lock_wait() {
  awk -v v="$SPI_LOCK_WAIT" '
    BEGIN {
      if (v !~ /^([0-9]+([.][0-9]*)?|[.][0-9]+)$/) exit 1
      n = v + 0
      if (n < 0 || n > 600) exit 1
    }' || fail "SPI_LOCK_WAIT must be a number between 0 and 600 seconds"
}

validate_lock_dir() {
  [[ -d "$LOCK_DIR" ]] || fail "runtime lock dir missing: $LOCK_DIR (no XDG_RUNTIME_DIR?)"

  local owner mode
  owner=$(stat -c %u "$LOCK_DIR" 2>/dev/null) \
    || fail "unable to stat runtime lock dir: $LOCK_DIR"
  mode=$(stat -c %a "$LOCK_DIR" 2>/dev/null) \
    || fail "unable to stat runtime lock dir mode: $LOCK_DIR"

  [[ "$owner" == "$(id -u)" ]] \
    || fail "runtime lock dir is not owned by uid $(id -u): $LOCK_DIR"
  [[ $((8#$mode & 0022)) -eq 0 ]] \
    || fail "runtime lock dir must not be group/world writable: $LOCK_DIR"
}

acquire_lock() {
  validate_lock_dir
  exec 9>"$LOCK_FILE" || fail "unable to open lock file: $LOCK_FILE"
  flock -n 9 || fail "another sensor-read-debug-secure instance is already running"
}

# H1 fix: assert each named variable holds a valid hex byte before bash
# arithmetic context touches it. Indirect expansion (${!v}) resolves the name.
assert_hex_bytes() {
  local label=$1 v
  shift
  for v in "$@"; do
    [[ "${!v}" =~ $HEX_BYTE_RE ]] \
      || { warn "  $label malformed byte: ${v}=${!v}"; return 1; }
  done
}

# ─── Preflight ─────────────────────────────────────────────────────────
preflight() {
  log "preflight checks..."
  for cmd in i2cdetect i2ctransfer i2cset awk timeout python3 flock; do
    command -v "$cmd" >/dev/null || fail "missing command: $cmd"
  done
  [[ -c /dev/i2c-$BUS ]]   || fail "/dev/i2c-$BUS missing (run: sudo raspi-config nonint do_i2c 0)"
  [[ -c "$SPI_BUS_TOKEN" ]] || fail "$SPI_BUS_TOKEN missing (run: sudo raspi-config nonint do_spi 0 + reboot)"
  if [[ ! -r /dev/i2c-$BUS || ! -w /dev/i2c-$BUS ]] && [[ $EUID -ne 0 ]]; then
    fail "/dev/i2c-$BUS not user-accessible — sudo usermod -aG i2c \$USER, then newgrp i2c"
  fi
  if [[ ! -r "$SPI_BUS_TOKEN" || ! -w "$SPI_BUS_TOKEN" ]] && [[ $EUID -ne 0 ]]; then
    fail "$SPI_BUS_TOKEN not user-accessible — sudo usermod -aG spi \$USER, then newgrp spi"
  fi
  PYTHONSAFEPATH=1 python3 -I -c "import spidev, gpiozero, PIL" 2>/dev/null \
    || fail "missing Python deps — sudo apt install -y python3-spidev python3-gpiozero python3-pil"
  log "  i2c-1 and spidev0.0 present"
  log "  Python deps available"
}

# ─── Sensor reads ──────────────────────────────────────────────────────
read_hdc2010() {
  log "reading HDC2010 @ 0x40 (raw I2C)..."
  timeout 2 i2cset -y $BUS 0x40 0x0F 0x01 2>/dev/null \
    || { warn "  HDC2010 trigger failed"; echo "-- --"; return 1; }
  sleep 0.05
  local raw
  raw=$(timeout 2 i2ctransfer -y $BUS w1@0x40 0x00 r4 2>/dev/null) \
    || { warn "  HDC2010 read failed"; echo "-- --"; return 1; }
  local t_lsb t_msb rh_lsb rh_msb
  read -r t_lsb t_msb rh_lsb rh_msb <<< "$raw"
  assert_hex_bytes "HDC2010" t_lsb t_msb rh_lsb rh_msb || { echo "-- --"; return 1; }
  awk -v tl="$((t_lsb))" -v tm="$((t_msb))" -v rl="$((rh_lsb))" -v rm="$((rh_msb))" '
    BEGIN {
      t = (tm*256+tl)/65536.0*165.0 - 40.0
      h = (rm*256+rl)/65536.0*100.0
      printf "%.1f %.0f\n", t, h
    }'
}

read_opt3002() {
  log "reading OPT3002 @ 0x45 (raw I2C)..."
  timeout 2 i2ctransfer -y $BUS w3@0x45 0x01 0xCA 0x10 2>/dev/null \
    || { warn "  OPT3002 config failed"; echo "--"; return 1; }
  sleep 0.85
  local raw
  raw=$(timeout 2 i2ctransfer -y $BUS w1@0x45 0x00 r2 2>/dev/null) \
    || { warn "  OPT3002 read failed"; echo "--"; return 1; }
  local msb lsb
  read -r msb lsb <<< "$raw"
  assert_hex_bytes "OPT3002" msb lsb || { echo "--"; return 1; }
  awk -v m="$((msb))" -v l="$((lsb))" '
    BEGIN {
      w = m*256 + l
      e = int(w/4096); ma = w%4096
      printf "%.0f\n", 1.2 * (2^e) * ma
    }'
}

read_bmp280() {
  log "reading BMP280 (IIO sysfs)..."
  local d
  for d in /sys/bus/iio/devices/iio:device*; do
    [[ -d "$d" ]] || continue
    local name=$(cat "$d/name" 2>/dev/null)
    if [[ "$name" == bmp280* || "$name" == bme280* ]]; then
      local p_kpa
      p_kpa=$(cat "$d/in_pressure_input" 2>/dev/null) \
        || { warn "  bmp280 read failed"; echo "--"; return 1; }
      awk -v p="$p_kpa" 'BEGIN { printf "%.0f\n", p*10 }'
      return 0
    fi
  done
  warn "  no bmp280 IIO device found"
  echo "--"
  return 1
}

# ─── Main ──────────────────────────────────────────────────────────────
validate_cycle_seconds
validate_lock_wait
acquire_lock
preflight

echo "${C_DIM}══════════════════════════════════════════${C_RST}"
echo "${C_HDR}Coral Env Sensor — secure v4${C_RST}"
echo "${C_DIM}$(date -Iseconds) host=$(hostname -s)${C_RST}"
echo "${C_DIM}══════════════════════════════════════════${C_RST}"

if [[ $TEST_PATTERN_ONLY -eq 0 ]]; then
  HDC_READ=$(read_hdc2010 || true)
  READING_TEMP=$(echo "$HDC_READ" | awk '{print $1}')
  READING_HUMID=$(echo "$HDC_READ" | awk '{print $2}')
  READING_LIGHT=$(read_opt3002 || true)
  READING_PRESS=$(read_bmp280 || true)
  READING_TEMP=${READING_TEMP:---}
  READING_HUMID=${READING_HUMID:---}
  READING_LIGHT=${READING_LIGHT:---}
  READING_PRESS=${READING_PRESS:---}
  log "all reads complete:"
  log "  temp  = $READING_TEMP °C"
  log "  humid = $READING_HUMID %"
  log "  press = $READING_PRESS hPa"
  log "  light = $READING_LIGHT nW/cm²"
else
  READING_TEMP="" READING_HUMID="" READING_PRESS="" READING_LIGHT=""
fi

export READING_TEMP READING_HUMID READING_PRESS READING_LIGHT
export LOOP_MODE CYCLE_SECONDS TEST_PATTERN_ONLY
export SPI_BUS_TOKEN SPI_LOCK_WAIT

echo
log "starting OLED block via raw spidev (SPI0 bus lock active)..."
echo

# ─── OLED via raw spidev (Python heredoc) ─────────────────────────────
PYTHONSAFEPATH=1 python3 -I - <<'PYEOF'
import atexit
import errno
import fcntl
import math
import os
import sys
import time
import traceback

def log(msg):
    print(f"  [oled] {msg}", file=sys.stderr, flush=True)

try:
    import spidev
    from gpiozero import DigitalOutputDevice
    from PIL import Image, ImageDraw, ImageFont
except ImportError as e:
    sys.exit(f"  [oled] import failed: {e}")

# ── Shared SPI0 bus lock ──────────────────────────────────────────────
# flock(2) on the bus token. SAME mechanism + SAME path as Spi0BusLock in
# epd2in7v2.py, so the OLED and the e-ink driver mutually exclude. Held per
# transaction (init / each frame), released between — so the e-ink can use
# the bus during our cycle sleep.
SPI_BUS_TOKEN = os.environ.get("SPI_BUS_TOKEN", "/dev/spidev0.0")
SPI_LOCK_WAIT = float(os.environ.get("SPI_LOCK_WAIT", "10"))

class SpiBus:
    def __init__(self, token, wait):
        if not os.path.exists(token):
            sys.exit(f"  [oled] bus token missing: {token}")
        self._fd = os.open(token, os.O_RDWR)   # node must exist; never O_CREAT
        self._wait = wait
    def hold(self):
        return _BusHold(self._fd, self._wait)
    def close(self):
        try:
            os.close(self._fd)
        except OSError:
            pass

class _BusHold:
    def __init__(self, fd, wait):
        self._fd = fd
        self._wait = wait
    def __enter__(self):
        deadline = time.monotonic() + self._wait
        while True:
            try:
                fcntl.flock(self._fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return self
            except OSError as e:
                if e.errno not in (errno.EWOULDBLOCK, errno.EACCES):
                    raise
                if time.monotonic() > deadline:
                    sys.exit(f"  [oled] SPI0 bus busy after {self._wait}s — e-ink holding it?")
                time.sleep(0.05)
    def __exit__(self, *exc):
        fcntl.flock(self._fd, fcntl.LOCK_UN)

# ── Setup ─────────────────────────────────────────────────────────────
DC = None
RST = None
spi = None
bus = None

log("creating GPIO controllers for DC=24, RST=25")
DC = DigitalOutputDevice(24, initial_value=False)
RST = DigitalOutputDevice(25, initial_value=True)

log("opening SPI bus 0 device 0")
spi = spidev.SpiDev()
spi.open(0, 0)
spi.max_speed_hz = 8_000_000
spi.mode = 0

log(f"opening SPI0 bus lock on {SPI_BUS_TOKEN} (wait {SPI_LOCK_WAIT}s)")
bus = SpiBus(SPI_BUS_TOKEN, SPI_LOCK_WAIT)

# ── Low-level I/O (always called inside `with bus.hold()`) ────────────
def cmd(*b):
    DC.off()
    spi.writebytes(list(b))

def data(b):
    DC.on()
    CHUNK = 4096
    for i in range(0, len(b), CHUNK):
        spi.writebytes(b[i:i+CHUNK])

# ── Cleanup (atexit, runs after everything else) ──────────────────────
def cleanup_resources():
    if spi is not None and DC is not None and bus is not None:
        try:
            log("clearing and turning off display")
            with bus.hold():
                cmd(0x21, 0, 127); cmd(0x22, 0, 3); data([0] * 512)
                cmd(0xAE)
        except SystemExit:
            log("could not acquire bus for cleanup; leaving display as-is")
        except Exception as e:
            log(f"cleanup failed: {e}")
    if spi is not None:
        try: spi.close()
        except Exception as e: log(f"SPI close failed: {e}")
    for device in (DC, RST):
        if device is not None:
            try: device.close()
            except Exception as e: log(f"GPIO close failed: {e}")
    if bus is not None:
        bus.close()

atexit.register(cleanup_resources)

# ── Hardware reset + init (one atomic bus transaction) ────────────────
with bus.hold():
    log("hardware reset pulse on RST")
    RST.off(); time.sleep(0.01); RST.on(); time.sleep(0.1)
    log("sending SSD1306 init sequence (128x32 variant)")
    INIT_SEQ = [
        (0xAE,),        # display OFF
        (0xD5, 0x80),   # clock divide ratio + oscillator freq
        (0xA8, 0x1F),   # multiplex ratio = 31 (32-row panel)
        (0xD3, 0x00),   # display offset 0
        (0x40,),        # start line = 0
        (0x8D, 0x14),   # charge pump ON
        (0x20, 0x00),   # horizontal addressing mode
        (0xA1,),        # segment remap (col 127 → SEG0)
        (0xC8,),        # COM scan direction reversed
        (0xDA, 0x02),   # COM pins hw config: 32-row sequential
        (0x81, 0xCF),   # contrast
        (0xD9, 0xF1),   # precharge period
        (0xDB, 0x40),   # vcomh deselect level
        (0xA4,),        # output follows GDDRAM
        (0xA6,),        # normal display
        (0xAF,),        # display ON
    ]
    for seq in INIT_SEQ:
        cmd(*seq)
log("init complete")

# ── Framebuffer conversion ────────────────────────────────────────────
def image_to_ssd1306_bytes(img):
    w, h = img.size
    pages = h // 8
    px = img.load()
    out = bytearray(w * pages)
    for page in range(pages):
        for col in range(w):
            b = 0
            for bit in range(8):
                if px[col, page*8 + bit]:
                    b |= (1 << bit)
            out[page * w + col] = b
    return list(out)

def push_image(img, label=""):
    buf = image_to_ssd1306_bytes(img)   # render outside the lock (CPU only)
    with bus.hold():                     # hold bus only for the transfer
        cmd(0x21, 0, 127)
        cmd(0x22, 0, 3)
        data(buf)

# ── Rendering helpers ─────────────────────────────────────────────────
font = ImageFont.load_default()

def _scaled_text_image(text, scale):
    """1-bit PIL image of `text` rendered at `scale`x (nearest neighbour)."""
    tmp = Image.new("1", (1, 1), 0)
    bbox = ImageDraw.Draw(tmp).textbbox((0, 0), text, font=font)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    tmp = Image.new("1", (tw + 2, th + 2), 0)
    ImageDraw.Draw(tmp).text((1, 1), text, fill=1, font=font)
    if scale > 1:
        tmp = tmp.resize((tmp.size[0]*scale, tmp.size[1]*scale), Image.NEAREST)
    return tmp

def render_centered(text, max_scale=2):
    """Auto-scale (largest that fits) and centre on the full panel."""
    img = Image.new("1", (128, 32), 0)
    for scale in range(max_scale, 0, -1):
        tmp = _scaled_text_image(text, scale)
        if tmp.size[0] <= 128 and tmp.size[1] <= 32:
            px = max(0, (128 - tmp.size[0]) // 2)
            py = max(0, (32 - tmp.size[1]) // 2)
            img.paste(tmp, (px, py))
            return img
    ImageDraw.Draw(img).text((2, 12), text[:20], fill=1, font=font)
    return img

def render_reading(label, value, unit):
    """Label small at top-left; value+unit BOTTOM-ANCHORED so no clip.
    Auto-scales 2x → 1x if text would overflow width."""
    img = Image.new("1", (128, 32), 0)
    ImageDraw.Draw(img).text((2, 0), label, fill=1, font=font)
    text = f"{value} {unit}"
    for scale in (2, 1):
        tmp = _scaled_text_image(text, scale)
        if tmp.size[0] <= 128 and tmp.size[1] <= 22:
            px = max(0, (128 - tmp.size[0]) // 2)
            py = max(10, 32 - tmp.size[1])   # bottom-anchored
            img.paste(tmp, (px, py))
            return img
    ImageDraw.Draw(img).text((2, 18), text[:21], fill=1, font=font)
    return img

# ── Hello splash ──────────────────────────────────────────────────────
log("displaying hello splash")
push_image(render_centered("hello"), "hello")
time.sleep(2)

# ── Test-pattern mode: hello → bye → exit (OLED-only health check) ────
if os.environ.get("TEST_PATTERN_ONLY") == "1":
    log("test-pattern mode — showing bye and exiting")
    push_image(render_centered("bye"), "bye")
    time.sleep(1.5)
    sys.exit(0)

# ── Sensor cycle ──────────────────────────────────────────────────────
readings = [
    ("TEMPERATURE", os.environ.get("READING_TEMP", "--"), "C"),
    ("HUMIDITY",    os.environ.get("READING_HUMID", "--"), "%"),
    ("PRESSURE",    os.environ.get("READING_PRESS", "--"), "hPa"),
    ("LIGHT",       os.environ.get("READING_LIGHT", "--"), "nW/cm2"),
]
cycle_s = float(os.environ.get("CYCLE_SECONDS", "3"))
if not math.isfinite(cycle_s) or cycle_s <= 0 or cycle_s > 60:
    sys.exit("  [oled] invalid CYCLE_SECONDS")
loop = os.environ.get("LOOP_MODE", "once") == "forever"

def run_cycle():
    for label, val, unit in readings:
        push_image(render_reading(label, val, unit), f"{label}={val}{unit}")
        time.sleep(cycle_s)   # bus released here — e-ink may refresh

log(f"=== cycling readings (cycle={cycle_s}s, loop={loop}) ===")
try:
    if loop:
        while True:
            run_cycle()
    else:
        run_cycle()
except KeyboardInterrupt:
    log("interrupted by user")
except Exception:
    traceback.print_exc(file=sys.stderr)
    raise
finally:
    try:
        log("displaying bye splash")
        push_image(render_centered("bye"), "bye")
        time.sleep(1.5)
    except Exception as e:
        log(f"bye display failed: {e}")
    log("done.")
PYEOF
PY_EXIT=$?

echo
if [[ $PY_EXIT -eq 0 ]]; then
  echo "${C_OK}OLED run completed.${C_RST}"
else
  echo "${C_ERR}OLED run exited with code $PY_EXIT.${C_RST}"
fi
