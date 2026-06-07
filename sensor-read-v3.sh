#!/usr/bin/env bash
# sensor-read-v3.sh — Coral Environmental Sensor Board readout
#
# v3 changes from v2 (display only):
#   * OLED redesign: white background, black icons + text (inverted look)
#   * 2x2 grid layout — all four readings on screen simultaneously
#   * Custom 1-bit pixel-art icons drawn programmatically (thermometer,
#     droplet, gauge, sun) instead of word labels
#   * Crisp legacy bitmap font (CP437) for value text
#   * Sensor logic, IIO/raw I2C fallback, security hardening (PATH, hex regex,
#     flock, timeouts, TTY colors), --no-oled and --json flags all unchanged
#
# Layout (128x32):
#   ┌─────────────────────┬─────────────────────┐
#   │ [thermo]  22.0C     │ [droplet]  50%      │
#   ├─────────────────────┼─────────────────────┤
#   │ [gauge]   1013      │ [sun]      5260     │
#   └─────────────────────┴─────────────────────┘
#
# Sensors (per pinout.xyz):
#   HDC2010   @ 0x40   temp + humidity            (IIO: hdc2010 / hdc100x)
#   OPT3002   @ 0x45   ambient irradiance         (IIO: opt3001 — chip-dependent)
#   BMP280    @ 0x76/0x77   barometric pressure   (IIO: bmp280)
#   ECC608    @ 0x30   secure element             (presence only)
#   TLA2021   @ 0x49   analog ADC (Grove)         (informational)
#   SSD1306   SPI0 CE0   OLED display             (DC=GPIO24, RST=GPIO25)
#
# Required: bash, i2c-tools, awk, flock, timeout.
# Optional (OLED): python3, python3-luma.oled, /dev/spidev0.0, 'spi' group.
#
# Usage:
#   chmod +x sensor-read-v3.sh
#   ./sensor-read-v3.sh             # read sensors + draw OLED
#   ./sensor-read-v3.sh --no-oled
#   ./sensor-read-v3.sh --json

set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C

# ─── Constants ─────────────────────────────────────────────────────────
BUS=1
LOCK_FILE=/run/lock/coral-i2c.lock
HEX_RE='^0x[0-9a-fA-F]{1,2}$'

HDC2010_ADDR=0x40
OPT3002_PRIMARY=0x45
OPT3002_FALLBACK=0x44
BMP280_PRIMARY=0x76
BMP280_FALLBACK=0x77
ECC608_ADDR=0x30
TLA2021_ADDR=0x49

READ_TEMP_C=""
READ_HUMID_PCT=""
READ_PRESS_HPA=""
READ_LIGHT_NWCM2=""

# ─── Args ──────────────────────────────────────────────────────────────
WANT_OLED=1
JSON_MODE=0
for arg in "$@"; do
    case "$arg" in
        --no-oled) WANT_OLED=0 ;;
        --json)    JSON_MODE=1; WANT_OLED=0 ;;
        --help|-h) sed -n '/^# /,/^$/{s/^# \{0,1\}//;p}' "$0" | sed '/^!/d'; exit 0 ;;
        *) echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done

# ─── Colors (TTY-detect) ───────────────────────────────────────────────
if [[ -t 1 && $JSON_MODE -eq 0 ]]; then
    C_OK=$'\033[1;32m'; C_WARN=$'\033[1;33m'; C_ERR=$'\033[1;31m'
    C_DIM=$'\033[0;90m'; C_HDR=$'\033[1;36m'; C_RST=$'\033[0m'
else
    C_OK=''; C_WARN=''; C_ERR=''; C_DIM=''; C_HDR=''; C_RST=''
fi

# ─── Preflight ─────────────────────────────────────────────────────────
preflight() {
    for cmd in i2cdetect i2ctransfer i2cget i2cset awk flock timeout; do
        command -v "$cmd" >/dev/null \
            || { echo "${C_ERR}missing: $cmd${C_RST}" >&2; exit 1; }
    done
    [[ -c /dev/i2c-$BUS ]] \
        || { echo "${C_ERR}/dev/i2c-$BUS missing — enable: sudo raspi-config nonint do_i2c 0${C_RST}" >&2; exit 1; }
    if [[ ! -r /dev/i2c-$BUS || ! -w /dev/i2c-$BUS ]] && [[ $EUID -ne 0 ]]; then
        echo "${C_ERR}/dev/i2c-$BUS not user-accessible. sudo, or join 'i2c' group${C_RST}" >&2
        exit 1
    fi
    exec 9>"$LOCK_FILE" 2>/dev/null || { LOCK_FILE=/tmp/coral-i2c.lock; exec 9>"$LOCK_FILE"; }
    flock -w 5 9 || { echo "${C_ERR}/dev/i2c-$BUS busy after 5s${C_RST}" >&2; exit 1; }
}

