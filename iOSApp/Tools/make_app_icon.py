"""Renders the Battleships app icon.

Usage: python3 iOSApp/Tools/make_app_icon.py iOSApp/Battleships/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
Requires Pillow (pip install pillow).
"""
import sys, math
from PIL import Image, ImageDraw, ImageFilter, ImageChops

S = 4096            # supersampled canvas
F = S / 1024        # scale factor from the 1024 design grid

def p(x, y):
    return (x * F, y * F)

def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(len(a)))

# --- background: deep-sea vertical gradient with a soft central glow
top, bottom = (16, 52, 102), (5, 18, 44)
bg = Image.new("RGB", (S, S))
px = bg.load()
grad = Image.linear_gradient("L").resize((S, S))
bg = Image.composite(Image.new("RGB", (S, S), bottom), Image.new("RGB", (S, S), top), grad)

glow = Image.new("L", (S, S), 0)
gd = ImageDraw.Draw(glow)
gd.ellipse([p(130, 140), p(894, 904)], fill=150)
glow = glow.filter(ImageFilter.GaussianBlur(110 * F))
bg = Image.composite(Image.new("RGB", (S, S), (38, 110, 190)), bg, glow)

d = ImageDraw.Draw(bg, "RGBA")

# --- faint radar grid
for i in range(1, 10):
    c = i * 1024 / 10
    d.line([p(c, 0), p(c, 1024)], fill=(170, 210, 255, 26), width=int(5 * F))
    d.line([p(0, c), p(1024, c)], fill=(170, 210, 255, 26), width=int(5 * F))

# --- water line
d.rectangle([p(0, 730), p(1024, 1024)], fill=(4, 20, 48, 120))

# --- battleship silhouette (bow to the right), sitting low so the crosshair arms stay clear
Y = 40  # vertical offset of the whole ship
def q(x, y):
    return p(x, y + Y)
steel = (196, 214, 232, 255)
shade = (140, 162, 186, 255)
d.polygon([q(118, 612), q(912, 612), q(860, 700), q(196, 700), q(150, 662)], fill=steel)
d.polygon([q(150, 662), q(196, 700), q(860, 700), q(880, 668)], fill=shade)
# superstructure, bridge, mast, funnel
d.rounded_rectangle([q(420, 520), q(612, 616)], radius=int(14 * F), fill=steel)
d.rounded_rectangle([q(462, 452), q(576, 524)], radius=int(12 * F), fill=steel)
d.rectangle([q(508, 380), q(522, 456)], fill=steel)
d.rectangle([q(476, 404), q(554, 416)], fill=steel)
d.rounded_rectangle([q(588, 486), q(620, 524)], radius=int(6 * F), fill=steel)
# turrets with barrels pointing fore and aft
d.rounded_rectangle([q(250, 580), q(340, 616)], radius=int(12 * F), fill=steel)
d.rectangle([q(190, 584), q(262, 596)], fill=steel)
d.rounded_rectangle([q(666, 580), q(756, 616)], radius=int(12 * F), fill=steel)
d.rectangle([q(744, 584), q(842, 596)], fill=steel)
# portholes
for x in range(240, 840, 52):
    d.ellipse([q(x - 7, 642), q(x + 7, 656)], fill=(60, 86, 118, 255))

# --- explosion where the crosshair is aimed
cx, cy = 512, 560
burst = Image.new("L", (S, S), 0)
bd = ImageDraw.Draw(burst)
points = []
for k in range(24):
    ang = math.pi * 2 * k / 24
    r = (118 if k % 2 == 0 else 62)
    points.append(p(cx + math.cos(ang) * r, cy + math.sin(ang) * r))
bd.polygon(points, fill=255)
burst_glow = burst.filter(ImageFilter.GaussianBlur(40 * F))
bg = Image.composite(Image.new("RGB", (S, S), (255, 120, 60)), bg, burst_glow.point(lambda v: int(v * 0.85)))
bg = Image.composite(Image.new("RGB", (S, S), (255, 86, 64)), bg, burst)
core = Image.new("L", (S, S), 0)
ImageDraw.Draw(core).ellipse([p(cx - 46, cy - 46), p(cx + 46, cy + 46)], fill=255)
core = core.filter(ImageFilter.GaussianBlur(6 * F))
bg = Image.composite(Image.new("RGB", (S, S), (255, 214, 120)), bg, core)

# --- crosshair reticle
d = ImageDraw.Draw(bg, "RGBA")
white = (255, 255, 255, 245)
R = 300
w = int(30 * F)
d.ellipse([p(cx - R, cy - R), p(cx + R, cy + R)], outline=white, width=w)
gap = 150
for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
    a = p(cx + dx * gap, cy + dy * gap)
    b = p(cx + dx * (R + 70), cy + dy * (R + 70))
    x0, y0 = min(a[0], b[0]), min(a[1], b[1])
    x1, y1 = max(a[0], b[0]), max(a[1], b[1])
    if dx != 0:
        d.rounded_rectangle([x0, y0 - w / 2, x1, y1 + w / 2], radius=w / 2, fill=white)
    else:
        d.rounded_rectangle([x0 - w / 2, y0, x1 + w / 2, y1], radius=w / 2, fill=white)
icon = bg.resize((1024, 1024), Image.LANCZOS)
icon.save(sys.argv[1], "PNG")
print("saved", sys.argv[1])
