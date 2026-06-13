#!/usr/bin/env python3
"""
display-pattern-test.py — isolate the getbuffer() image path on the Waveshare
2.7" e-ink, after the solid-fill test has already proven the hardware/data path.

Why this exists: clear() writes its bytes directly and never calls getbuffer(),
so a passing fill test does NOT validate getbuffer (the image -> panel-bytes
conversion). The speckled image with clean fills points squarely at getbuffer.
This runs two simple high-contrast patterns to localize the fault:

  Test 1 — NATIVE 176x264 portrait, top half black:
           getbuffer takes its NO-ROTATE branch. Isolates bit/byte packing.
  Test 2 — LANDSCAPE 264x176, left half black:
           getbuffer rotates 90 deg. Isolates the rotation step.

Run it, watch the panel through each 4-second hold, then read the
interpretation printed at the end.

Usage:
    python3 display-pattern-test.py
Keeps the same convention as eink-smoke-test.py: loads only the bundled driver
beside it, no path overrides.
"""
from __future__ import annotations

import importlib.util
import os
import sys
import time

DEFAULT_DRIVER = "waveshare-driver-securev2.py"


def step(msg): print(f"[ .. ] {msg}", flush=True)
def die(msg, hint=""):
    print(f"[FAIL] {msg}", file=sys.stderr)
    if hint:
        print(f"       -> {hint}", file=sys.stderr)
    sys.exit(1)


# deps ───────────────────────────────────────────────────────────────
try:
    from PIL import Image, ImageDraw
except ImportError as exc:
    die(f"missing dependency: {exc}",
        "sudo apt install -y --no-install-recommends python3-pil")

# load the bundled driver (no path overrides, same policy as the smoke test) ──
if len(sys.argv) > 1:
    die("driver path overrides are disabled",
        "run without arguments so only the bundled driver is loaded")
drv = os.path.join(os.path.dirname(os.path.abspath(__file__)), DEFAULT_DRIVER)
if not os.path.isfile(drv):
    die(f"driver not found: {drv}",
        "keep waveshare-driver-securev2.py beside this script")
spec = importlib.util.spec_from_file_location("epd_driver", drv)
m = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(m)
except Exception as exc:
    die(f"driver failed to import: {exc}")

# exercise getbuffer ─────────────────────────────────────────────────
e = m.EPD2in7V2()
try:
    e.open()

    step("Test 1: NATIVE 176x264 (no rotate) -- expect TOP HALF black, bottom white")
    img1 = Image.new("1", (m.WIDTH, m.HEIGHT), 255)
    ImageDraw.Draw(img1).rectangle((0, 0, m.WIDTH, m.HEIGHT // 2), fill=0)
    e.refresh(e.getbuffer(img1), force=True)
    time.sleep(4)

    step("Test 2: LANDSCAPE 264x176 (rotate 90) -- expect a clean HALF black, half white")
    img2 = Image.new("1", (m.HEIGHT, m.WIDTH), 255)
    ImageDraw.Draw(img2).rectangle((0, 0, m.HEIGHT // 2, m.WIDTH), fill=0)
    e.refresh(e.getbuffer(img2), force=True)
    time.sleep(4)
except m.Spi0Busy:
    die("SPI0 bus busy", "stop the OLED sensor script, then re-run alone")
except m.EpdError as exc:
    die(f"hardware fault: {exc}",
        "check wiring: BUSY->GP22, RST->GP17, DC->GP23, CS->CE1, BS jumper at 0")
finally:
    try:
        e.close()
    except Exception:
        pass

print()
print("Interpretation:")
print("  Test1 clean, Test2 speckle -> getbuffer rotate(90) is the bug")
print("  Test1 speckle              -> getbuffer bit/byte packing is the bug")
print("  Both clean                 -> getbuffer ok; issue is the text rendering")