# ─── Helpers ───────────────────────────────────────────────────────────
validate_hex_byte() { [[ $1 =~ $HEX_RE ]] || { echo "i2c output malformed: '$1'" >&2; return 1; }; }

hex_to_dec() {
    local out=""
    for b in $1; do
        validate_hex_byte "$b" || return 1
        out+="$((b)) "
    done
    echo "$out"
}

find_iio_device() {
    local pattern=$1 d name
    for d in /sys/bus/iio/devices/iio:device*; do
        [[ -d "$d" ]] || continue
        name=$(cat "$d/name" 2>/dev/null || echo "")
        if [[ "$name" =~ $pattern ]]; then echo "$d"; return 0; fi
    done
    return 1
}

read_iio_channel() {
    local iio_dir=$1 channel=$2 raw scale offset
    if [[ -f "$iio_dir/${channel}_input" ]]; then
        cat "$iio_dir/${channel}_input"; return 0
    fi
    if [[ -f "$iio_dir/${channel}_raw" ]]; then
        raw=$(cat "$iio_dir/${channel}_raw")
        scale=$(cat "$iio_dir/${channel}_scale" 2>/dev/null || echo "1")
        offset=$(cat "$iio_dir/${channel}_offset" 2>/dev/null || echo "0")
        awk -v r="$raw" -v s="$scale" -v o="$offset" 'BEGIN { print (r + o) * s }'
        return 0
    fi
    return 1
}

detect_addr() {
    local addr=$1
    local row=$(((addr & 0xF0) >> 4))
    local col=$((addr & 0x0F))
    local line cell
    line=$(i2cdetect -y $BUS 2>/dev/null | awk -v row="$row" 'NR > 1 && $1 == sprintf("%d0:", row) { print }')
    cell=$(echo "$line" | awk -v col="$col" '{ print $(col + 2) }')
    if [[ "$cell" == "$(printf '%02x' $addr)" ]] || [[ "$cell" == "UU" ]]; then
        printf "0x%02x" $addr
    else
        echo "MISSING"
    fi
}

# ─── HDC2010 ───────────────────────────────────────────────────────────
read_hdc2010_iio() {
    local d t h
    d=$(find_iio_device "hdc(2010|100x)") || return 1
    t=$(read_iio_channel "$d" in_temp) || return 1
    h=$(read_iio_channel "$d" in_humidityrelative) || return 1
    awk -v t="$t" -v h="$h" '
    BEGIN {
        if (t > 200 || t < -50) t = t / 1000.0
        if (h > 100) h = h / 1000.0
        printf "%.2f %.2f\n", t, h
    }'
}

read_hdc2010_raw() {
    local addr=$HDC2010_ADDR raw t_lsb t_msb rh_lsb rh_msb
    timeout 2 i2cset -y $BUS $addr 0x0F 0x01 || return 1
    sleep 0.05
    raw=$(timeout 2 i2ctransfer -y $BUS w1@$addr 0x00 r4) || return 1
    read -r t_lsb t_msb rh_lsb rh_msb <<< "$raw"
    for v in t_lsb t_msb rh_lsb rh_msb; do validate_hex_byte "${!v}" || return 1; done
    awk -v tl="$((t_lsb))" -v tm="$((t_msb))" -v rl="$((rh_lsb))" -v rm="$((rh_msb))" '
    BEGIN {
        t_raw  = tm * 256 + tl
        rh_raw = rm * 256 + rl
        printf "%.2f %.2f\n", (t_raw/65536.0)*165.0 - 40.0, (rh_raw/65536.0)*100.0
    }'
}

