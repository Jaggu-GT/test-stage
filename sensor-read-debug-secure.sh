#!/usr/bin/env bash
# sensor-read-debug.sh — Coral Env Sensor Board readout with RAW SPIDEV OLED
#
# Purpose: bypass luma.oled completely. Drive the SSD1306 with direct SPI
# writes and explicit DC pin control, so we can pinpoint where luma's
# framebuffer flush is going wrong.
#
# Display behavior (intentionally simple for debug):
#   Cycles through 4 sensor readings, one per OLED page, ~3 seconds each.
#   Each page shows label (top) + value + metric unit (bottom).
#
# Verbose stderr logging at every SPI/GPIO step. Watch the terminal to see
# exactly where execution stalls or errors.
#
# Sensors:
#   HDC2010 @ 0x40   raw I2C
#   OPT3002 @ 0x45   raw I2C
#   BMP280  via IIO sysfs (kernel-claimed)
#
# OLED:
#   SSD1306 128x32, SPI0 device 0, DC=GPIO24, RST=GPIO25
#   Hand-rolled init sequence, manual PIL image → SSD1306 byte conversion
#
# Requires:
#   - bash, i2c-tools, awk, timeout
#   - python3, python3-spidev, python3-gpiozero, python3-pil
#   - /dev/i2c-1 and /dev/spidev0.0 enabled
#   - user in 'i2c' and 'spi' groups
#
# Usage:
#   chmod +x sensor-read-debug.sh
#   ./sensor-read-debug.sh                  # one cycle through 4 readings
#   ./sensor-read-debug.sh --loop           # forever
#   ./sensor-read-debug.sh --cycle 5        # 5s per reading instead of 3
#   ./sensor-read-debug.sh --test-pattern   # only show test patterns, skip sensors
#
# Security hardening in this version:
#   - isolates Python imports from cwd/user site paths
#   - validates --cycle as a finite positive duration
#   - uses trusted system command paths
#   - serializes runs with an advisory lock
#   - performs best-effort OLED cleanup on Python errors

set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C

BUS=1
LOCK_FILE="/tmp/sensor-read-debug.lock"
LOOP_MODE="once"
CYCLE_SECONDS="3"
TEST_PATTERN_ONLY=0

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
    C_OK=$'\033[1;32m'; C_WARN=$'\033[1;33m'; C_ERR=$'\033[1;31m'
    C_DIM=$'\033[0;90m'; C_HDR=$'\033[1;36m'; C_RST=$'\033[0m'
else
    C_OK=''; C_WARN=''; C_ERR=''; C_DIM=''; C_HDR=''; C_RST=''
fi

log()    { echo "${C_DIM}[+]${C_RST} $*" >&2; }
warn()   { echo "${C_WARN}[!]${C_RST} $*" >&2; }
fail()   { echo "${C_ERR}[x]${C_RST} $*" >&2; exit 1; }


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
    flock -n 9 || fail "another sensor-read-debug instance is already running"
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

# ─── Sensor reads (minimal, just the working paths) ───────────────────
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
echo "${C_HDR}Coral Env Sensor — RAW SPIDEV debug${C_RST}"
echo "${C_DIM}$(date -Iseconds)  host=$(hostname -s)${C_RST}"
echo "${C_DIM}══════════════════════════════════════════${C_RST}"

# Read sensors once (unless --test-pattern only)
if [[ $TEST_PATTERN_ONLY -eq 0 ]]; then
    HDC_READ=$(read_hdc2010)
    READING_TEMP=$(echo "$HDC_READ" | awk '{print $1}')
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

# Export everything the Python OLED block needs
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
DC  = DigitalOutputDevice(24, initial_value=False)
RST = DigitalOutputDevice(25, initial_value=True)
log(f"  DC.value={DC.value}, RST.value={RST.value}")

log("opening SPI bus 0 device 0")
spi = spidev.SpiDev()
spi.open(0, 0)
spi.max_speed_hz = 8_000_000
spi.mode = 0
log(f"  SPI configured: speed={spi.max_speed_hz} Hz, mode={spi.mode}")

# ── Helpers ───────────────────────────────────────────────────────────
def cmd(*b):
    """Send command byte(s) — DC low."""
    DC.off()
    spi.writebytes(list(b))

def data(b):
    """Send data byte(s) — DC high."""
    DC.on()
    # Chunk large writes to stay under spidev's typical 4096-byte limit
    CHUNK = 4096
    for i in range(0, len(b), CHUNK):
        spi.writebytes(b[i:i+CHUNK])

def cleanup_resources():
    """Best-effort cleanup for normal exits, sys.exit, and unhandled errors."""
    if spi is not None and DC is not None:
        try:
            log("clearing and turning off display")
            cmd(0x21, 0, 127); cmd(0x22, 0, 3); data([0] * 512)
            cmd(0xAE)
        except Exception as e:
            log(f"cleanup failed: {e}")
    if spi is not None:
        try:
            spi.close()
        except Exception as e:
            log(f"SPI close failed: {e}")
    for device in (DC, RST):
        if device is not None:
            try:
                device.close()
            except Exception as e:
                log(f"GPIO close failed: {e}")

