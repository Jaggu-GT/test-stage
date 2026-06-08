#!/usr/bin/env bash
# sensor-read-debug-secure-v2.sh — Coral Env Sensor Board readout
#
# Changes from sensor-read-debug-secure.sh (v1):
#   * H1 fix: hex regex validation on every I2C byte before $((..)) arithmetic
#   * Replaces 3-pattern self-test (white/black/checker) with "hello" splash
#     on startup and "bye" on exit
#   * Fixes bottom-row text clipping: value text now anchored to bottom edge
#     and auto-scales 2x → 1x if the rendered string would overflow width
#   * --test-pattern now means "hello/bye OLED smoke test, skip sensors"
#
# Preserved from v1:
#   * Pinned PATH, single-instance flock, PYTHONSAFEPATH+isolated Python
#   * atexit-based GPIO/SPI/OLED cleanup
#   * --cycle validation (0 < n ≤ 60), --loop, --help unchanged
#
# Sensors (per pinout.xyz):
#   HDC2010 @ 0x40    raw I2C
#   OPT3002 @ 0x45    raw I2C
#   BMP280            IIO sysfs (kernel-claimed)
#
# OLED:
#   SSD1306 128x32, SPI0 device 0, DC=GPIO24, RST=GPIO25
#
# Requires:
#   - bash, i2c-tools, awk, timeout, flock
#   - python3 (≥3.11 for PYTHONSAFEPATH), python3-spidev, python3-gpiozero, python3-pil
#   - /dev/i2c-1 and /dev/spidev0.0; user in 'i2c' and 'spi' groups
#
# Usage:
#   chmod +x sensor-read-debug-secure-v2.sh
#   ./sensor-read-debug-secure-v2.sh                   # hello → sensors → bye
#   ./sensor-read-debug-secure-v2.sh --loop            # hello → forever → (Ctrl-C) → bye
#   ./sensor-read-debug-secure-v2.sh --cycle 5         # 5s per reading
#   ./sensor-read-debug-secure-v2.sh --test-pattern    # hello + bye only

set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C

BUS=1
LOCK_FILE="/tmp/sensor-read-debug-secure.lock"
LOOP_MODE="once"
CYCLE_SECONDS="3"
TEST_PATTERN_ONLY=0

# H1 fix: regex used for every hex byte coming from i2ctransfer/i2cget before
# it is fed into $((..)) arithmetic context (which recursively evaluates).
readonly HEX_BYTE_RE='^0x[0-9a-fA-F]{1,2}$'

while [[ $# -gt 0 ]]; do
    case "$1" in
        --loop)
            LOOP_MODE="forever"
            shift ;;
        --cycle)
            [[ $# -ge 2 ]] || { echo "Missing value for --cycle" >&2; exit 2; }
            CYCLE_SECONDS="$2"
            shift 2 ;;
        --cycle=*)
            CYCLE_SECONDS="${1#*=}"
            shift ;;
        --test-pattern)
            TEST_PATTERN_ONLY=1
            shift ;;
        --help|-h)
            sed -n '/^# /,/^$/{s/^# \{0,1\}//;p}' "$0" | sed '/^!/d'
            exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

# ─── Colors ────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    C_OK=$'\033[1;32m';   C_WARN=$'\033[1;33m'; C_ERR=$'\033[1;31m'
    C_DIM=$'\033[0;90m';  C_HDR=$'\033[1;36m';  C_RST=$'\033[0m'
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

acquire_lock() {
    exec 9>"$LOCK_FILE" || fail "unable to open lock file: $LOCK_FILE"
    flock -n 9 || fail "another sensor-read-debug-secure instance is already running"
}