read_hdc2010() {
    local result via
    if result=$(read_hdc2010_iio 2>/dev/null); then via="IIO"
    elif result=$(read_hdc2010_raw); then via="raw I2C"
    else echo "  ${C_ERR}HDC2010 read failed${C_RST}"; return 1
    fi
    READ_TEMP_C=$(echo "$result" | awk '{print $1}')
    READ_HUMID_PCT=$(echo "$result" | awk '{print $2}')
    printf "  Temperature: %.2f °C  (%.2f °F)   ${C_DIM}[%s]${C_RST}\n" \
        "$READ_TEMP_C" "$(awk -v t="$READ_TEMP_C" 'BEGIN { print t*9/5+32 }')" "$via"
    printf "  Humidity:    %.2f %% RH                ${C_DIM}[%s]${C_RST}\n" "$READ_HUMID_PCT" "$via"
}

# ─── OPT3002 ───────────────────────────────────────────────────────────
read_opt3002_iio() {
    local d val
    d=$(find_iio_device "opt300[12]") || return 1
    val=$(read_iio_channel "$d" in_intensity) || val=$(read_iio_channel "$d" in_illuminance) || return 1
    echo "$val IIO"
}

read_opt3002_raw() {
    local addr=$1 raw msb lsb
    timeout 2 i2ctransfer -y $BUS w3@$addr 0x01 0xCA 0x10 || return 1
    sleep 0.85
    raw=$(timeout 2 i2ctransfer -y $BUS w1@$addr 0x00 r2) || return 1
    read -r msb lsb <<< "$raw"
    validate_hex_byte "$msb" || return 1
    validate_hex_byte "$lsb" || return 1
    awk -v m="$((msb))" -v l="$((lsb))" '
    BEGIN {
        word = m * 256 + l
        e = int(word / 4096); ma = word % 4096
        printf "%.2f %d %d\n", 1.2 * (2^e) * ma, e, ma
    }'
}

read_opt3002() {
    local opt_addr result irr e m
    if result=$(read_opt3002_iio 2>/dev/null); then
        irr=$(echo "$result" | awk '{print $1}')
        printf "  Irradiance:  %s (IIO units)              ${C_DIM}[IIO]${C_RST}\n" "$irr"
        READ_LIGHT_NWCM2="$irr"; return 0
    fi
    opt_addr=$(detect_addr $OPT3002_PRIMARY)
    [[ "$opt_addr" == "MISSING" ]] && opt_addr=$(detect_addr $OPT3002_FALLBACK)
    if [[ "$opt_addr" == "MISSING" ]]; then
        echo "  ${C_ERR}NOT detected at 0x44/0x45${C_RST}"; return 1
    fi
    result=$(read_opt3002_raw "$opt_addr") || { echo "  ${C_ERR}read failed at $opt_addr${C_RST}"; return 1; }
    read -r irr e m <<< "$result"
    READ_LIGHT_NWCM2="$irr"
    printf "  Irradiance:  %s nW/cm²  (E=%s M=%s)   ${C_DIM}[raw I2C @ %s]${C_RST}\n" "$irr" "$e" "$m" "$opt_addr"
}

# ─── BMP280 ────────────────────────────────────────────────────────────
read_bmp280_iio() {
    local d p t
    d=$(find_iio_device "bm[ep]280") || return 1
    p=$(read_iio_channel "$d" in_pressure) || return 1
    t=$(read_iio_channel "$d" in_temp) || t=""
    awk -v p="$p" -v t="$t" '
    BEGIN {
        p_hpa = p * 10
        if (t != "") { t_c = (t > 200 || t < -50) ? t/1000.0 : t } else { t_c = -999 }
        alt = 44330.0 * (1.0 - (p_hpa/1013.25)^0.1903)
        if (t_c > -100) printf "%.2f %.2f %.1f\n", p_hpa, t_c, alt
        else printf "%.2f -- %.1f\n", p_hpa, alt
    }'
}

