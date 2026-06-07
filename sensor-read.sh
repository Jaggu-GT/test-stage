#!/usr/bin/env bash
# sensor-read.sh — Coral Environmental Sensor Board readout (Phase 1)
#
# Reads all sensors on the Coral Env Board via I2C and prints values.
# Pure bash + i2c-tools + awk. No Python, no Google apt repo.
#
# Sensors:
#   HDC2010   @ 0x40   temperature + humidity
#   OPT3002   @ 0x44   ambient irradiance
#   BMP280    @ 0x76   barometric pressure + temperature
#   ATECC608A @ 0x60   secure element (presence only, Phase 2 = real use)
#
# Usage:
#   chmod +x sensor-read.sh
#   ./sensor-read.sh
#
# Requires:
#   - i2c-tools  (sudo apt install i2c-tools)
#   - dtparam=i2c_arm=on in /boot/firmware/config.txt
#   - user in 'i2c' group OR run with sudo

set -euo pipefail
export LC_ALL=C

BUS=1

# ANSI colors
C_OK=$'\033[1;32m'
C_WARN=$'\033[1;33m'
C_ERR=$'\033[1;31m'
C_DIM=$'\033[0;90m'
C_HDR=$'\033[1;36m'
C_RST=$'\033[0m'

HDC2010_ADDR=0x40
OPT3002_PRIMARY=0x44
OPT3002_FALLBACK=0x45
BMP280_PRIMARY=0x76
BMP280_FALLBACK=0x77
ATECC608_ADDR=0x60

# ─── Preflight ─────────────────────────────────────────────────────────
preflight() {
    command -v i2cdetect   >/dev/null || { echo "${C_ERR}i2c-tools missing — sudo apt install i2c-tools${C_RST}"; exit 1; }
    command -v i2ctransfer >/dev/null || { echo "${C_ERR}i2ctransfer missing — update i2c-tools${C_RST}"; exit 1; }
    command -v i2cset      >/dev/null || { echo "${C_ERR}i2cset missing${C_RST}"; exit 1; }

    [[ -c /dev/i2c-$BUS ]] || { echo "${C_ERR}/dev/i2c-$BUS missing — enable I2C with sudo raspi-config nonint do_i2c 0${C_RST}"; exit 1; }

    if [[ ! -r /dev/i2c-$BUS || ! -w /dev/i2c-$BUS ]] && [[ $EUID -ne 0 ]]; then
        echo "${C_ERR}/dev/i2c-$BUS not user-accessible. Either run with sudo or join 'i2c' group:${C_RST}"
        echo "  sudo usermod -aG i2c \$USER  &&  newgrp i2c"
        exit 1
    fi
}

# ─── Address detection ─────────────────────────────────────────────────
# Tries a register read at the address. If it ACKs, returns the address.
detect_addr() {
    local primary=$1 fallback=$2
    if i2cget -y $BUS $primary 0x00 >/dev/null 2>&1; then
        echo $primary
    elif i2cget -y $BUS $fallback 0x00 >/dev/null 2>&1; then
        echo $fallback
    else
        echo "MISSING"
    fi
}

# Convert "0xab 0xcd ..." → decimal bash array via stdin
hex_to_dec() {
    local out=()
    for b in $1; do out+=($((b))); done
    echo "${out[@]}"
}

# ─── HDC2010: temperature + humidity ───────────────────────────────────
read_hdc2010() {
    local addr=$HDC2010_ADDR

    # Trigger a single measurement: write 0x01 to Measurement Configuration (0x0F)
    i2cset -y $BUS $addr 0x0F 0x01 \
        || { echo "  ${C_ERR}HDC2010 trigger failed${C_RST}"; return 1; }
    sleep 0.05    # 14-bit conversion ~660 µs; 50 ms = comfortable

    # Read 4 bytes from 0x00: T_LSB, T_MSB, RH_LSB, RH_MSB
    local raw t_lsb t_msb rh_lsb rh_msb
    raw=$(i2ctransfer -y $BUS w1@$addr 0x00 r4)
    read -r t_lsb t_msb rh_lsb rh_msb <<< "$raw"
    t_lsb=$((t_lsb)); t_msb=$((t_msb)); rh_lsb=$((rh_lsb)); rh_msb=$((rh_msb))

    awk -v t_lsb="$t_lsb" -v t_msb="$t_msb" -v rh_lsb="$rh_lsb" -v rh_msb="$rh_msb" '
    BEGIN {
        t_raw  = t_msb  * 256 + t_lsb
        rh_raw = rh_msb * 256 + rh_lsb
        temp_c = (t_raw  / 65536.0) * 165.0 - 40.0
        rh_pct = (rh_raw / 65536.0) * 100.0
        printf "  Temperature: %.2f °C  (%.2f °F)\n", temp_c, temp_c * 9/5 + 32
        printf "  Humidity:    %.2f %% RH\n", rh_pct
    }'
}

