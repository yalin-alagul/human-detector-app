#!/usr/bin/env python3
"""Generate the Human Detector app icon.

Draws a squircle with a gradient, a viewfinder frame, and a person silhouette,
then writes every size macOS wants into the AppIcon asset catalog.

Run:  python3 Scripts/generate_app_icon.py
Requires: pillow  (pip install pillow)
"""

from __future__ import annotations

import os
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

REPO = Path(__file__).resolve().parent.parent
ASSETS = REPO / "Sources/HumanDetectorApp/Resources/Assets.xcassets"
ICONSET = ASSETS / "AppIcon.appiconset"
LOGOSET = ASSETS / "Logo.imageset"

SIZE = 1024
SS = 4  # supersample factor for smooth edges
W = SIZE * SS

TOP = (41, 98, 255)      # blue
BOTTOM = (123, 63, 228)  # violet
WHITE = (255, 255, 255, 255)


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def gradient():
    column = Image.new("RGB", (1, W))
    for y in range(W):
        column.putpixel((0, y), lerp(TOP, BOTTOM, y / (W - 1)))
    return column.resize((W, W))


def squircle_mask(margin_frac=0.055, radius_frac=0.225):
    margin = int(margin_frac * W)
    radius = int(radius_frac * W)
    mask = Image.new("L", (W, W), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [margin, margin, W - margin, W - margin], radius=radius, fill=255
    )
    return mask


def add_highlight(icon, mask):
    overlay = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    draw.ellipse([-W * 0.25, -W * 0.55, W * 1.25, W * 0.45], fill=(255, 255, 255, 46))
    overlay = overlay.filter(ImageFilter.GaussianBlur(W * 0.06))
    overlay.putalpha(
        Image.composite(overlay.getchannel("A"), Image.new("L", (W, W), 0), mask)
    )
    return Image.alpha_composite(icon, overlay)


def add_bottom_shade(icon, mask):
    overlay = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    draw.ellipse([-W * 0.25, W * 0.55, W * 1.25, W * 1.5], fill=(0, 0, 0, 60))
    overlay = overlay.filter(ImageFilter.GaussianBlur(W * 0.08))
    overlay.putalpha(
        Image.composite(overlay.getchannel("A"), Image.new("L", (W, W), 0), mask)
    )
    return Image.alpha_composite(icon, overlay)


def draw_viewfinder(layer):
    d = ImageDraw.Draw(layer)
    inset = 0.150 * W
    arm = 0.105 * W
    th = 0.032 * W
    r = th / 2
    color = (255, 255, 255, 225)

    def corner(x, y, sx, sy):
        d.rounded_rectangle([x, y, x + sx * arm, y + th], radius=r, fill=color)
        d.rounded_rectangle([x, y, x + th, y + sy * arm], radius=r, fill=color)

    corner(inset, inset, 1, 1)
    corner(W - inset - th, inset, 1, 1)
    corner(inset, W - inset - th, 1, 1)
    corner(W - inset - th, W - inset - th, 1, 1)


def draw_person(layer):
    d = ImageDraw.Draw(layer)
    cx = 0.5 * W

    # Head
    head_r = 0.099 * W
    head_cy = 0.385 * W
    d.ellipse([cx - head_r, head_cy - head_r, cx + head_r, head_cy + head_r], fill=WHITE)

    # Shoulders: rounded base + dome for a clean bust silhouette.
    half = 0.188 * W
    base_top = 0.590 * W
    base_bottom = 0.840 * W
    d.rounded_rectangle(
        [cx - half, base_top, cx + half, base_bottom],
        radius=0.062 * W,
        fill=WHITE,
    )
    d.pieslice(
        [cx - half, 0.490 * W, cx + half, 0.900 * W],
        start=180,
        end=360,
        fill=WHITE,
    )


def render_master() -> Image.Image:
    mask = squircle_mask()
    icon = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    icon.paste(gradient(), (0, 0), mask)
    icon = add_bottom_shade(icon, mask)
    icon = add_highlight(icon, mask)

    art = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    draw_viewfinder(art)
    draw_person(art)

    # Soft drop shadow under the person for depth.
    shadow = art.split()[3].filter(ImageFilter.GaussianBlur(W * 0.012))
    shadow_layer = Image.new("RGBA", (W, W), (20, 20, 50, 0))
    shadow_layer.putalpha(shadow.point(lambda v: int(v * 0.35)))
    icon = Image.alpha_composite(icon, shadow_layer)
    icon = Image.alpha_composite(icon, art)

    return icon.resize((SIZE, SIZE), Image.LANCZOS)


SPECS = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

CONTENTS = """{
  "images" : [
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""

LOGO_CONTENTS = """{
  "images" : [
    { "filename" : "logo-1x.png", "idiom" : "universal", "scale" : "1x" },
    { "filename" : "logo-2x.png", "idiom" : "universal", "scale" : "2x" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""


def main():
    ICONSET.mkdir(parents=True, exist_ok=True)
    master = render_master()

    preview = REPO / "build/icon-preview-1024.png"
    preview.parent.mkdir(parents=True, exist_ok=True)
    master.save(preview)

    for name, px in SPECS:
        master.resize((px, px), Image.LANCZOS).save(ICONSET / name)
    (ICONSET / "Contents.json").write_text(CONTENTS)

    # In-app logo (sidebar header).
    LOGOSET.mkdir(parents=True, exist_ok=True)
    master.resize((128, 128), Image.LANCZOS).save(LOGOSET / "logo-1x.png")
    master.resize((256, 256), Image.LANCZOS).save(LOGOSET / "logo-2x.png")
    (LOGOSET / "Contents.json").write_text(LOGO_CONTENTS)

    print(f"wrote {len(SPECS)} icon sizes to {ICONSET.relative_to(REPO)}")
    print(f"wrote logo imageset to {LOGOSET.relative_to(REPO)}")
    print(f"preview: {preview.relative_to(REPO)}")


if __name__ == "__main__":
    main()
