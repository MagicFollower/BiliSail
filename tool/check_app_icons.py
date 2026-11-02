"""Check launcher icon sizes and generated pixels.

    uv run --with pillow==12.3.0 python tool/check_app_icons.py

Android-only since the platform collapse: every icon is one runtime source PNG
under `assets/branding/` plus the five densities the manifest aliases point at,
and each density must be the LANCZOS rescale of that source - not a hand-edited
or stale file. The runtime source is checked against the artwork it came from
(vector for `bilibili`, the 256px ICO frame for `dsconfinement`) so the checked-in
PNG cannot drift from its input either.
"""
import hashlib
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
DENSITIES = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
checked = 0


def check_png(path, original, size):
    global checked
    expected = original.resize((size, size), Image.Resampling.LANCZOS)
    with Image.open(ROOT / path) as actual:
        assert actual.size == (size, size), path
        assert actual.mode == expected.mode, (path, actual.mode)
        assert actual.tobytes() == expected.tobytes(), path
    checked += 1


def open_rgba(path):
    with Image.open(ROOT / path) as image:
        return image.convert("RGBA")


# The runtime PNG must still be the frame its artwork ships.
assert open_rgba("assets/branding/dsconfinement_icon.png").tobytes() == \
    open_rgba("assets/branding/dsconfinement_source.ico").tobytes(), \
    "dsconfinement_icon.png is not the ICO's largest frame"

for source, android, size in (
    ("app_icon.png", "ic_launcher", (1254, 1254)),
    ("bilibili_pink.png", "ic_launcher_bilibili", (1254, 1254)),
    ("dsconfinement_icon.png", "ic_launcher_dsconfinement", (256, 256)),
):
    original = open_rgba(f"assets/branding/{source}")
    assert original.size == size, (source, original.size)
    assert original.getpixel((0, 0))[3] == 0, source
    for density, pixels in DENSITIES.items():
        check_png(f"android/app/src/main/res/mipmap-{density}/{android}.png", original, pixels)

print(f"Icon resources checked: {checked}; runtime sources: "
      "app_icon/bilibili_pink 1254x1254, dsconfinement 256x256 RGBA")
for name in ("app_icon.png", "bilibili_source.svg", "dsconfinement_source.ico"):
    digest = hashlib.sha256((ROOT / "assets/branding" / name).read_bytes()).hexdigest()
    print(f"{name} SHA-256: {digest}")
