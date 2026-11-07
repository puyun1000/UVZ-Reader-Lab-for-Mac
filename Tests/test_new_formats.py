"""Disposable PDZ/EPUB/text-PDG/layered-page fixtures, including rejected certificates."""
from pathlib import Path
import io,json,struct,hashlib,subprocess,tempfile,zipfile,zlib,sys
from PIL import Image
from reportlab.pdfgen import canvas
from pypdf import PdfReader,PdfWriter
from cryptography.hazmat.primitives.ciphers import Cipher,algorithms,modes
from cryptography.hazmat.decrepit.ciphers.algorithms import Blowfish
from test_decoder import header,simple_pdf
ROOT=Path(__file__).resolve().parents[1]
EXE=ROOT/'UVZ Reader Lab.app/Contents/MacOS/UVZReaderLab'
def run(*args,ok=True):
 p=subprocess.run([str(EXE),*map(str,args)],capture_output=True,text=True,timeout=90)
 assert (p.returncode==0)==ok,(args,p.stderr,p.stdout)
 return json.loads(p.stdout) if p.returncode==0 and p.stdout.strip() else None
ALPHABET=bytes([52,43,82,84,101,54,105,35,114,51,37,57,67,117,99,118,94,38,42,40,41,95,98,110,50,33,121,104,106,56,39,122,73,46,47,81,87,69,53,61,126,116,70,109,111,112,91,93,92,97,64,113,119,66,115,103,44,79,71,36,102,107,108,59,48,45,72,74,75,78,77,60,96,49,68,100,89,85,86,55,76,58,34,90,88,120,80,123,125,124,65,83,62,63,0,0])
def expand(text,salt):
 out=bytearray()
 for i,b in enumerate(text.encode()):
  if len(out)>=32:break
  out.append(b)
  c=ALPHABET[salt[i%4]*i%96]
  if c:out.append(c)
 for c in ALPHABET:
  if len(out)>=32:break
  if c:out.append(c)
 return bytes(out[:32])
def key(text):
 out=bytearray(hashlib.md5(text.encode()).digest())
 mask=struct.pack('<4I',0x820208,0x1220208,0x805038,0x920208)
 return bytes(a^b for a,b in zip(out,mask))
def encrypt_catalog(data,k):
 out=bytearray(data);keys=struct.unpack('<4I',k);mask=0xffffffff
 for at in range(0,len(out)-15,16):
  a,b,c,d=struct.unpack_from('<4I',out,at)
  for turn in reversed(range(16)):
   total=(0xe3779b90-turn*0x9e3779b9)&mask
   def mix(x,l,r):return ((((x<<4)+keys[l])^((x+total)&mask)^((x>>5)+keys[r]))&mask)
   a=(a+mix(b,0,1))&mask;b=(b+mix(c,2,3))&mask;c=(c+mix(d,0,3))&mask;d=(d+mix(a,2,1))&mask
  struct.pack_into('<4I',out,at,a,b,c,d)
 return bytes(out)
def pdz(members,expiry='0',version=b'1.00',legacy=False):
 password='*s{P2a_1mP^?';salt=b'ABCD';bookkey='Disposable fixture book key'
 xml=f'<cert><certexpdate>{expiry}</certexpdate><rightinfo><bookkey>{bookkey}</bookkey></rightinfo></cert>'.encode()
 padding=16-len(xml)%16;xml+=bytes([padding])*padding;iv=bytes(range(16))
 aes=Cipher(algorithms.AES(expand(password,salt)),modes.CBC(iv)).encryptor()
 encoded=(aes.update(xml)+aes.finalize()+iv).hex().upper()
 encoded=encoded[:-2]+salt.decode()+encoded[-2:]
 cert=b'SSCT'+encoded.encode()+hashlib.md5((encoded+password).encode()).hexdigest().upper().encode()+b'[p?ver=2&type=0]SSCE'
 payload=bytearray(96);payload[:4]=b'%pdg';struct.pack_into('<I',payload,4,0x667a if legacy else 0x7a);payload[8:12]=version;payload[13]=4;payload[15]=2 if legacy else 1
 marker='Fixture';payload[28:28+len(marker)]=marker.encode()
 catalog=bytearray()
 for name,data in members:
  value=bytearray(data)
  if name.lower().endswith('.pdg'):
   n=min(len(value),1024)//8*8
   swapped=b''.join(value[i:i+4][::-1] for i in range(0,n,4))
   enc=Cipher(Blowfish(key(bookkey)),modes.ECB()).encryptor();cipher=enc.update(swapped)+enc.finalize()
   value[:n]=b''.join(cipher[i:i+4][::-1] for i in range(0,n,4))
  catalog+=name.encode().ljust(12,b'\0')+struct.pack('<II',len(payload),len(value));payload+=value
 offset=len(payload);payload+=encrypt_catalog(catalog,key(expand(marker,b'ljhd').hex().upper()))
 struct.pack_into('<III',payload,16,len(payload)-96,offset,len(catalog))
 check=payload[:min(len(payload),1024)];check[60:64]=bytes(4);crc=zlib.crc32(check)
 crc=zlib.crc32(payload[-1024:] if len(payload)>2048 else payload[1024:],crc)
 struct.pack_into('<I',payload,60,crc)
 return bytes(payload)+cert