read_bmp280_raw() {
    local addr=$1 cal data cal_dec data_dec
    cal=$(timeout 2 i2ctransfer -y $BUS w1@$addr 0x88 r24) || return 1
    cal_dec=$(hex_to_dec "$cal") || return 1
    timeout 2 i2cset -y $BUS $addr 0xF4 0x25 || return 1
    sleep 0.02
    data=$(timeout 2 i2ctransfer -y $BUS w1@$addr 0xF7 r6) || return 1
    data_dec=$(hex_to_dec "$data") || return 1
    awk -v c="$cal_dec" -v d="$data_dec" '
    function s16(lo, hi,  v) { v = hi*256 + lo; if (v >= 32768) v -= 65536; return v }
    function u16(lo, hi)    { return hi*256 + lo }
    BEGIN {
        split(c, ca, " "); split(d, da, " ")
        dig_T1=u16(ca[1],ca[2]);  dig_T2=s16(ca[3],ca[4]);  dig_T3=s16(ca[5],ca[6])
        dig_P1=u16(ca[7],ca[8]);  dig_P2=s16(ca[9],ca[10])
        dig_P3=s16(ca[11],ca[12]); dig_P4=s16(ca[13],ca[14])
        dig_P5=s16(ca[15],ca[16]); dig_P6=s16(ca[17],ca[18])
        dig_P7=s16(ca[19],ca[20]); dig_P8=s16(ca[21],ca[22])
        dig_P9=s16(ca[23],ca[24])
        adc_P = da[1]*4096 + da[2]*16 + int(da[3]/16)
        adc_T = da[4]*4096 + da[5]*16 + int(da[6]/16)
        var1 = (adc_T/16384.0 - dig_T1/1024.0) * dig_T2
        var2 = ((adc_T/131072.0 - dig_T1/8192.0)^2) * dig_T3
        t_fine = var1 + var2; T = t_fine / 5120.0
        var1 = t_fine/2.0 - 64000.0
        var2 = var1*var1*dig_P6/32768.0; var2 += var1*dig_P5*2.0
        var2 = var2/4.0 + dig_P4*65536.0
        var1 = (dig_P3*var1*var1/524288.0 + dig_P2*var1)/524288.0
        var1 = (1.0 + var1/32768.0)*dig_P1
        if (var1 == 0) exit 1
        p = 1048576.0 - adc_P
        p = (p - var2/4096.0) * 6250.0 / var1
        var1 = dig_P9*p*p/2147483648.0
        var2 = p*dig_P8/32768.0
        p = p + (var1 + var2 + dig_P7)/16.0
        p_hpa = p/100.0
        alt = 44330.0 * (1.0 - (p_hpa/1013.25)^0.1903)
        printf "%.2f %.2f %.1f\n", p_hpa, T, alt
    }'
}

read_bmp280() {
    local result via bmp_addr p t a
    if result=$(read_bmp280_iio 2>/dev/null); then via="IIO"
    else
        bmp_addr=$(detect_addr $BMP280_PRIMARY)
        [[ "$bmp_addr" == "MISSING" ]] && bmp_addr=$(detect_addr $BMP280_FALLBACK)
        if [[ "$bmp_addr" == "MISSING" ]]; then echo "  ${C_ERR}NOT detected at 0x76/0x77${C_RST}"; return 1; fi
        result=$(read_bmp280_raw "$bmp_addr") || { echo "  ${C_ERR}read failed at $bmp_addr${C_RST}"; return 1; }
        via="raw I2C @ $bmp_addr"
    fi
    read -r p t a <<< "$result"
    READ_PRESS_HPA="$p"
    printf "  Pressure:    %s hPa                  ${C_DIM}[%s]${C_RST}\n" "$p" "$via"
    [[ "$t" != "--" ]] && printf "  Temperature: %s °C  (BMP280 die)       ${C_DIM}[%s]${C_RST}\n" "$t" "$via"
    printf "  Altitude:    %s m  (sea-level 1013.25)  ${C_DIM}[derived]${C_RST}\n" "$a"
}

# ─── ECC608 + TLA2021 (presence only) ──────────────────────────────────
read_ecc608() {
    local addr=$(detect_addr $ECC608_ADDR)
    if [[ "$addr" != "MISSING" ]]; then
        printf "  Status:      ${C_OK}present at 0x30${C_RST}  ${C_DIM}(Phase 2: real driver + wake sequence)${C_RST}\n"
    else
        printf "  Status:      ${C_WARN}not detected at 0x30${C_RST}  ${C_DIM}(wake-quirk applies)${C_RST}\n"
    fi
}

read_tla2021() {
    local addr=$(detect_addr $TLA2021_ADDR)
    if [[ "$addr" != "MISSING" ]]; then
        printf "  Status:      ${C_OK}present at 0x49${C_RST}  ${C_DIM}(analog Grove ADC)${C_RST}\n"
    else
        printf "  Status:      ${C_DIM}not detected (normal if no analog Grove wired)${C_RST}\n"
    fi
}