# ─── OPT3002: ambient irradiance ──────────────────────────────────────
read_opt3002() {
    local addr=$1
    # Configure register 0x01 to 0xCA10:
    #   RN[15:12]=1100 auto-range, CT[11]=1 (800 ms), M[10:9]=01 (single-shot),
    #   L[4]=1 (latched). Datasheet section 7.6.
    i2ctransfer -y $BUS w3@$addr 0x01 0xCA 0x10 \
        || { echo "  ${C_ERR}OPT3002 config failed${C_RST}"; return 1; }
    sleep 0.85    # one 800 ms integration period + margin

    local raw msb lsb
    raw=$(i2ctransfer -y $BUS w1@$addr 0x00 r2)
    read -r msb lsb <<< "$raw"
    msb=$((msb)); lsb=$((lsb))

    awk -v msb="$msb" -v lsb="$lsb" '
    BEGIN {
        word     = msb * 256 + lsb
        exponent = int(word / 4096)              # top 4 bits
        mantissa = word % 4096                   # bottom 12 bits
        # Datasheet eq 1: irradiance (nW/cm²) = 1.2 × 2^E × M
        irr = 1.2 * (2 ^ exponent) * mantissa
        printf "  Irradiance:  %.2f nW/cm²  (E=%d M=%d)\n", irr, exponent, mantissa
    }'
}

# ─── BMP280: barometric pressure + temperature ────────────────────────
read_bmp280() {
    local addr=$1

    # Read 24-byte calibration block at 0x88 (12 × 16-bit, LSB first)
    local cal
    cal=$(i2ctransfer -y $BUS w1@$addr 0x88 r24)
    local cal_dec
    cal_dec=$(hex_to_dec "$cal")

    # Trigger forced-mode measurement: ctrl_meas (0xF4) = osrs_t=1, osrs_p=1, mode=forced
    # 0b001_001_01 = 0x25. Forced mode auto-returns to sleep after one conversion.
    i2cset -y $BUS $addr 0xF4 0x25
    sleep 0.02    # ~7 ms typical conversion at 1× oversampling

    # Read 6 bytes from 0xF7: P_MSB, P_LSB, P_XLSB, T_MSB, T_LSB, T_XLSB
    local data
    data=$(i2ctransfer -y $BUS w1@$addr 0xF7 r6)
    local data_dec
    data_dec=$(hex_to_dec "$data")

    awk -v c="$cal_dec" -v d="$data_dec" '
    function s16(lo, hi,    v) { v = hi*256 + lo; if (v >= 32768) v -= 65536; return v }
    function u16(lo, hi)       { return hi*256 + lo }
    BEGIN {
        split(c, ca, " "); split(d, da, " ")

        # Calibration constants (datasheet section 3.11)
        dig_T1 = u16(ca[1],  ca[2])
        dig_T2 = s16(ca[3],  ca[4])
        dig_T3 = s16(ca[5],  ca[6])
        dig_P1 = u16(ca[7],  ca[8])
        dig_P2 = s16(ca[9],  ca[10])
        dig_P3 = s16(ca[11], ca[12])
        dig_P4 = s16(ca[13], ca[14])
        dig_P5 = s16(ca[15], ca[16])
        dig_P6 = s16(ca[17], ca[18])
        dig_P7 = s16(ca[19], ca[20])
        dig_P8 = s16(ca[21], ca[22])
        dig_P9 = s16(ca[23], ca[24])

        # 20-bit ADC values (MSB-aligned across 3 bytes, XLSB top nibble)
        adc_P = da[1]*4096 + da[2]*16 + int(da[3]/16)
        adc_T = da[4]*4096 + da[5]*16 + int(da[6]/16)

        # Temperature compensation (floating point, datasheet section 8.2)
        var1 = (adc_T/16384.0 - dig_T1/1024.0) * dig_T2
        var2 = ((adc_T/131072.0 - dig_T1/8192.0) ^ 2) * dig_T3
        t_fine = var1 + var2
        T = t_fine / 5120.0

        # Pressure compensation
        var1 = t_fine/2.0 - 64000.0
        var2 = var1 * var1 * dig_P6 / 32768.0
        var2 = var2 + var1 * dig_P5 * 2.0
        var2 = var2/4.0 + dig_P4 * 65536.0
        var1 = (dig_P3 * var1 * var1 / 524288.0 + dig_P2 * var1) / 524288.0
        var1 = (1.0 + var1/32768.0) * dig_P1
        if (var1 == 0) { print "  Pressure:    error (calibration div-by-zero)"; exit 1 }
        p = 1048576.0 - adc_P
        p = (p - var2/4096.0) * 6250.0 / var1
        var1 = dig_P9 * p * p / 2147483648.0
        var2 = p * dig_P8 / 32768.0
        p = p + (var1 + var2 + dig_P7) / 16.0

        # International Standard Atmosphere altitude estimate (sea level = 1013.25 hPa)
        p_hpa = p / 100.0
        alt_m = 44330.0 * (1.0 - (p_hpa / 1013.25) ^ 0.1903)

        printf "  Temperature: %.2f °C  (BMP280 die)\n", T
        printf "  Pressure:    %.2f hPa  (%.2f inHg)\n", p_hpa, p / 3386.39
        printf "  Altitude:    %.1f m   (assumes 1013.25 hPa sea-level)\n", alt_m
    }'
}

