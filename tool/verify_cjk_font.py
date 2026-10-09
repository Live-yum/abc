#!/usr/bin/env python3
"""Check bundled Chinese glyph coverage. Requires fonttools==4.61.1."""

from pathlib import Path
import hashlib
import re

from fontTools.ttLib import TTFont


ROOT = Path(__file__).resolve().parents[1]
FONT = ROOT / "assets/fonts/TerraForgeCJK-Regular.otf"
SHA256 = "8d8f6deb9c77910cb8e24fad5b576446cac5f04faa685acaf74fcc5e4079e65b"
HAN = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\U00020000-\U000323af]")


def main():
    font = TTFont(FONT)
    cmap = font.getBestCmap()
    assert font.sfntVersion == "OTTO", "Must remain native/Web OpenType CFF"
    assert font["OS/2"].usWeightClass == 400
    assert font["name"].getDebugName(1) == "TerraForge CJK"
    assert font["name"].getDebugName(6) == "TerraForgeCJK-Regular"
    assert font["CFF "].cff.fontNames == ["TerraForgeCJK-Regular"]
    assert len(cmap) == 44810, "Expected the source face's full Unicode cmap"
    assert hashlib.sha256(FONT.read_bytes()).hexdigest() == SHA256

    # Test the actual labels, including every Han character in Dart source.
    ui_chars = set()
    for source in (ROOT / "lib").rglob("*.dart"):
        ui_chars.update(map(ord, HAN.findall(source.read_text(encoding="utf-8"))))
    required = (
        ui_chars
        | set(range(0x4E00, 0x9FF0))
        | set(range(0x3400, 0x4DB6))
        | set(range(0xAC00, 0xD7A4))
        | set(map(ord, "赵钱孙李周吴郑王张陈刘黄杨林欧阳司马繁體中文龍臺灣"))
    )
    missing = sorted(cp for cp in required if cp not in cmap or cmap[cp] == ".notdef")
    assert not missing, "Missing UI/name characters: " + " ".join(
        f"{chr(cp)} U+{cp:04X}" for cp in missing
    )
    print(f"PASS: {len(ui_chars)} distinct Han characters in lib/**/*.dart; "
          f"44,810 mapped Unicode code points; {FONT.stat().st_size:,} bytes")


if __name__ == "__main__":
    main()