# ─── OLED (v3 redesign: white bg, black icons + text, 2x2 grid) ───────
display_oled() {
    [[ $WANT_OLED -eq 0 ]] && return 0
    if ! command -v python3 >/dev/null; then
        echo "  ${C_DIM}OLED skipped: python3 not present${C_RST}"; return 0
    fi
    if ! python3 -c "import luma.oled" 2>/dev/null; then
        echo "  ${C_DIM}OLED skipped: python3-luma.oled not installed${C_RST}"
        echo "  ${C_DIM}  Install: sudo apt install -y python3-luma.oled${C_RST}"
        return 0
    fi
    if [[ ! -c /dev/spidev0.0 ]]; then
        echo "  ${C_DIM}OLED skipped: SPI not enabled${C_RST}"; return 0
    fi

    export OLED_TEMP="${READ_TEMP_C:-}"
    export OLED_HUMID="${READ_HUMID_PCT:-}"
    export OLED_PRESS="${READ_PRESS_HPA:-}"
    export OLED_LIGHT="${READ_LIGHT_NWCM2:-}"

    python3 - <<'PYEOF'
import os, sys
try:
    from luma.core.interface.serial import spi
    from luma.oled.device import ssd1306
    from luma.core.render import canvas
    from luma.core.legacy import text as legacy_text
    from luma.core.legacy.font import proportional, CP437_FONT
except ImportError as e:
    sys.exit(f"luma not importable: {e}")

# ── Value formatting ──────────────────────────────────────────────────
def safe_float(env):
    v = os.environ.get(env, "").strip()
    try:    return float(v) if v else None
    except ValueError: return None

def fmt_temp(v):  return f"{v:.1f}C" if v is not None else "--"
def fmt_humid(v): return f"{v:.0f}%" if v is not None else "--"
def fmt_press(v): return f"{v:.0f}"  if v is not None else "--"   # hPa, no unit (label is the gauge icon)
def fmt_light(v):
    if v is None: return "--"
    if v < 1000:    return f"{v:.0f}"
    if v < 1e6:     return f"{v/1000:.0f}k"
    return f"{v/1e6:.0f}M"

# ── Icons drawn programmatically (1-bit pixel art, fits in ~12x14 px) ─
def icon_thermometer(d, x, y):
    # top cap (small circle)
    d.ellipse([x+3, y+0, x+5, y+2], fill="black")
    # tube (narrow rectangle)
    d.rectangle([x+3, y+2, x+5, y+8], fill="black")
    # bulb (larger circle at bottom)
    d.ellipse([x+1, y+7, x+7, y+13], fill="black")

def icon_droplet(d, x, y):
    # pointed top half (triangle)
    d.polygon([(x+4, y+0), (x+0, y+7), (x+8, y+7)], fill="black")
    # round bottom half (ellipse)
    d.ellipse([x+0, y+5, x+8, y+13], fill="black")

def icon_gauge(d, x, y):
    # circle outline (gauge face)
    d.ellipse([x+0, y+0, x+12, y+12], outline="black", width=1)
    # needle pointing up-right
    d.line([(x+6, y+6), (x+10, y+3)], fill="black", width=1)
    # center hub
    d.ellipse([x+5, y+5, x+7, y+7], fill="black")
    # tick marks at cardinals
    d.point((x+6,  y+1),  fill="black")
    d.point((x+11, y+6),  fill="black")
    d.point((x+1,  y+6),  fill="black")

def icon_sun(d, x, y):
    # center disc
    d.ellipse([x+3, y+3, x+8, y+8], fill="black")
    # cardinal rays
    d.line([(x+5, y+0),  (x+5, y+1)],  fill="black")
    d.line([(x+5, y+10), (x+5, y+11)], fill="black")
    d.line([(x+0, y+5),  (x+1, y+5)],  fill="black")
    d.line([(x+10, y+5), (x+11, y+5)], fill="black")
    # diagonal ray pixels
    d.point((x+1, y+1),  fill="black")
    d.point((x+9, y+1),  fill="black")
    d.point((x+1, y+9),  fill="black")
    d.point((x+9, y+9),  fill="black")

# ── Render ────────────────────────────────────────────────────────────
try:
    serial = spi(port=0, device=0, gpio_DC=24, gpio_RST=25, bus_speed_hz=8_000_000)
    device = ssd1306(serial, width=128, height=32, rotate=0)
    device.contrast(255)

    temp  = safe_float("OLED_TEMP")
    humid = safe_float("OLED_HUMID")
    press = safe_float("OLED_PRESS")
    light = safe_float("OLED_LIGHT")

    with canvas(device) as draw:
        # White background — invert: every pixel ON, then turn OFF for icons/text
        draw.rectangle(device.bounding_box, fill="white")

        # Subtle dividers (1 px black lines splitting the 4 cells)
        draw.line([(64, 1),  (64, 30)], fill="black")    # vertical
        draw.line([(2, 16),  (126, 16)], fill="black")   # horizontal

        # ── Top-left cell: thermometer + temperature ──
        icon_thermometer(draw, 2, 1)
        legacy_text(draw, (14, 3), fmt_temp(temp), fill="black", font=proportional(CP437_FONT))

        # ── Top-right cell: droplet + humidity ──
        icon_droplet(draw, 66, 1)
        legacy_text(draw, (78, 3), fmt_humid(humid), fill="black", font=proportional(CP437_FONT))

        # ── Bottom-left cell: gauge + pressure ──
        icon_gauge(draw, 2, 18)
        legacy_text(draw, (18, 20), fmt_press(press), fill="black", font=proportional(CP437_FONT))

        # ── Bottom-right cell: sun + light ──
        icon_sun(draw, 66, 19)
        legacy_text(draw, (80, 20), fmt_light(light), fill="black", font=proportional(CP437_FONT))

except Exception as e:
    sys.exit(f"display error: {e}")
PYEOF

    if [[ $? -eq 0 ]]; then
        echo "  ${C_OK}OLED updated${C_RST}  ${C_DIM}(2x2 grid: thermo+T | drop+H / gauge+P | sun+L)${C_RST}"
    else
        echo "  ${C_ERR}OLED display failed${C_RST}"
    fi
}

