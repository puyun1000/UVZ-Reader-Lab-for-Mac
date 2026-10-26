#!/usr/bin/env python3
"""Reproduce interoperability constants from the pinned upstream reference file.

Does not load, execute, modify, copy or redistribute the supplied Windows DLL.
"""
import argparse,hashlib,struct
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('reference',type=Path);p.add_argument('output',type=Path);a=p.parse_args()
b=a.reference.read_bytes()
assert hashlib.sha256(b).hexdigest()=='78c5762dccdc339c3e72c656191869c57026e596a6ccdbef7e422c37bb1bbabc','Unexpected reference version'
pe=struct.unpack_from('<I',b,0x3c)[0];assert b[pe:pe+4]==b'PE\0\0'
count=struct.unpack_from('<H',b,pe+6)[0];optional=struct.unpack_from('<H',b,pe+20)[0];sections=pe+24+optional

def read(rva,n):
 for i in range(count):
  at=sections+40*i;vs,va,rs,raw=struct.unpack_from('<4I',b,at+8)
  if va<=rva<va+max(vs,rs):
   offset=raw+rva-va;assert rva-va+n<=rs and offset+n<=len(b);return b[offset:offset+n]
 raise ValueError('Unmapped reference constant')
s='// PDG interoperability constants used by the MIT-licensed 100apps/pdg_decoder.\n// See Docs/Decoder-0.3.0.md for provenance and reproduction. No executable DLL code.\n#pragma once\n#include <cstdint>\n'
for rva,n,fmt,typ,name in [(0xc28f50,8,'<2I','uint32_t','seriesMaster'),(0xc28f60,16,'<16B','uint8_t','seriesRot'),(0xc28f70,2048,'<512I','uint32_t','seriesKS'),(0xc286cf,2052,'<2052B','uint8_t','seriesSP')]:
 values=struct.unpack(fmt,read(rva,n));s+=f'static constexpr {typ} {name}[] = {{\n'
 for i in range(0,len(values),8):s+='    '+','.join(hex(x) for x in values[i:i+8])+',\n'
 s+='};\n'
assert not a.output.exists(),'Choose a new output path to compare with the committed header'
a.output.write_text(s)
print(hashlib.sha256(a.output.read_bytes()).hexdigest())
