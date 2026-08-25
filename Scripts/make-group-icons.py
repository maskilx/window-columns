#!/usr/bin/env python3
from pathlib import Path
from PIL import Image, ImageOps

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Resources" / "AppIcon-v3-Light.png"
OUTPUT = ROOT / "Resources" / "GroupIcons"

PALETTES = [
    ((10, 65, 170), (92, 185, 255)),
    ((65, 35, 155), (177, 116, 255)),
    ((145, 25, 70), (255, 113, 157)),
    ((157, 61, 10), (255, 174, 78)),
    ((7, 105, 70), (75, 225, 164)),
    ((0, 95, 135), (73, 213, 244)),
    ((115, 55, 22), (229, 148, 85)),
    ((55, 68, 94), (157, 177, 211)),
    ((20, 115, 75), (112, 233, 96)),
]

OUTPUT.mkdir(parents=True, exist_ok=True)
source = Image.open(SOURCE).convert("RGBA")
alpha = source.getchannel("A")
gray = ImageOps.grayscale(source.convert("RGB"))
gray = ImageOps.autocontrast(gray, cutoff=1)

for index, (shadow, highlight) in enumerate(PALETTES, start=1):
    colored = ImageOps.colorize(gray, black=shadow, white=highlight).convert("RGBA")
    colored.putalpha(alpha)
    colored.save(OUTPUT / f"Group{index}.png", optimize=True)