# ─── JSON output ───────────────────────────────────────────────────────
emit_json() {
    cat <<JSON
{
  "timestamp": "$(date -Iseconds)",
  "host": "$(hostname -s)",
  "sensors": {
    "hdc2010":  { "temp_c": ${READ_TEMP_C:-null},  "humid_pct": ${READ_HUMID_PCT:-null} },
    "opt3002":  { "light_nwcm2": ${READ_LIGHT_NWCM2:-null} },
    "bmp280":   { "press_hpa": ${READ_PRESS_HPA:-null} }
  }
}
JSON
}

# ─── Main ──────────────────────────────────────────────────────────────
preflight

if [[ $JSON_MODE -eq 1 ]]; then
    read_hdc2010 >/dev/null 2>&1 || true
    read_opt3002 >/dev/null 2>&1 || true
    read_bmp280  >/dev/null 2>&1 || true
    emit_json
    exit 0
fi

echo "${C_DIM}══════════════════════════════════════════${C_RST}"
echo "${C_HDR}Coral Env Sensor Board — readout (v3)${C_RST}"
echo "${C_DIM}$(date -Iseconds)  bus=$BUS  host=$(hostname -s)${C_RST}"
echo "${C_DIM}══════════════════════════════════════════${C_RST}"

echo
echo "${C_HDR}HDC2010${C_RST}  ${C_DIM}temperature + humidity${C_RST}"
read_hdc2010 || true

echo
echo "${C_HDR}OPT3002${C_RST}  ${C_DIM}ambient irradiance${C_RST}"
read_opt3002 || true

echo
echo "${C_HDR}BMP280${C_RST}  ${C_DIM}barometric pressure${C_RST}"
read_bmp280 || true

echo
echo "${C_HDR}ECC608${C_RST}  ${C_DIM}secure element @ 0x30${C_RST}"
read_ecc608

echo
echo "${C_HDR}TLA2021${C_RST}  ${C_DIM}analog ADC @ 0x49${C_RST}"
read_tla2021

echo
echo "${C_HDR}OLED${C_RST}  ${C_DIM}SSD1306 128×32 — 2x2 icon grid${C_RST}"
display_oled

echo
echo "${C_DIM}══════════════════════════════════════════${C_RST}"
