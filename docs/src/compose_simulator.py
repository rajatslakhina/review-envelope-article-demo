"""Puts two real Simulator screenshots side by side for the README and article."""
import sys
from PIL import Image, ImageDraw

left, right, out = sys.argv[1:4]
a, b = Image.open(left).convert("RGB"), Image.open(right).convert("RGB")
scale = 900 / a.height
a = a.resize((int(a.width * scale), 900))
b = b.resize((int(b.width * scale), 900))
pad = 40
canvas = Image.new("RGB", (a.width + b.width + pad * 3, 900 + pad * 2), (241, 245, 249))
canvas.paste(a, (pad, pad))
canvas.paste(b, (a.width + pad * 2, pad))
draw = ImageDraw.Draw(canvas)
for x, img in ((pad, a), (a.width + pad * 2, b)):
    draw.rectangle([x - 1, pad - 1, x + img.width, pad + img.height], outline=(148, 163, 184), width=2)
canvas.save(out, optimize=True)
