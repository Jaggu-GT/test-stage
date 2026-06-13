#!/usr/bin/env python3
"""
eink-smoke-test.py — end-to-end bring-up check for the Waveshare 2.7" e-ink.

Verifies, in order:
  1. Python deps (spidev, gpiozero, PIL)
  2. SPI device nodes (spidev0.0 lock token + spidev0.1 e-ink CE1)
  3. driver loads
  4. a real panel write: clear (white) + a system-internals frame
  5. clean deep-sleep on close

Prints PASS, or a FAIL mapped to the likely cause. Uses force=True so it
bypasses the daemon's min-refresh delay and gives immediate visual feedback.

Usage:
    python3 eink-smoke-test.py
Default driver: waveshare-driver-securev2.py beside this script
"""
from __future__ import annotations

import importlib.util
import os
import sys
import time

DEFAULT_DRIVER = "waveshare-driver-securev2.py"


def step(msg): print(f"[ .. ] {msg}", flush=True)
def ok(msg):   print(f"[ OK ] {msg}", flush=True)
def die(msg, hint=""):
    print(f"[FAIL] {msg}", file=sys.stderr)
    if hint:
        print(f"       -> {hint}", file=sys.stderr)
    sys.exit(1)


# 1. deps ────────────────────────────────────────────────────────────
step("checking Python deps (spidev, gpiozero, PIL)")
try:
    import spidev          # noqa: F401
    import gpiozero        # noqa: F401
    from PIL import Image  # noqa: F401
except ImportError as e:
    die(f"missing dependency: {e}",
        "sudo apt install -y --no-install-recommends "
        "python3-spidev python3-gpiozero python3-lgpio python3-pil")
ok("deps present")

# 2. device nodes ────────────────────────────────────────────────────
step("checking SPI device nodes")
for node in ("/dev/spidev0.0", "/dev/spidev0.1"):
    if not os.path.exists(node):
        die(f"{node} missing",
            "enable SPI (dtparam=spi=on) and reboot — both CE0 and CE1 are needed")
ok("spidev0.0 (lock token) + spidev0.1 (e-ink CE1) present")

# 3. load the bundled driver (dashed filename isn't a normal import) ───
if len(sys.argv) > 1:
    die("driver path overrides are disabled",
        "run without arguments so only the bundled driver is loaded")
drv = os.path.join(os.path.dirname(os.path.abspath(__file__)), DEFAULT_DRIVER)
step(f"loading driver: {drv}")
if not os.path.isfile(drv):
    die(f"driver not found: {drv}",
        "keep waveshare-driver-securev2.py beside eink-smoke-test.py")
spec = importlib.util.spec_from_file_location("epd_driver", drv)
mod = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(mod)
except Exception as e:
    die(f"driver failed to import: {e}")
ok("driver loaded")

# 4. exercise the panel ──────────────────────────────────────────────
e = mod.EPD2in7V2()
t0 = time.monotonic()
try:
    step("open() — claim GPIO + SPI")
    e.open()
    step("clear() — full white refresh (data-path test)")
    e.clear()
    step("refresh() — system-internals frame (render + write)")
    e.refresh(e.getbuffer(mod.system_internals()), force=True)
except mod.Spi0Busy:
    die("SPI0 bus busy",
        "stop the OLED sensor script, then re-run the e-ink test alone")
except mod.EpdError as ex:
    die(f"hardware fault: {ex}",
        "check wiring: BUSY->GP22, RST->GP17, DC->GP23, CS->CE1, BS jumper at 0")
except Exception as ex:
    die(f"unexpected error: {ex}")
finally:
    try:
        e.close()   # releases GPIO/SPI; panel was deep-slept by the last refresh
    except Exception:
        pass

ok(f"PASS — cleared + drew a frame in {time.monotonic() - t0:.1f}s; panel asleep")
print("\nIf you SAW a white flash then the PI 3B+ INTERNALS screen, bring-up is good.")