# ─── ATECC608A: secure element (presence only, Phase 1) ───────────────
read_atecc608() {
    # The ATECC608A needs a wake sequence (drive SDA low ≥60 µs) before any
    # real command, and the protocol is non-trivial. For Phase 1 we just
    # confirm it ACKs on the bus. Cryptographic use comes in Phase 2 with
    # a proper driver and signed-telemetry pipeline.
    if i2cdetect -y $BUS 2>/dev/null | grep -q " 60 "; then
        printf "  Status:      ${C_OK}present${C_RST} at 0x60 (Phase 2 work)\n"
        printf "  ${C_DIM}Note: Coral boards ship with Google-provisioned keys; config zone${C_RST}\n"
        printf "  ${C_DIM}      lock state must be verified before planning own key slots.${C_RST}\n"
    else
        printf "  Status:      ${C_ERR}NOT detected at 0x60${C_RST}\n"
    fi
}

# ─── Main ──────────────────────────────────────────────────────────────
preflight

echo "${C_DIM}══════════════════════════════════════════${C_RST}"
echo "${C_HDR}Coral Env Sensor Board — readout${C_RST}"
echo "${C_DIM}$(date -Iseconds)  bus=$BUS  host=$(hostname)${C_RST}"
echo "${C_DIM}══════════════════════════════════════════${C_RST}"

echo
echo "${C_HDR}HDC2010${C_RST}  ${C_DIM}temperature + humidity${C_RST}"
if i2cget -y $BUS $HDC2010_ADDR 0x00 >/dev/null 2>&1; then
    read_hdc2010 || echo "  ${C_ERR}read failed${C_RST}"
else
    echo "  ${C_ERR}NOT detected at 0x40${C_RST}"
fi

echo
echo "${C_HDR}OPT3002${C_RST}  ${C_DIM}ambient irradiance${C_RST}"
opt_addr=$(detect_addr $OPT3002_PRIMARY $OPT3002_FALLBACK)
if [[ $opt_addr == "MISSING" ]]; then
    echo "  ${C_ERR}NOT detected at 0x44/0x45${C_RST}"
else
    read_opt3002 $opt_addr || echo "  ${C_ERR}read failed${C_RST}"
fi

echo
echo "${C_HDR}BMP280${C_RST}  ${C_DIM}barometric pressure${C_RST}"
bmp_addr=$(detect_addr $BMP280_PRIMARY $BMP280_FALLBACK)
if [[ $bmp_addr == "MISSING" ]]; then
    echo "  ${C_ERR}NOT detected at 0x76/0x77${C_RST}"
else
    read_bmp280 $bmp_addr || echo "  ${C_ERR}read failed${C_RST}"
fi

echo
echo "${C_HDR}ATECC608A${C_RST}  ${C_DIM}secure element${C_RST}"
read_atecc608

echo
echo "${C_DIM}══════════════════════════════════════════${C_RST}"
