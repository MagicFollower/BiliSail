"""Regenerate Android launcher icons.

    uv run --with pillow==12.3.0 --with resvg-py==0.5.0 python tool/generate_app_icons.py

Pass names to rebuild only some of them, e.g.
`python tool/generate_app_icons.py dsconfinement`.

The tree is Android-only since the platform collapse, so nothing is written for
Windows/macOS/iOS/Linux any more; each icon is one runtime source PNG under
`assets/branding/` plus the five launcher densities the manifest aliases point
at. Run `tool/check_app_icons.py` afterwards to prove the densities are the
source rescaled, not hand-edited.
"""
import sys
from pathlib import Path

from PIL import Image
import resvg_py

root = Path(__file__).resolve().parent.parent
DENSITIES = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}


def write_android_sizes(image, base):
    for density, size in DENSITIES.items():
        image.resize((size, size), Image.Resampling.LANCZOS).save(
            root / f"android/app/src/main/res/mipmap-{density}/{base}.png")


def bilisail():
    with Image.open(root / "assets/branding/app_icon.png") as source:
        write_android_sizes(source.convert("RGBA"), "ic_launcher")


def bilibili():
    # Render the alternate from its vector source, with brand pink and margins.
    svg = (root / "assets/branding/bilibili_source.svg").read_text(encoding="utf-8")
    svg = svg.replace('viewBox="0 0 24 24"',
                      'width="1254" height="1254" fill="#FB7299" viewBox="-1 -1 26 26"')
    (root / "assets/branding/bilibili_pink.svg").write_text(svg, encoding="utf-8")
    (root / "assets/branding/bilibili_pink.png").write_bytes(
        resvg_py.svg_to_bytes(svg_string=svg))
    with Image.open(root / "assets/branding/bilibili_pink.png") as source:
        write_android_sizes(source.convert("RGBA"), "ic_launcher_bilibili")


def dsconfinement():
    # The artwork arrived as an ICO; the 256px frame is the largest one and the
    # runtime source. Pillow opens the biggest frame by default.
    with Image.open(root / "assets/branding/dsconfinement_source.ico") as source:
        image = source.convert("RGBA")
        assert image.size == (256, 256), image.size
        image.save(root / "assets/branding/dsconfinement_icon.png")
        write_android_sizes(image, "ic_launcher_dsconfinement")


ICONS = {"bilisail": bilisail, "bilibili": bilibili, "dsconfinement": dsconfinement}

selected = sys.argv[1:] or list(ICONS)
unknown = [name for name in selected if name not in ICONS]
if unknown:
    raise SystemExit(f"Unknown icons: {', '.join(unknown)}; known: {', '.join(ICONS)}")
for name in selected:
    ICONS[name]()
    print(f"Generated {name}: 1 runtime source + {len(DENSITIES)} launcher densities")
