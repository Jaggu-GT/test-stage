#!/usr/bin/env python3
"""
epd2in7v2.py — from-scratch driver + long-running display daemon for the
Waveshare 2.7" e-Paper HAT (V2). 264 x 176, B/W, SSD1680-family controller.

Written from the public register contract in the Waveshare 2.7" V2 manual —
NOT vendored from waveshare/e-Paper. Trusted surface = this file + spidev +
gpiozero (+ PIL for rendering).

Hardware (BCM) — deconflicted to coexist with the Coral SSD1306 OLED:
    DIN  -> MOSI  (BCM10, phys 19)   shared      RST  -> BCM17 (phys 11)
    CLK  -> SCLK  (BCM11, phys 23)   shared      DC   -> BCM23 (phys 16)
    CS   -> CE1   (BCM7,  phys 26)               BUSY -> BCM22 (phys 15) [active HIGH]
    VCC  -> 3V3                                  GND  -> GND
SPI: mode 0 (CPOL=0, CPHA=0). DC low = command, DC high = data.

CO-RESIDENCE WITH THE OLED (both persistent):
  * Separate chip-selects: OLED on CE0 (/dev/spidev0.0), e-ink on CE1
    (/dev/spidev0.1). Two SPI devices must NOT share one CS. Each chip ignores
    the other's traffic because its own CS stays deasserted.
  * Shared advisory bus lock: SPI0 SCLK/MOSI are common, and spidev does NOT
    enforce exclusivity, so concurrent transfers corrupt both. Spi0BusLock takes
    an flock(2) on the BUS TOKEN /dev/spidev0.0 — the SAME path + same syscall
    the OLED script's fcntl.flock uses, so they mutually exclude. Note the e-ink
    *transfers* on CE1 but *locks* the CE0 node as the agreed token.
  * Lock is held ONLY while clocking bytes. The ~6s autonomous waveform after
    0x20 needs no bus, so the lock is RELEASED during that wait — the OLED can
    refresh in that window. Deep-sleep is then sent under a patient re-acquire so
    a busy bus can never leave the panel powered (a manual damage hazard).
  * flock auto-releases on process death: a crashed display never blocks the
    other one.

Deps (apt, not pip):
    sudo apt install python3-spidev python3-gpiozero python3-pil
"""

from __future__ import annotations

import errno
import fcntl
import os
import signal
import time
from typing import Callable, Final, Optional

import spidev
from gpiozero import DigitalInputDevice, DigitalOutputDevice