atexit.register(cleanup_resources)

# ── Hardware reset + init ─────────────────────────────────────────────
log("hardware reset pulse on RST")
RST.off(); time.sleep(0.01); RST.on(); time.sleep(0.1)

log("sending SSD1306 init sequence (128x32 variant)")
INIT_SEQ = [
    (0xAE,),         # display OFF
    (0xD5, 0x80),    # clock divide ratio + oscillator freq
    (0xA8, 0x1F),    # multiplex ratio = 31 (for 32-row panel)
    (0xD3, 0x00),    # display offset 0
    (0x40,),         # start line = 0
    (0x8D, 0x14),    # charge pump ON
    (0x20, 0x00),    # memory addressing mode = horizontal
    (0xA1,),         # segment remap (column 127 → SEG0)
    (0xC8,),         # COM scan direction reversed
    (0xDA, 0x02),    # COM pins hw config: sequential, no remap (32-row)
    (0x81, 0xCF),    # contrast
    (0xD9, 0xF1),    # precharge period
    (0xDB, 0x40),    # vcomh deselect level
    (0xA4,),         # output follows GDDRAM contents
    (0xA6,),         # normal display (not inverted)
    (0xAF,),         # display ON
]
for seq in INIT_SEQ:
    log(f"  cmd: {' '.join(f'0x{b:02X}' for b in seq)}")
    cmd(*seq)
log("init complete")

# ── Framebuffer conversion ────────────────────────────────────────────
def image_to_ssd1306_bytes(img):
    """Pack a PIL '1' mode 128x32 image into 512 SSD1306 bytes.
       Page layout: 4 pages of 8 rows each. Each byte = 8 vertical pixels."""
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
    """Write a PIL image to the OLED via raw SPI."""
    log(f"pushing image to OLED ({label})")
    buf = image_to_ssd1306_bytes(img)
    log(f"  framebuffer: {len(buf)} bytes")
    # Set window to full screen
    cmd(0x21, 0, 127)   # column addr range
    cmd(0x22, 0, 3)     # page addr range (4 pages for 32 rows)
    data(buf)
    log(f"  data written, DC now {'HIGH' if DC.value else 'LOW'}")

# ── Self-test patterns (always shown, regardless of mode) ─────────────
log("=== self-test: solid white ===")
img = Image.new("1", (128, 32), 1)
push_image(img, "all-on")
time.sleep(2)

log("=== self-test: solid black ===")
img = Image.new("1", (128, 32), 0)
push_image(img, "all-off")
time.sleep(1)

log("=== self-test: checkerboard ===")
img = Image.new("1", (128, 32), 0)
draw = ImageDraw.Draw(img)
for y in range(0, 32, 4):
    for x in range(0, 128, 4):
        if ((x // 4) + (y // 4)) % 2 == 0:
            draw.rectangle([x, y, x+3, y+3], fill=1)
push_image(img, "checker")
time.sleep(2)

if os.environ.get("TEST_PATTERN_ONLY") == "1":
    log("test-pattern-only mode — clearing and exiting")
    cmd(0x21, 0, 127); cmd(0x22, 0, 3); data([0] * 512)
    cmd(0xAE)  # display off
    sys.exit(0)

# ── Render text per reading ───────────────────────────────────────────
font = ImageFont.load_default()

def render_reading(label, value, unit):
    """Render one reading: label small-top, value big-bottom centered."""
    img = Image.new("1", (128, 32), 0)
    d = ImageDraw.Draw(img)
    # Label on top, left-aligned
    d.text((2, 2), label, fill=1, font=font)
    # Value + unit on bottom, drawn larger via 2x scaling
    text = f"{value} {unit}"
    bbox = d.textbbox((0, 0), text, font=font)
    tw = bbox[2] - bbox[0]
    th = bbox[3] - bbox[1]
    # Render to small image then scale 2x
    tmp = Image.new("1", (tw + 2, th + 2), 0)
    ImageDraw.Draw(tmp).text((1, 1), text, fill=1, font=font)
    tmp = tmp.resize((tmp.size[0]*2, tmp.size[1]*2), Image.NEAREST)
    # Paste centered in lower portion (y >= 12)
    paste_x = (128 - tmp.size[0]) // 2
    paste_y = 14
    if paste_x < 0: paste_x = 0
    img.paste(tmp, (paste_x, paste_y))
    return img

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
        img = render_reading(label, val, unit)
        push_image(img, f"{label}={val}{unit}")
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
log("done.")
PYEOF

PY_EXIT=$?
echo
if [[ $PY_EXIT -eq 0 ]]; then
    echo "${C_OK}OLED debug run completed.${C_RST}"
else
    echo "${C_ERR}OLED debug run exited with code $PY_EXIT.${C_RST}"
fi
