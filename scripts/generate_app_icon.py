#!/usr/bin/env python3

from __future__ import annotations

import json
import math
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter


SIZE = 1024
OUTPUT_DIR = Path("Vomo/Assets.xcassets/AppIcon.appiconset")
MASTER_OUTPUT = OUTPUT_DIR / "AppIcon.png"
ICON_SPECS = [
    {"idiom": "iphone", "size": "20x20", "scale": "2x", "filename": "AppIcon-20@2x.png", "pixels": 40},
    {"idiom": "iphone", "size": "20x20", "scale": "3x", "filename": "AppIcon-20@3x.png", "pixels": 60},
    {"idiom": "iphone", "size": "29x29", "scale": "2x", "filename": "AppIcon-29@2x.png", "pixels": 58},
    {"idiom": "iphone", "size": "29x29", "scale": "3x", "filename": "AppIcon-29@3x.png", "pixels": 87},
    {"idiom": "iphone", "size": "40x40", "scale": "2x", "filename": "AppIcon-40@2x.png", "pixels": 80},
    {"idiom": "iphone", "size": "40x40", "scale": "3x", "filename": "AppIcon-40@3x.png", "pixels": 120},
    {"idiom": "iphone", "size": "60x60", "scale": "2x", "filename": "AppIcon-60@2x.png", "pixels": 120},
    {"idiom": "iphone", "size": "60x60", "scale": "3x", "filename": "AppIcon-60@3x.png", "pixels": 180},
    {"idiom": "ipad", "size": "20x20", "scale": "1x", "filename": "AppIcon-iPad-20@1x.png", "pixels": 20},
    {"idiom": "ipad", "size": "20x20", "scale": "2x", "filename": "AppIcon-iPad-20@2x.png", "pixels": 40},
    {"idiom": "ipad", "size": "29x29", "scale": "1x", "filename": "AppIcon-iPad-29@1x.png", "pixels": 29},
    {"idiom": "ipad", "size": "29x29", "scale": "2x", "filename": "AppIcon-iPad-29@2x.png", "pixels": 58},
    {"idiom": "ipad", "size": "40x40", "scale": "1x", "filename": "AppIcon-iPad-40@1x.png", "pixels": 40},
    {"idiom": "ipad", "size": "40x40", "scale": "2x", "filename": "AppIcon-iPad-40@2x.png", "pixels": 80},
    {"idiom": "ipad", "size": "76x76", "scale": "1x", "filename": "AppIcon-iPad-76@1x.png", "pixels": 76},
    {"idiom": "ipad", "size": "76x76", "scale": "2x", "filename": "AppIcon-iPad-76@2x.png", "pixels": 152},
    {"idiom": "ipad", "size": "83.5x83.5", "scale": "2x", "filename": "AppIcon-iPad-83.5@2x.png", "pixels": 167},
    {"idiom": "ios-marketing", "size": "1024x1024", "scale": "1x", "filename": "AppIcon.png", "pixels": 1024},
]


def lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def lerp_color(start: tuple[int, int, int], end: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    return tuple(round(lerp(s, e, t)) for s, e in zip(start, end))


def vertical_gradient(size: int, top: tuple[int, int, int], bottom: tuple[int, int, int]) -> Image.Image:
    image = Image.new("RGBA", (size, size))
    px = image.load()
    for y in range(size):
        t = y / (size - 1)
        row = (*lerp_color(top, bottom, t), 255)
        for x in range(size):
            px[x, y] = row
    return image


def add_radial_glow(base: Image.Image, center: tuple[float, float], radius: float, color: tuple[int, int, int], strength: int) -> None:
    glow = Image.new("RGBA", base.size, (0, 0, 0, 0))
    px = glow.load()
    cx, cy = center
    for y in range(base.height):
        dy = y - cy
        for x in range(base.width):
            dx = x - cx
            distance = math.hypot(dx, dy)
            if distance >= radius:
                continue
            t = 1.0 - (distance / radius)
            alpha = round((t * t) * strength)
            px[x, y] = (*color, alpha)
    base.alpha_composite(glow)


def rounded_bar(draw: ImageDraw.ImageDraw, box: tuple[int, int, int, int], fill: tuple[int, int, int, int]) -> None:
    draw.rounded_rectangle(box, radius=(box[2] - box[0]) // 2, fill=fill)


def add_shadow(canvas: Image.Image, box: tuple[int, int, int, int], radius: int, color: tuple[int, int, int, int], blur: int) -> None:
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_draw.rounded_rectangle(box, radius=radius, fill=color)
    shadow = shadow.filter(ImageFilter.GaussianBlur(blur))
    canvas.alpha_composite(shadow)


def main() -> None:
    icon = vertical_gradient(SIZE, (247, 243, 255), (231, 220, 255))

    sweep = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    sweep_draw = ImageDraw.Draw(sweep)
    sweep_draw.polygon(
        [(-80, 700), (360, 260), (980, -40), (SIZE + 120, -40), (SIZE + 120, 1120), (-80, 1120)],
        fill=(157, 111, 255, 40),
    )
    sweep = sweep.filter(ImageFilter.GaussianBlur(72))
    icon.alpha_composite(sweep)

    add_radial_glow(icon, (SIZE * 0.18, SIZE * 0.12), 320, (255, 255, 255), 90)
    add_radial_glow(icon, (SIZE * 0.82, SIZE * 0.82), 420, (139, 92, 246), 60)

    lines = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    lines_draw = ImageDraw.Draw(lines)
    for y in (250, 336, 422, 688, 774):
        lines_draw.rounded_rectangle((184, y, 840, y + 26), radius=13, fill=(201, 182, 244, 150))
    lines = lines.filter(ImageFilter.GaussianBlur(1))
    icon.alpha_composite(lines)

    waveform = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    waveform_draw = ImageDraw.Draw(waveform)
    centers = [252, 396, 540, 684, 828]
    heights = [208, 380, 540, 380, 208]
    colors = [
        (99, 68, 214, 255),
        (110, 72, 228, 255),
        (124, 58, 237, 255),
        (138, 86, 246, 255),
        (163, 132, 243, 255),
    ]
    base_y = 548
    width = 88
    for cx, height, fill in zip(centers, heights, colors):
        top = base_y - height // 2
        bottom = base_y + height // 2
        rounded_bar(waveform_draw, (cx - width // 2, top, cx + width // 2, bottom), fill)

    waveform_glow = waveform.filter(ImageFilter.GaussianBlur(36))
    tint = Image.new("RGBA", (SIZE, SIZE), (182, 153, 255, 0))
    waveform_glow = ImageChops.screen(waveform_glow, tint)
    icon.alpha_composite(waveform_glow)
    icon.alpha_composite(waveform)

    top_gloss = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    gloss_draw = ImageDraw.Draw(top_gloss)
    gloss_draw.pieslice((-160, -280, SIZE + 220, 320), 180, 360, fill=(255, 255, 255, 26))
    top_gloss = top_gloss.filter(ImageFilter.GaussianBlur(62))
    icon.alpha_composite(top_gloss)

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    for spec in ICON_SPECS:
        resized = icon.resize((spec["pixels"], spec["pixels"]), Image.Resampling.LANCZOS)
        resized.save(OUTPUT_DIR / spec["filename"])

    contents = {
        "images": [
            {
                "idiom": spec["idiom"],
                "size": spec["size"],
                "scale": spec["scale"],
                "filename": spec["filename"],
            }
            for spec in ICON_SPECS
        ],
        "info": {
            "author": "xcode",
            "version": 1,
        },
    }

    (OUTPUT_DIR / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")
    print(f"Wrote {MASTER_OUTPUT} and {len(ICON_SPECS) - 1} derived icons")


if __name__ == "__main__":
    main()
