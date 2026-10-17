#!/usr/bin/python3
"""Compose preview.png, the marketplace card, from screenshots/compact.png.

capture.py runs this after it captures the reader. The marketplace card
shows only a strip from the middle, about 2.7 times as wide as it is tall,
and the websites crop to 16:9. So the reader is shown large, running off
the bottom edge, with its title and the sung line in the middle, where
every crop keeps them, over Omarchy's Ristretto wallpaper, blurred and
dimmed.
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageEnhance, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
WALLPAPER = Path("/usr/share/omarchy/themes/ristretto/backgrounds/0-launch.png")
W, H = 2560, 1600


def cover(image, width, height):
    scale = max(width / image.width, height / image.height)
    image = image.resize((round(image.width * scale), round(image.height * scale)), Image.LANCZOS)
    left, top = (image.width - width) // 2, (image.height - height) // 2
    return image.crop((left, top, left + width, top + height))


def main():
    back = cover(Image.open(WALLPAPER).convert("RGB"), W, H).filter(ImageFilter.GaussianBlur(24))
    card = ImageEnhance.Brightness(back).enhance(0.35).convert("RGBA")
    # The capture is five times the logical size; at 0.6 of it the header
    # and the sung line both fall in the card's strip, and both crops cut
    # between lines, not through one.
    reader = Image.open(ROOT / "screenshots/compact.png").convert("RGBA")
    reader = reader.resize((round(reader.width * 0.6), round(reader.height * 0.6)), Image.LANCZOS)
    x, y = (W - reader.width) // 2, 345
    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((x + 16, y + 40, x + reader.width + 16, y + reader.height + 40),
                                             50, fill=(0, 0, 0, 190))
    card = Image.alpha_composite(card, shadow.filter(ImageFilter.GaussianBlur(40)))
    card.alpha_composite(reader, (x, y))
    card.convert("RGB").save(ROOT / "preview.png", optimize=True)
    print(ROOT / "preview.png", card.size)


if __name__ == "__main__": main()
