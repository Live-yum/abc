#!/usr/bin/env python3
"""Original synthetic v139 furniture fixture: named chest, sign, training dummy."""
import pathlib,struct,sys
p=lambda fmt,*v:struct.pack('<'+fmt,*v)
def text(s):
 b=s.encode();assert len(b)<128;return bytes([len(b)])+b
name='ABC object fixture';width,height=16,32
flags=bytearray(271)
for offset,value in {0:1,8:width*16,16:height*16,20:height,24:width}.items():struct.pack_into('<i',flags,offset,value)
flags[130]=1
objects=[(21,1,2,2,2),(55,4,2,2,2),(378,7,2,2,3)]
tiles=bytearray()
for x in range(width):
 for y in range(height):
  obj=next((a for a in objects if a[1]<=x<a[1]+a[3] and a[2]<=y<a[2]+a[4]),None)
  if obj:
   tile,xx,yy,_,_=obj;tiles+=bytes([2|(32 if tile>255 else 0)])+(p('H',tile) if tile>255 else bytes([tile]))+p('hh',(x-xx)*18,(y-yy)*18)
  else:tiles+=b'\0'
chests=p('hhii',1,40,1,2)+text('Keeps inventory')+p('hiB',9,8,3)+p('h',0)*39
signs=p('h',1)+text('Keeps sign text')+p('ii',4,2)
entities=p('iBiHHh',1,0,7,7,2,-1)
sections=[text(name)+flags,tiles,chests,signs,b'\0',entities,b'\1'+text(name)+p('i',1)]
important=bytearray(48)
for tile,*_ in objects:important[tile//8]|=1<<(tile%8)
format_size=4+20+2+4*7+2+len(important)
positions=[];cursor=format_size
for section in sections:positions.append(cursor);cursor+=len(section)
fmt=p('i',139)+b'relogic\2'+bytes(12)+p('h',7)+p('7i',*positions)+p('h',384)+important
path=pathlib.Path(sys.argv[1]);path.write_bytes(fmt+b''.join(sections));print(path)