# H1 fix: assert each named variable holds a valid hex byte before
# bash arithmetic context touches it. Indirect expansion (${!v}) resolves
# the variable name passed by the caller.
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

    [[ -c /dev/i2c-$BUS ]]    || fail "/dev/i2c-$BUS missing (run: sudo raspi-config nonint do_i2c 0)"
    [[ -c /dev/spidev0.0 ]]   || fail "/dev/spidev0.0 missing (run: sudo raspi-config nonint do_spi 0 + reboot)"

    if [[ ! -r /dev/i2c-$BUS  || ! -w /dev/i2c-$BUS  ]] && [[ $EUID -ne 0 ]]; then
        fail "/dev/i2c-$BUS not user-accessible — sudo usermod -aG i2c \$USER, then newgrp i2c"
    fi
    if [[ ! -r /dev/spidev0.0 || ! -w /dev/spidev0.0 ]] && [[ $EUID -ne 0 ]]; then
        fail "/dev/spidev0.0 not user-accessible — sudo usermod -aG spi \$USER, then newgrp spi"
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

    # H1 fix: validate hex before $((..)) arithmetic context
    assert_hex_bytes "HDC2010" t_lsb t_msb rh_lsb rh_msb \
        || { echo "-- --"; return 1; }

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

    # H1 fix: validate hex before $((..)) arithmetic context
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
acquire_lock
preflight

echo "${C_DIM}══════════════════════════════════════════${C_RST}"
echo "${C_HDR}Coral Env Sensor — secure v2${C_RST}"
echo "${C_DIM}$(date -Iseconds)  host=$(hostname -s)${C_RST}"
echo "${C_DIM}══════════════════════════════════════════${C_RST}"

if [[ $TEST_PATTERN_ONLY -eq 0 ]]; then
    HDC_READ=$(read_hdc2010)
    READING_TEMP=$(echo "$HDC_READ"  | awk '{print $1}')
    READING_HUMID=$(echo "$HDC_READ" | awk '{print $2}')
    READING_LIGHT=$(read_opt3002)
    READING_PRESS=$(read_bmp280)
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

echo
log "starting OLED block via raw spidev..."
echo

# ─── OLED via raw spidev (Python heredoc) ─────────────────────────────
PYTHONSAFEPATH=1 python3 -I - <<'PYEOF'
import atexit
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

# ── Setup ─────────────────────────────────────────────────────────────
DC = None
RST = None
spi = None

log("creating GPIO controllers for DC=24, RST=25")
DC = DigitalOutputDevice(24, initial_value=False)
RST = DigitalOutputDevice(25, initial_value=True)

log("opening SPI bus 0 device 0")
spi = spidev.SpiDev()
spi.open(0, 0)
spi.max_speed_hz = 8_000_000
spi.mode = 0

# ── Low-level I/O ─────────────────────────────────────────────────────
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
    if spi is not None and DC is not None:
        try:
            log("clearing and turning off display")
            cmd(0x21, 0, 127); cmd(0x22, 0, 3); data([0] * 512)
            cmd(0xAE)
        except Exception as e:
            log(f"cleanup failed: {e}")
    if spi is not None:
        try: spi.close()
        except Exception as e: log(f"SPI close failed: {e}")
    for device in (DC, RST):
        if device is not None:
            try: device.close()
            except Exception as e: log(f"GPIO close failed: {e}")

atexit.register(cleanup_resources)

# ── Hardware reset + init ─────────────────────────────────────────────
log("hardware reset pulse on RST")
RST.off(); time.sleep(0.01); RST.on(); time.sleep(0.1)

log("sending SSD1306 init sequence (128x32 variant)")
INIT_SEQ = [
    (0xAE,),         # display OFF
    (0xD5, 0x80),    # clock divide ratio + oscillator freq
    (0xA8, 0x1F),    # multiplex ratio = 31 (32-row panel)
    (0xD3, 0x00),    # display offset 0
    (0x40,),         # start line = 0
    (0x8D, 0x14),    # charge pump ON
    (0x20, 0x00),    # horizontal addressing mode
    (0xA1,),         # segment remap (col 127 → SEG0)
    (0xC8,),         # COM scan direction reversed
    (0xDA, 0x02),    # COM pins hw config: 32-row sequential
    (0x81, 0xCF),    # contrast
    (0xD9, 0xF1),    # precharge period
    (0xDB, 0x40),    # vcomh deselect level
    (0xA4,),         # output follows GDDRAM
    (0xA6,),         # normal display
    (0xAF,),         # display ON
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
    buf = image_to_ssd1306_bytes(img)
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
            py = max(0, (32  - tmp.size[1]) // 2)
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
            # Bottom-anchored: bottom of scaled text touches y=31 (last row)
            py = max(10, 32 - tmp.size[1])
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
    ("TEMPERATURE", os.environ.get("READING_TEMP",  "--"), "C"),
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
        time.sleep(cycle_s)

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
    # Always try to leave a "bye" before atexit clears the screen.
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
