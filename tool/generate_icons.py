#!/usr/bin/env python3
"""Generate original TerraForge launcher artwork; no game assets are used."""
import json
from pathlib import Path
from PIL import Image, ImageDraw
ROOT=Path(__file__).resolve().parents[1]
def icon(size):
    im=Image.new('RGB',(1024,1024),'#102029');d=ImageDraw.Draw(im)
    d.rounded_rectangle((86,86,938,938),radius=210,fill='#9be7c1')
    # Pixel-block forge: a stepped roof, central stem, and offset ground blocks.
    dark='#183b36'
    d.polygon([(258,340),(354,244),(674,244),(770,340),(674,340),(674,420),(562,420),(562,712),(450,712),(450,420),(354,420),(354,340)],fill=dark)
    d.rectangle((258,712,370,792),fill='#4c8b75')
    d.rectangle((402,744,610,824),fill=dark)
    d.rectangle((642,712,754,792),fill='#4c8b75')
    return im.resize((size,size),Image.Resampling.LANCZOS)
def save(path,size):
    path.parent.mkdir(parents=True,exist_ok=True);icon(size).save(path)
for density,size in [('mdpi',48),('hdpi',72),('xhdpi',96),('xxhdpi',144),('xxxhdpi',192)]:
    save(ROOT/f'android/app/src/main/res/mipmap-{density}/ic_launcher.png',size)
for platform in ['ios','macos']:
    folder=ROOT/platform/'Runner/Assets.xcassets/AppIcon.appiconset'
    payload=json.loads((folder/'Contents.json').read_text())
    for item in payload['images']:
        if 'filename' not in item:continue
        base=float(item['size'].split('x')[0]);scale=float(item['scale'].rstrip('x'))
        save(folder/item['filename'],round(base*scale))
for name,size in [('Icon-192.png',192),('Icon-512.png',512),('Icon-maskable-192.png',192),('Icon-maskable-512.png',512)]:save(ROOT/'web/icons'/name,size)
save(ROOT/'web/favicon.png',64)
print('Generated original TerraForge platform icons.')