def epub(path,ncx=False):
 with zipfile.ZipFile(path,'w') as z:
  z.writestr('mimetype','application/epub+zip')
  z.writestr('META-INF/container.xml','<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>')
  nav='<item id="nav" href="nav.xhtml" properties="nav" media-type="application/xhtml+xml"/>' if not ncx else '<item id="nav" href="toc.ncx" media-type="application/x-dtbncx+xml"/>'
  z.writestr('OPS/book.opf','<package unique-identifier="id" xmlns:dc="http://purl.org/dc/elements/1.1/"><metadata><dc:identifier id="id">urn:uuid:12345678-1234-1234-1234-123456789abc</dc:identifier><dc:title>EPUB测试图书</dc:title><dc:creator>测试作者</dc:creator></metadata><manifest>'+nav+'<item id="a" href="text/a.xhtml" media-type="application/xhtml+xml"/><item id="b" href="text/b.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="a"/><itemref idref="b"/></spine></package>')
  z.writestr('OPS/nav.xhtml','<html xmlns:epub="http://www.idpf.org/2007/ops"><body><nav epub:type="toc"><ol><li><a href="text/a.xhtml">第一章</a><ol><li><a href="text/b.xhtml#sub">第二章</a></li></ol></li></ol></nav></body></html>')
  z.writestr('OPS/toc.ncx','<ncx><navMap><navPoint><navLabel><text>第一章</text></navLabel><content src="text/a.xhtml"/><navPoint><navLabel><text>第二章</text></navLabel><content src="text/b.xhtml#sub"/></navPoint></navPoint></navMap></ncx>')
  for f,text in [('a','第一章内容'),('b','第二章内容')]:z.writestr('OPS/text/'+f+'.xhtml','<html xmlns="http://www.w3.org/1999/xhtml"><head><title>章节</title></head><body><h1 id="sub">'+text+'</h1><p>EPUB text fixture.</p></body></html>')

