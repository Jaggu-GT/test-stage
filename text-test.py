#!/usr/bin/env python3
"""
text-test.py — render LARGE legible text via getbuffer on the 2.7" e-ink.

The rectangle test proved getbuffer + hardware are good for solid content.
system_internals() uses PIL's ~6px load_default() font, which renders as a
field of tiny dots that looks like speckle. This draws a real TrueType font
at a readable size to confirm that's all it was.

If the text comes out large and READABLE -> the fix is just a bigger font in
system_internals(). If it's still scrambled -> deeper look needed.

Usage:  python3 text-test.py     (keep it beside waveshare-driver-securev2.py)
"""
import importlib.util
import os
import time
from PIL import Image, ImageDraw, ImageFont

spec = importlib.util.spec_from_file_location("epd", "waveshare-driver-securev2.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def load_font(size):
    for p in ("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
              "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"):
        if os.path.exists(p):
            return ImageFont.truetype(p, size)
    print("WARN: DejaVu TTF not found -> falling back to tiny default font")
    print("      install it with: sudo apt install -y fonts-dejavu-core")
    return ImageFont.load_default()


big = load_font(30)
med = load_font(18)

img = Image.new("1", (m.HEIGHT, m.WIDTH), 255)        # 264x176 landscape
d = ImageDraw.Draw(img)
d.rectangle((2, 2, m.HEIGHT - 3, m.WIDTH - 3), outline=0, width=2)
d.text((16, 18), "E-INK OK", font=big, fill=0)
d.text((16, 78), "2.7in 264x176", font=med, fill=0)
d.text((16, 112), "Pi 3B+ bring-up", font=med, fill=0)

e = m.EPD2in7V2()
e.open()
e.refresh(e.getbuffer(img), force=True)
time.sleep(4)
e.close()
print("done -- is the text LARGE and READABLE (not speckle)?")
