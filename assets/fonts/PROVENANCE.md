# TerraForge CJK Regular

This app bundles an offline OpenType/CFF font because Flutter Web CanvasKit
cannot reliably use the browser's installed Chinese fonts. The Flutter family
is `TerraForge CJK`; the font has one real Regular (400) weight. Heavier UI
weights are synthesized by the renderer, not separate authored bold faces.

## Source and license

- Upstream: [Noto CJK](https://github.com/notofonts/noto-cjk), Sans release
  [2.004](https://github.com/notofonts/noto-cjk/tree/Sans2.004).
- Upstream license:
  [SIL Open Font License 1.1](https://github.com/notofonts/noto-cjk/blob/Sans2.004/LICENSE).
  The complete license and original notices are included in `LICENSE.txt`,
  which is also packaged as an application asset.
- Local distribution: `/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc`,
  documented by `/usr/share/doc/fonts-noto-cjk/copyright` (Debian package
  copyright file, dated 2024-08-10). No exact installed package version was
  available; the embedded face version is `2.004`.
- Original TTC SHA-256:
  `b76b0433203017ca80401b2ee0dd69350349871c4b19d504c34dbdd80541690a`.
- Selected face: zero-based TTC index **2**, verified family
  **Noto Sans CJK SC**, subfamily **Regular**, OS/2 weight **400**.
- The font's embedded original copyright is `© 2014-2021 Adobe
  (http://www.adobe.com/).`; the Debian upstream notice also identifies
  `2010-2012, Google Corporation`. Both are preserved in `LICENSE.txt`.

## Modification and scope

Generated with fontTools **4.61.1**. The SC face was extracted with
`TTFont(source, fontNumber=2, recalcTimestamp=False)` and subset with
`hinting=False`, `layout_features=['ccmp','liga','kern','mark','mkmk']`,
`name_IDs=['*']`, `name_legacy=True`, and `name_languages=['*']`.
The subset input was **every code point in the original face's getBestCmap()**.
No text-only, simplified-only, or common-character subset was used.

The resulting cmap was compared with the original: all **44,810** Unicode
code points are retained. It includes all **20,976** characters from
U+4E00–U+9FEF, all **6,582** characters from U+3400–U+4DB5, and all **11,172**
Hangul syllables. This is the source font's coverage, not a claim to cover
every Unicode Han character. In particular the newer U+9FF0–U+9FFF and
U+4DB6–U+4DBF additions are absent, as they were in the source.

Regional glyph substitutions, vertical layout features and hinting were
removed to reduce bundle size; Simplified Chinese base glyphs are retained.
This font is intended for horizontal UI text. Ideographic variation-sequence
coverage and typography for other regional variants are not guaranteed.

This modified font is named **TerraForge CJK** to avoid reusing an upstream
font family or any reserved names as its primary identity. All existing name
table records with IDs 1, 2, 3, 4, 6, 16 and 17 were updated to that derivative
family, Regular style and `TerraForgeCJK-Regular` PostScript name. The CFF
font name, FamilyName and FullName were updated too. Original author,
copyright, version and license metadata are retained. This does not imply
endorsement by Noto, Google or Adobe.

## Distributed asset and validation

- File: `TerraForgeCJK-Regular.otf` (native/Web OpenType CFF; not WOFF/WOFF2).
- Size: **8,785,236 bytes**.
- SHA-256:
  `8d8f6deb9c77910cb8e24fad5b576446cac5f04faa685acaf74fcc5e4079e65b`.
- Verify the font metadata, exact binary and every Han character currently
  in the app's Dart source with `python tool/verify_cjk_font.py` (requires
  `fonttools==4.61.1`). Browser rendering still requires real-browser QA;
  a glyph-map check alone does not establish that the renderer loaded it.

The font remains licensed under SIL OFL 1.1, independently of the app's
source-code license. The font has no runtime download requirement.