def main():
 checks=[]
 with tempfile.TemporaryDirectory(prefix='readerlab-new-formats-') as t:
  root=Path(t);b=io.BytesIO();Image.new('RGB',(64,96),'white').save(b,'PNG');image=b.getvalue()
  members=[('000001.pdg',bytes(header(0,len(image)))+image),('000002.pdg',bytes(header(0,len(image)))+image),('BookInfo.dat','书名=PDZ测试图书\nSS号=12345678'.encode()),('contents.dat','章节|01|1|0|6'.encode())]
  for ver,legacy in [(b'1.00',False),(b'1.01',False),(b'1.00',True),(b'1.01',True)]:
   source=root/'book.pdz';source.write_bytes(pdz(members,version=ver,legacy=legacy));before=source.read_bytes()
   got=run('--verify',source);assert got['pageCount']==got['renderedPages']==2 and got['metadata']['书名']=='PDZ测试图书'
   assert source.read_bytes()==before;checks.append('PDZ '+ver.decode()+(' legacy' if legacy else '')+' read and render')
  source.write_bytes(pdz(members,expiry='2000-01-01'));run('--inspect',source,ok=False);checks.append('Expired PDZ certificate rejected')
  source.write_bytes(pdz(members));broken=bytearray(source.read_bytes());broken[60]^=1;source.write_bytes(broken);run('--inspect',source,ok=False);checks.append('PDZ CRC damage rejected')
  for ncx in [False,True]:
   path=root/'book.epub';epub(path,ncx)
   got=run('--epub-inspect',path);assert got['title']=='EPUB测试图书' and len(got['spine'])==2 and [c['level'] for c in got['chapters']]==[0,1],got
   checks.append('EPUB '+('2 NCX' if ncx else '3 nav')+' spine and nested contents')
  # The reference text-PDG pair layout differs from image-PDG's layout.
  pairs=[(267,250),(94,280),(1,2),(65,1),(267,132),(193,86),(504,79),(77,65),(5,158),(473,145),(489,175),(37,13)]
  expected=simple_pdf().ljust(8181,b' ');compressed=zlib.compress(expected,level=0);assert len(compressed)==8192
  for typ,(changed,amount) in zip(range(0x11,0x1d),pairs):
   payload=bytearray(compressed);low,high=sorted((changed,amount))
   if typ<=0x14 and changed!=amount:
    delta=19 if high-low==17 else 17
    payload[low]=compressed[high]^compressed[low+delta]
    payload[high]=compressed[low]^compressed[high+delta]
   elif typ<=0x18 and changed!=amount:
    mask=payload[low]^payload[high]
    payload[low+1:high]=bytes(b^mask for b in payload[low+1:high][::-1])
   elif typ>=0x19:
    middle=(changed>>1)+(amount>>1)
    payload[changed]=((payload[changed]+amount)&255)^(payload[middle] if middle!=changed else 0)
   h=header(typ,len(payload),64,96,text=True);struct.pack_into('<H',h,94,17)
   path=root/'text.pdg';path.write_bytes(h+payload);dest=root/'text.pdf'
   run('--decode-page',path,dest);assert dest.read_bytes()==expected
   checks.append('Text PDG '+hex(typ)+' byte match')
  from test_decoder_extended import series_encode
  for typ in [0xaa,0xab,0xac]:
   h=header(typ,len(compressed),64,96,text=True)
   if typ==0xaa:seeds=[8520200,19005960,8409144,9568776]
   elif typ==0xab:seeds=[struct.unpack_from('<I',h,at)[0]^k for at,k in zip([12,16,20,24],[0x820208,0x1220208,0x805038,0x920208])]
   else:seeds=[struct.unpack_from('<I',h,at)[0]^k for at,k in zip([32,36,40,44],[0x820208,0x1220208,0x805038,0x920208])]
   payload=series_encode(compressed,seeds)
   if typ==0xab:h[16:18],h[18:20]=h[18:20],h[16:18]
   if typ==0xac:struct.pack_into('<HH',h,16,164,1096)
   h[56:58]=b'\1\x86';payload=series_encode(payload,[850670129,941241401,8414468,9568772])
   struct.pack_into('<H',h,16,struct.unpack_from('<H',h,16)[0]+49)
   path=root/'text-series.pdg';path.write_bytes(h+payload);dest=root/'text-series.pdf'
   run('--decode-page',path,dest);assert dest.read_bytes()==expected
   checks.append('Text PDG '+hex(typ)+' preprocessing byte match')
  # JPEG rectangle placed on a white PDG background.
  jpg=io.BytesIO();Image.new('RGB',(10,20),'red').save(jpg,'JPEG')
  h=header(0,len(image),64,96);h[21]=1;struct.pack_into('<I',h,24,160)
  table=struct.pack('<I4H2I',1,4,6,14,26,160+len(image),len(jpg.getvalue()))
  path=root/'layer.pdg';path.write_bytes(h+table+image+jpg.getvalue());output=root/'layer.png'
  run('--render-page',path,1,output)
  with Image.open(output) as result:
   assert result.size==(64,96)
   red=result.convert('RGB').getpixel((8,10));white=result.convert('RGB').getpixel((40,50))
   assert red[0]>230 and red[1]<30 and red[2]<30 and min(white)>240,(red,white)
  checks.append('Layered PDG JPEG rectangle and page orientation')
  # Large print sheet with an offset finished-page crop box.
  buf=io.BytesIO();c=canvas.Canvas(buf,pagesize=(3200,1000));c.setFillColorRGB(1,0,0);c.rect(2000,100,500,800,fill=1,stroke=0);c.showPage();c.save()
  page=PdfReader(io.BytesIO(buf.getvalue())).pages[0];page.cropbox.lower_left=(2000,100);page.cropbox.upper_right=(2500,900)
  writer=PdfWriter();writer.add_page(page);path=root/'crop.pdf'
  with path.open('wb') as out:writer.write(out)
  output=root/'crop.png';run('--render-page',path,1,output)
  with Image.open(output) as im:
   assert im.size==(1500,2400),im.size
   rgb=im.convert('RGB').getpixel((750,1200));assert rgb[0]>240 and rgb[1]<20 and rgb[2]<20,rgb
  checks.append('Offset PDF crop box fills OCR image without printer-sheet whitespace')
  tools=ROOT/'.build/DjVuTools'
  im=Image.new('RGB',(64,96),'white');im.save(root/'photo.ppm')
  subprocess.run([str(tools/'c44'),str(root/'photo.ppm'),str(root/'photo.djvu')],check=True,capture_output=True)
  djvu=(root/'photo.djvu').read_bytes();outcomes=[]
  for typ in [0,5]:
   path=root/f'plain-{typ}.pdg';path.write_bytes(header(typ,len(djvu))+djvu)
   dest=root/f'plain-{typ}.png';run('--render-page',path,1,dest)
   with Image.open(dest) as image:outcomes.append(image.convert('RGB').tobytes())
  assert outcomes[0]==outcomes[1]
  checks.append('Plaintext type-5 DjVu is not decrypted twice')
 print(json.dumps(dict(passed=len(checks),checks=checks),ensure_ascii=False,indent=2))
if __name__=='__main__':main()