# ── Panel geometry ────────────────────────────────────────────────────────
WIDTH: Final[int] = 176                          # source lines
HEIGHT: Final[int] = 264                          # gate lines
_BUF_BYTES: Final[int] = (WIDTH // 8) * HEIGHT     # 22 * 264 = 5808

# ── Pins (BCM) — deconflicted from the OLED (OLED uses DC=24, RST=25, CE0) ──
_RST_PIN: Final[int] = 17
_DC_PIN: Final[int] = 23                           # was 25 (OLED RST) -> moved
_BUSY_PIN: Final[int] = 22                         # was 24 (OLED DC)  -> moved
_SPI_BUS: Final[int] = 0
_SPI_DEV: Final[int] = 1                           # CE1 -> /dev/spidev0.1 (transfer node)
_SPI_NODE: Final[str] = "/dev/spidev0.0"           # CE0 -> BUS LOCK TOKEN (shared with OLED)
_SPI_HZ: Final[int] = 4_000_000

# ── Timing / safety bounds ────────────────────────────────────────────────
_BUSY_POLL_S: Final[float] = 0.02
_BUSY_TIMEOUT_S: Final[float] = 30.0               # post-0x20 waveform wait (OUTSIDE lock)
_INIT_BUSY_TIMEOUT_S: Final[float] = 5.0           # init-phase waits (UNDER lock; bound dead-panel hold)
_SLEEP_LOCK_WAIT_S: Final[float] = 30.0            # patient wait to send deep-sleep
_MIN_REFRESH_S: Final[int] = 180                   # manual: >=180s between refreshes
_FORCE_FULL_S: Final[int] = 24 * 3600              # manual: full refresh at least daily


class EpdError(RuntimeError):
    """Hardware-level fault (e.g. BUSY never clears)."""


class Spi0Busy(EpdError):
    """SPI0 bus held by another cooperating process and could not be acquired."""


# ── Advisory bus lock (the OLED script flock()s the same token) ─────────────
class Spi0BusLock:
    """
    flock-based advisory lock on the CE0 device node (the agreed bus token).
    Squat-proof (root-owned node). fcntl.flock == flock(2), so it interoperates
    with the OLED shell script's `flock` on the same path.

    policy="reject": non-blocking; raise Spi0Busy immediately if held.
    policy="wait":   retry up to `timeout` seconds, then raise Spi0Busy.
    """

    def __init__(self, policy: str = "reject", timeout: float = 5.0) -> None:
        if policy not in ("reject", "wait"):
            raise ValueError("policy must be 'reject' or 'wait'")
        self._policy = policy
        self._timeout = timeout
        self._fd: Optional[int] = None

    def __enter__(self) -> "Spi0BusLock":
        if not os.path.exists(_SPI_NODE):
            raise EpdError(
                f"{_SPI_NODE} missing — SPI0 disabled or claimed by a kernel driver"
            )
        self._fd = os.open(_SPI_NODE, os.O_RDWR)    # node must exist; never O_CREAT
        deadline = time.monotonic() + self._timeout
        while True:
            try:
                fcntl.flock(self._fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return self
            except OSError as e:
                if e.errno not in (errno.EWOULDBLOCK, errno.EACCES):
                    self._close_fd()
                    raise
                if self._policy == "reject" or time.monotonic() > deadline:
                    self._close_fd()
                    raise Spi0Busy("SPI0 in use by another process") from None
                time.sleep(0.05)

    def __exit__(self, *exc) -> None:
        if self._fd is not None:
            try:
                fcntl.flock(self._fd, fcntl.LOCK_UN)
            finally:
                self._close_fd()

    def _close_fd(self) -> None:
        if self._fd is not None:
            os.close(self._fd)
            self._fd = None


class EPD2in7V2:
    """
    Resource-holding driver. Claims GPIO + opens spidev on open()/__enter__ but
    puts NO traffic on the bus until refresh(). A refresh holds the bus lock only
    while clocking bytes, releases during the autonomous waveform wait, then
    re-acquires patiently to deep-sleep the panel.
    """

    def __init__(self, *, lock_policy: str = "wait", lock_timeout: float = 5.0) -> None:
        self._lock_policy = lock_policy
        self._lock_timeout = lock_timeout
        self._spi: Optional[spidev.SpiDev] = None
        self._rst: Optional[DigitalOutputDevice] = None
        self._dc: Optional[DigitalOutputDevice] = None
        self._busy: Optional[DigitalInputDevice] = None
        self._last_buf: Optional[bytes] = None
        self._last_full: float = 0.0
        self._open = False

    # ── resource lifecycle (no bus traffic here) ──────────────────────────
    def open(self) -> None:
        if self._open:
            return
        self._rst = DigitalOutputDevice(_RST_PIN, initial_value=True)
        self._dc = DigitalOutputDevice(_DC_PIN, initial_value=False)
        self._busy = DigitalInputDevice(_BUSY_PIN)
        self._spi = spidev.SpiDev()
        self._spi.open(_SPI_BUS, _SPI_DEV)          # CE1
        self._spi.max_speed_hz = _SPI_HZ
        self._spi.mode = 0b00
        self._open = True

    def close(self) -> None:
        for obj in (self._spi, self._rst, self._dc, self._busy):
            try:
                if obj is not None:
                    obj.close()
            except Exception:
                pass
        self._spi = self._rst = self._dc = self._busy = None
        self._open = False

    def __enter__(self) -> "EPD2in7V2":
        self.open()
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    # ── low-level I/O (caller holds the bus lock) ─────────────────────────
    def _command(self, cmd: int) -> None:
        self._dc.off()
        self._spi.writebytes([cmd & 0xFF])

    def _data(self, *vals: int) -> None:
        self._dc.on()
        self._spi.writebytes([v & 0xFF for v in vals])

    def _data_bulk(self, payload: bytes) -> None:
        self._dc.on()
        self._spi.writebytes2(payload)

    def _wait_busy(self, timeout: float = _BUSY_TIMEOUT_S) -> None:
        deadline = time.monotonic() + timeout
        while self._busy.value == 1:               # V2: HIGH = busy
            if time.monotonic() > deadline:
                raise EpdError("BUSY never cleared — check wiring/SPI/reset")
            time.sleep(_BUSY_POLL_S)

    def _reset(self) -> None:
        # Waveshare timing: 200ms pulses. Short pulses leave the controller
        # only partly initialized — fills work but detailed waveforms corrupt.
        self._rst.on();  time.sleep(0.200)
        self._rst.off(); time.sleep(0.002)
        self._rst.on();  time.sleep(0.200)

    def _power_on_init(self) -> None:
        # Matches Waveshare epd2in7_V2 init() exactly. The earlier version sent
        # V1-panel commands (0x74/0x7E/0x01/0x3C/0x18/0x21) that left the V2
        # controller in a state where solid fills worked but fine detail
        # corrupted. SWRESET restores correct defaults; we set only RAM-Y and
        # data-entry, exactly as the reference does.
        self._reset()
        self._wait_busy(_INIT_BUSY_TIMEOUT_S)
        self._command(0x12)                          # SWRESET
        self._wait_busy(_INIT_BUSY_TIMEOUT_S)
        self._command(0x45)                          # RAM-Y start/end -> 0..263
        self._data(0x00, 0x00, 0x07, 0x01)
        self._command(0x4F)                          # RAM-Y counter -> 0
        self._data(0x00, 0x00)
        self._command(0x11)                          # data entry: X+ Y+
        self._data(0x03)

    def _send_update(self) -> None:
        # Kick the waveform; do NOT wait here (wait happens with the bus freed).
        self._command(0x22); self._data(0xF7)      # full update sequence
        self._command(0x20)

    def _sleep_panel(self) -> None:
        self._command(0x10); self._data(0x01)      # deep sleep
        time.sleep(0.1)

    @staticmethod
    def _check_buffer(buf: bytes) -> None:
        if len(buf) != _BUF_BYTES:
            raise ValueError(f"buffer must be {_BUF_BYTES} bytes, got {len(buf)}")

    # ── the one public draw path ──────────────────────────────────────────
    def refresh(self, buf: bytes, *, force: bool = False) -> bool:
        """
        Full refresh. Holds the SPI0 lock ONLY while clocking bytes, releases
        during the autonomous waveform wait so a co-resident OLED can use the
        bus, then re-acquires patiently to deep-sleep the panel. Skips redundant
        writes unless `force` or 24h elapsed. Returns True if the panel was
        actually written. Raises Spi0Busy if the bus could not be acquired for
        the (byte-clocking) phase per lock_policy.
        """
        if not self._open:
            raise EpdError("call open() first")
        buf = bytes(buf)
        self._check_buffer(buf)

        now = time.monotonic()
        stale = (now - self._last_full) >= _FORCE_FULL_S
        if not force and not stale and buf == self._last_buf:
            return False

        if not force and self._last_full and (now - self._last_full) < _MIN_REFRESH_S:
            print(
                f"WARN: skipping e-ink refresh; minimum interval is "
                f"{_MIN_REFRESH_S}s"
            )
            return False

        wait_error: Optional[EpdError] = None
        with Spi0BusLock(self._lock_policy, self._lock_timeout):
            self._power_on_init()
            self._command(0x24)
            self._data_bulk(buf)
            self._send_update()
        try:
            self._wait_busy(_BUSY_TIMEOUT_S)
        except EpdError as e:
            wait_error = e
        finally:
            try:
                with Spi0BusLock("wait", _SLEEP_LOCK_WAIT_S):
                    self._sleep_panel()
            except Spi0Busy:
                print("WARN: could not acquire bus to deep-sleep e-ink panel")
        if wait_error is not None:
            raise wait_error

        self._last_buf = buf
        self._last_full = now
        return True

    def clear(self, white: bool = True) -> None:
        self.refresh(bytes([0xFF if white else 0x00]) * _BUF_BYTES, force=True)

    # ── PIL helper ────────────────────────────────────────────────────────
    @staticmethod
    def getbuffer(image) -> bytes:
        """Convert a PIL 1-bit image to a panel buffer.

        Ported verbatim from Waveshare epd2in7_V2.getbuffer(): manual pixel
        remap, NOT PIL rotate(90). PIL's rotation produced a different byte/bit
        layout that only corrupted non-uniform content (text), which is why
        solid blocks looked fine but text came out as speckle.
        1 = white, 0 = black; MSB = leftmost pixel.
        """
        buf = [0xFF] * ((WIDTH // 8) * HEIGHT)
        img = image.convert("1")
        w, h = img.size
        px = img.load()
        if (w, h) == (WIDTH, HEIGHT):                 # portrait, native
            for y in range(h):
                for x in range(w):
                    if px[x, y] == 0:
                        buf[(x + y * WIDTH) // 8] &= ~(0x80 >> (x % 8))
        elif (w, h) == (HEIGHT, WIDTH):               # landscape, rotate 90
            for y in range(h):
                for x in range(w):
                    if px[x, y] == 0:
                        newx = y
                        newy = HEIGHT - x - 1
                        buf[(newx + newy * WIDTH) // 8] &= ~(0x80 >> (y % 8))
        else:
            raise ValueError(f"image must be {WIDTH}x{HEIGHT} or {HEIGHT}x{WIDTH}")
        return bytes(buf)


# ── Render helpers (proc/sysfs only — no extra deps, fits the sensor path) ──
def _read(path: str) -> str:
    with open(path, "r") as f:
        return f.read().strip()


def system_internals():
    """Return a landscape PIL image (HEIGHT x WIDTH) of Pi 3B+ system internals."""
    from PIL import Image, ImageDraw

    lines = []
    try:
        up = float(_read("/proc/uptime").split()[0])
        h, m = divmod(int(up) // 60, 60)
        lines.append(f"uptime  {h}h{m:02d}m")
    except Exception:
        lines.append("uptime  n/a")
    try:
        la = _read("/proc/loadavg").split()[:3]
        lines.append(f"load    {' '.join(la)}")
    except Exception:
        lines.append("load    n/a")
    try:
        mi = {k.rstrip(':'): int(v) for k, v, *_ in
              (ln.split() for ln in _read("/proc/meminfo").splitlines())}
        used = (mi["MemTotal"] - mi["MemAvailable"]) // 1024
        tot = mi["MemTotal"] // 1024
        lines.append(f"mem     {used}/{tot} MB")
    except Exception:
        lines.append("mem     n/a")
    try:
        t = int(_read("/sys/class/thermal/thermal_zone0/temp")) / 1000.0
        lines.append(f"soc     {t:.1f} C")
    except Exception:
        lines.append("soc     n/a")
    lines.append(time.strftime("%Y-%m-%d %H:%M"))

    img = Image.new("1", (HEIGHT, WIDTH), 255)
    d = ImageDraw.Draw(img)
    d.rectangle((2, 2, HEIGHT - 3, WIDTH - 3), outline=0)
    d.text((10, 8), "PI 3B+ INTERNALS", fill=0)
    for i, ln in enumerate(lines):
        d.text((10, 34 + i * 22), ln, fill=0)
    return img


def sensor_screen(values: dict):
    """Return a landscape PIL image rendering a dict of sensor key->value."""
    from PIL import Image, ImageDraw

    img = Image.new("1", (HEIGHT, WIDTH), 255)
    d = ImageDraw.Draw(img)
    d.rectangle((2, 2, HEIGHT - 3, WIDTH - 3), outline=0)
    d.text((10, 8), "SENSOR NODE", fill=0)
    for i, (k, v) in enumerate(list(values.items())[:5]):
        d.text((10, 34 + i * 22), f"{k:<8}{v}", fill=0)
    d.text((10, WIDTH - 18), time.strftime("%H:%M:%S"), fill=0)
    return img


def default_provider() -> "object":
    """
    Show fresh sensor data if SENSOR_FILE exists and is recent, else system
    internals. SENSOR_FILE is simple `key=value` lines (write it from your
    sensor-read script). Override by passing your own provider to EpdDaemon.
    """
    path = os.environ.get("SENSOR_FILE", "")
    if path and os.path.exists(path):
        try:
            age = time.time() - os.stat(path).st_mtime
            if age < 2 * _MIN_REFRESH_S:
                vals = {}
                for ln in _read(path).splitlines():
                    if "=" in ln:
                        k, _, v = ln.partition("=")
                        vals[k.strip()] = v.strip()
                if vals:
                    return sensor_screen(vals)
        except Exception:
            pass
    return system_internals()


class EpdDaemon:
    """
    Long-running display loop. Each cycle: render via provider -> refresh (lock
    held only while clocking bytes) -> wait `interval`. If the bus is busy for
    the clocking phase, the cycle is skipped. SIGINT/SIGTERM -> clean shutdown.
    """

    def __init__(
        self,
        provider: Callable[[], object] = default_provider,
        interval: int = 300,
    ) -> None:
        if interval < _MIN_REFRESH_S:
            print(f"WARN: interval {interval}s < {_MIN_REFRESH_S}s manual minimum")
        self._provider = provider
        self._interval = interval
        self._stop = False

    def _signal(self, *_a) -> None:
        self._stop = True

    def run(self) -> None:
        signal.signal(signal.SIGINT, self._signal)
        signal.signal(signal.SIGTERM, self._signal)
        with EPD2in7V2(lock_policy="wait", lock_timeout=10.0) as epd:
            try:
                epd.clear()
            except Spi0Busy:
                print("WARN: SPI0 busy, skipping startup clear")
            except EpdError as e:
                print(f"ERROR: {e}")
            while not self._stop:
                try:
                    img = self._provider()
                    if img is not None:
                        epd.refresh(epd.getbuffer(img))
                except Spi0Busy:
                    print("WARN: SPI0 busy, skipping cycle")
                except EpdError as e:
                    print(f"ERROR: {e}")
                for _ in range(self._interval * 10):   # interruptible sleep
                    if self._stop:
                        break
                    time.sleep(0.1)
        print("daemon stopped; panel asleep")


if __name__ == "__main__":
    EpdDaemon().run()
