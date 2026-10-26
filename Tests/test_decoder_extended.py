"""Generated interoperability fixtures; no scanned book pages or DLLs bundled."""
from pathlib import Path
import io,json,re,struct,subprocess,sys,tempfile,zipfile
from PIL import Image
sys.path.insert(0,str(Path(__file__).parent/'Reference'))
import pdg_decoder as reference
from test_decoder import header,encode,encrypt_block
ROOT=Path(__file__).resolve().parents[1];EXE=ROOT/'UVZ Reader Lab.app/Contents/MacOS/UVZReaderLab'
def run(*args,ok=True):
 p=subprocess.run([str(EXE),*map(str,args)],capture_output=True,text=True,timeout=90)
 if ok:assert p.returncode==0,p.stderr
 else:assert p.returncode!=0
 return json.loads(p.stdout) if p.stdout.strip() and p.returncode==0 else None

def tables():
 text=(ROOT/'Source/PDGSeriesTables.h').read_text();result={}
 for key,name in [('master_key_words','seriesMaster'),('rot','seriesRot'),('ksbox','seriesKS'),('spbox','seriesSP')]:
  values=re.search(name+r'\[\] = \{(.*?)\};',text,re.S).group(1)
  result[key]=[int(x,16) for x in re.findall(r'0x[0-9a-f]+',values)]
 result['spbox']=bytes(result['spbox']);return result

def series_encode(raw,seeds,blocks=17):
 sch=reference._build_a0_schedules(seeds,tables());out=bytearray(raw)
 for off in range(0,min(blocks*32,len(out)-15),32):
  a,b,c,d=struct.unpack_from('<4I',out,off)
  # Inverse of the six Feistel stages; reference functions supply the DES primitive.
  for i in range(6):
   k=sch[['k1fc0','k2040','k20c0','k2140','k21c0','k2240'][i]]
   x,y=reference._sub_08b780_enc([a,b] if i%2==0 else [c,d],k,sch['spbox'])
   if i%2==0:c^=x;d^=y
   else:a^=x;b^=y
  struct.pack_into('<4I',out,off,a,b,c,d)
 return bytes(out)

def seed28(h):
 a,b,c,d=struct.unpack_from('<4I',h,16);s=0xe3779b90;m=0xffffffff
 c=(c-((a<<4)^(a>>5)^((a+s)&m)))&m;d=(d-((c<<4)^(c>>5)^((c+s)&m)))&m
 b=(b-((d<<4)^(d>>5)^((d+s)&m)))&m;a=(a-((b<<4)^(b>>5)^((b+s)&m)))&m
 first=(0x1c886470-a)&m
 return [first,-(((a+s)&m)^d)&m,-(((a+(first>>5))&m)^((b+s)&m))&m,-(b^((d+s)&m))&m]

def main():
 checks=[]
 with tempfile.TemporaryDirectory(prefix='uvz-extended-') as td:
  root=Path(td);im=Image.new('RGB',(70,96));im.putdata([(x*3%256,y*2%256,(x+y)%256) for y in range(96) for x in range(70)])
  buf=io.BytesIO();im.save(buf,'PNG');raw=buf.getvalue().ljust(2048,b'\0')
  def verify(label,data,expected=raw,size=(70,96),pixels=True):
   src=root/(label+'.pdg');out=root/(label+'.decoded');png=root/(label+'.png');src.write_bytes(data)
   run('--decode-page',src,out);assert out.read_bytes()==expected,label
   run('--render-page',src,1,png)
   with Image.open(png) as got:
    assert got.size==size,(label,got.size)
    if pixels:assert got.convert('RGB').tobytes()==im.tobytes(),label
   checks.append(label+' payload and rendered pixels')
   return src
  for mode in [0,4,5]:
   h=bytearray(56);h[:3]=b'HH\1';struct.pack_into('<HH',h,3,70,96);struct.pack_into('<I',h,7,mode);struct.pack_into('<I',h,28,len(raw))
   value=raw if mode==0 else raw[:128]+b'x'*(1 if mode==4 else 2)+raw[128:]
   verify('v1-'+str(mode),bytes(h)+value)
  for typ in [0xaa,0xab,0xac]:
   logical=header(typ,len(raw),70,96)
   if typ==0xaa:seeds=[8520200,19005960,8409144,9568776]
   elif typ==0xab:seeds=[struct.unpack_from('<I',logical,at)[0]^key for at,key in zip([12,16,20,24],[0x820208,0x1220208,0x805038,0x920208])]
   else:seeds=[struct.unpack_from('<I',logical,at)[0]^key for at,key in zip([32,36,40,44],[0x820208,0x1220208,0x805038,0x920208])]
   payload=series_encode(raw,seeds)
   if typ==0xab:logical[16:18],logical[18:20]=logical[18:20],logical[16:18]
   if typ==0xac:struct.pack_into('<HH',logical,16,170,1096)
   logical[56:58]=b'\2\x86';payload=series_encode(payload,[850670129,941241401,8414468,9568772]);struct.pack_into('<H',logical,16,struct.unpack_from('<H',logical,16)[0]+49)
   verify(hex(typ)+'-preprocessed',bytes(logical)+payload)
  # Type10 is tested with bitonal data so the decoded dimensions matter.
  h=header(0x10,32,1,1);h[20]=1;h[104:108]=b'\x18\x27\xff\xff'
  normalized=bytearray(h);reference._normalize_type10_header(normalized)
  w,hg=struct.unpack_from('<HH',normalized,16)
  width,height=32,24;struct.pack_into('<HH',h,16,(width-w+1)&65535,(height-hg+1)&65535)
  b=bytes([255])*32;src=root/'type10.pdg';src.write_bytes(bytes(h)+b);run('--render-page',src,1,root/'type10.png')
  with Image.open(root/'type10.png') as got:assert got.size==(width,height)
  checks.append('type10 dimensions normalized before bitonal decoding')
  h=header(0x28,len(raw),70,96);payload=series_encode(raw,seed28(h),len(raw)//32);verify('type28',bytes(h)+payload)
  # Standalone and PDG-wrapped JPEG2000, including raw J2K codestream.
  for fmt,no_jp2 in [('jp2',False),('j2k',True)]:
   b=io.BytesIO();im.save(b,'JPEG2000',no_jp2=no_jp2,irreversible=False);payload=b.getvalue()
   verify(fmt,bytes(header(0,len(payload),70,96))+payload,payload)
  for label,b in [('v1-short',b'HH\1'),('v2-short',b'HH\2'),('bad-type',bytes(header(0x60,1))+b'x'),('bad-preprocess',bytes(header(0,1)[:56])+b'\1\0'+bytes(82)+b'x')]:
   p=root/(label+'.pdg');p.write_bytes(b);run('--decode-page',p,root/'bad.out',ok=False);checks.append(label+' rejected')
  # A new format must work inside ZIP and through PDF export, not just decoder entry.
  archive=root/'mixed.uvz'
  with zipfile.ZipFile(archive,'w') as z:
   for i,label in enumerate(['v1-0','0xaa-preprocessed','type28']):z.writestr(f'{i+1:06d}.pdg',(root/(label+'.pdg')).read_bytes())
  assert run('--verify',archive)['renderedPages']==3
  assert run('--convert-pdf',archive,root/'converted.pdf')['outputPages']==3
  checks.append('extended formats read and convert inside an archive')
 print(json.dumps(dict(passed=len(checks),checks=checks),ensure_ascii=False,indent=2))
if __name__=='__main__':main()
