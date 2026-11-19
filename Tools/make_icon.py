#!/usr/bin/env python3
"""生成 App 图标（1024x1024）。用法：python3 Tools/make_icon.py"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
OUTPUT = Path(__file__).resolve().parent.parent / (
    "iDeviceXRay/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
)


def gradient_background() -> Image.Image:
    image = Image.new("RGB", (SIZE, SIZE))
    draw = ImageDraw.Draw(image)
    top = (124, 58, 237)     # #7C3AED
    bottom = (20, 8, 40)     # 深紫

    for y in range(SIZE):
        t = y / (SIZE - 1)
        ease = t ** 0.85
        color = tuple(int(top[i] * (1 - ease) + bottom[i] * ease) for i in range(3))
        draw.line([(0, y), (SIZE, y)], fill=color)

    # 左上角高光
    glow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse([-260, -360, 620, 520], fill=(168, 85, 247, 90))
    glow = glow.filter(ImageFilter.GaussianBlur(160))
    return Image.alpha_composite(image.convert("RGBA"), glow)


def overlay() -> Image.Image:
    layer = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    cx = cy = SIZE // 2

    # 取景框四角
    frame = 300
    arm = 124
    width = 24
    color = (255, 255, 255, 232)

    corners = [
        [(cx - frame, cy - frame + arm), (cx - frame, cy - frame), (cx - frame + arm, cy - frame)],
        [(cx + frame - arm, cy - frame), (cx + frame, cy - frame), (cx + frame, cy - frame + arm)],
        [(cx - frame, cy + frame - arm), (cx - frame, cy + frame), (cx - frame + arm, cy + frame)],
        [(cx + frame - arm, cy + frame), (cx + frame, cy + frame), (cx + frame, cy + frame - arm)],
    ]
    for points in corners:
        draw.line(points, fill=color, width=width, joint="curve")

    # 设备轮廓
    draw.rounded_rectangle(
        [cx - 96, cy - 152, cx + 96, cy + 152],
        radius=38,
        outline=(255, 255, 255, 240),
        width=16,
    )
    draw.line([(cx - 96, cy - 108), (cx + 96, cy - 108)], fill=(255, 255, 255, 150), width=9)

    # 扫描光带
    band = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    bd = ImageDraw.Draw(band)
    bd.rectangle([cx - 300, cy + 18, cx + 300, cy + 58], fill=(34, 211, 238, 205))
    band = band.filter(ImageFilter.GaussianBlur(16))
    layer = Image.alpha_composite(layer, band)

    # 青色外发光
    halo = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    hd = ImageDraw.Draw(halo)
    hd.rounded_rectangle(
        [cx - 96, cy - 152, cx + 96, cy + 152],
        radius=38,
        outline=(34, 211, 238, 110),
        width=30,
    )
    halo = halo.filter(ImageFilter.GaussianBlur(46))
    return Image.alpha_composite(halo, layer)


def main() -> None:
    base = gradient_background()
    result = Image.alpha_composite(base, overlay()).convert("RGB")
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    result.save(OUTPUT, "PNG")
    print(f"saved {OUTPUT} {result.size}")


if __name__ == "__main__":
    main()
