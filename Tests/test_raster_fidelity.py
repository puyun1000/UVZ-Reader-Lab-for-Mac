"""Pixel/DPI/orientation regression with generated raster and DjVu layers only."""
from pathlib import Path
import io,json,struct,subprocess,tempfile,zipfile,hashlib
from PIL import Image,ImageDraw,ImageOps,ImageChops,ImageStat
from pypdf import PdfReader
r=Path(__file__).resolve().parents[1];exe=r/'UVZ Reader Lab.app/Contents/MacOS/UVZReaderLab';tools=r/'.build/DjVuTools';checks=[]
def run(*args,ok=True):
 p=subprocess.run([str(exe),*map(str,args)],capture_output=True,text=True,timeout=90)
 assert (p.returncode==0)==ok,(args,p.stderr)
 return (json.loads(p.stdout) if p.stdout.strip() else None) if p.returncode==0 else p.stderr
def chunk(name,data):return name.encode()+struct.pack('>I',len(data))+data+b'\0'*(len(data)%2)
def chunks(data):
 at=16;out=[]
 while at<len(data):
  n=data[at:at+4].decode();size=struct.unpack_from('>I',data,at+4)[0];out.append((n,data[at+8:at+8+size]));at+=8+size+(size&1)
 return out
def djvu(layers,w=512,h=640,dpi=300,flags=1):
 info=struct.pack('>HH',w,h)+b'\x18\0'+struct.pack('<H',dpi)+bytes([22,flags]);body=b'DJVU'+chunk('INFO',info)+b''.join(chunk(n,b) for n,b in layers)
 return b'AT&TFORM'+struct.pack('>I',len(body))+body
def wrap(data,version=2):
 h=bytearray(140 if version==2 else 56);h[:3]=b'HH'+bytes([version]);struct.pack_into('<I',h,28,len(data))
 if version==2:h[20]=24;struct.pack_into('<I',h,24,140)
 return bytes(h)+data
def mae(a,b):
 assert a.size==b.size,(a.size,b.size)
 return max(ImageStat.Stat(ImageChops.difference(a.convert('RGB'),b.convert('RGB'))).mean)
def rgbflip(im):
 a=ImageOps.flip(im.convert('RGB'));rr,g,b=a.split();return Image.merge('RGB',(b,g,rr))
with tempfile.TemporaryDirectory(prefix='uvz-raster-') as td:
 f=Path(td);im=Image.new('RGB',(512,640),'white');d=ImageDraw.Draw(im)
 for box,color in [((0,0,256,320),'red'),((256,0,512,320),'green'),((0,320,256,640),'blue'),((256,320,512,640),'yellow')]:d.rectangle(box,fill=color)
 d.rectangle((22,14,230,65),fill='black');d.rectangle((34,20,54,55),fill='white')
 def raster(name,data):
  p=f/(name+'.pdg');p.write_bytes(data);png=f/(name+'.png');run('--render-page',p,1,png);return p,Image.open(png).convert('RGB')
 def iw(image,name):
  p=f/(name+'.ppm');image.save(p,'PPM');out=f/(name+'.djvu');subprocess.run([str(tools/'c44'),'-dpi','300',str(p),str(out)],check=True,capture_output=True)
  return [(n,b) for n,b in chunks(out.read_bytes()) if n=='BG44']
 for mode,progressive in [('RGB',False),('RGB',True),('L',False)]:
  b=io.BytesIO();im.convert(mode).save(b,'JPEG',quality=96,progressive=progressive);jpeg=b.getvalue();p,actual=raster('jpeg-'+mode+str(progressive),djvu([('BGjp',jpeg)]))
  assert actual.size==(512,640) and mae(actual,Image.open(io.BytesIO(jpeg)))<3
  _,direct=raster('direct-'+mode+str(progressive),jpeg);assert mae(direct,Image.open(io.BytesIO(jpeg)))<3
  checks.append('BGjp '+mode+(' progressive' if progressive else '')+': native pixels and independently decoded JPEG colours')
 # Do not confuse a legitimate blank page with a failed decoder.
 b=io.BytesIO();Image.new('RGB',(512,640),'white').save(b,'JPEG');_,actual=raster('blank',djvu([('BGjp',b.getvalue())]));assert min(actual.getextrema()[0])==255;checks.append('valid blank JPEG layer remains readable')
 b=io.BytesIO();im.save(b,'JPEG',quality=97);jpeg=b.getvalue()
 for dpi in [150,300,600]:
  p=f/('dpi-'+str(dpi)+'.djvu');p.write_bytes(djvu([('BGjp',jpeg)],dpi=dpi));out=p.with_suffix('.pdf');result=run('--convert-pdf',p,out);pdf=PdfReader(out);image=pdf.pages[0].images[0].image
  assert image.size==(512,640) and result['fallbackDPIPages']==0
  assert abs(float(pdf.pages[0].mediabox.width)-512*72/dpi)<.01 and abs(float(pdf.pages[0].mediabox.height)-640*72/dpi)<.01
  checks.append('DjVu '+str(dpi)+' dpi: PDF image pixels and physical page size preserved')
 # A standard source and a DIB-convention source encode the same visible picture independently.
 normal=iw(im,'normal');legacy=iw(rgbflip(im),'legacy')
 for flags in [1,2,5,6]:
  _,expected=raster('standard-'+str(flags),djvu(normal,flags=flags));p,actual=raster('superstar-'+str(flags),wrap(djvu(legacy,flags=flags)))
  assert mae(actual,expected)<6,(flags,mae(actual,expected))
  out=p.with_suffix('.pdf');run('--convert-pdf',p,out);pdf=PdfReader(out);assert pdf.pages[0].images[0].image.size==actual.size
  assert mae(pdf.pages[0].images[0].image,actual)<.1
  checks.append('V2 BG44 photo INFO flag '+str(flags)+': upright colours and PDF raster agree')
  raw=f/('superstar-'+str(flags)+'.decoded');run('--decode-page',p,raw);assert raw.read_bytes().startswith(b'\x89PNG')
 # Provenance controls are deliberately distinct from the image content.
 for version in [0,1]:
  source=djvu(normal);p,actual=raster('standard-provenance-'+str(version),source if version==0 else wrap(source,1));decoded=p.with_suffix('.decoded');run('--decode-page',p,decoded);assert decoded.read_bytes()==source
  checks.append(('raw renamed DjVu' if version==0 else 'V1 DjVu container')+': source bytes remain standard')
 gray=im.convert('L');gray_encoded=iw(ImageOps.flip(gray),'gray-legacy');gray_normal=iw(gray,'gray-normal')
 _,expected=raster('gray-reference',djvu(gray_normal));_,actual=raster('gray-v2',wrap(djvu(gray_encoded)));assert mae(actual,expected)<3;checks.append('generated V2 grayscale photo: row order restored without a channel swap')
 mask=Image.new('1',im.size,1);ImageDraw.Draw(mask).rectangle((25,25,180,70),fill=0);mask.save(f/'mask.pbm');subprocess.run([str(tools/'cjb2'),str(f/'mask.pbm'),str(f/'mask.djvu')],capture_output=True,check=True)
 masks=[(n,b) for n,b in chunks((f/'mask.djvu').read_bytes()) if n=='Sjbz']
 b=io.BytesIO();Image.new('RGB',im.size,'white').save(b,'JPEG')
 _,foreground=raster('jpeg-foreground',djvu([('BGjp',b.getvalue())]+masks+[('FGjp',jpeg)]))
 assert min(foreground.getpixel((300,300)))>245 and foreground.getpixel((100,68))[0]>220 and foreground.getpixel((100,68))[2]<40,(foreground.getpixel((300,300)),foreground.getpixel((100,68)))
 checks.append('FGjp plus JB2 mask: foreground JPEG is composed over the white background')
 for label,layers in [('bilevel',masks),('compound',normal+masks),('jpeg-layer',[('BGjp',jpeg)])]:
  source=djvu(layers);_,expected=raster(label+'-reference',source);p,actual=raster(label+'-v2',wrap(source));assert mae(actual,expected)==0
  decoded=p.with_suffix('.decoded');run('--decode-page',p,decoded);assert decoded.read_bytes()==source;checks.append('V2 '+label+': no photo-only correction applied')
 # Explicit failures must never produce a white success page or a committed PDF.
 bads=[('BG2k',[('BG2k',b'unknown')],512,640),('FG2k',[('FG2k',b'unknown')],512,640),('oversized-info',[('BGjp',jpeg)],65000,65000),('truncated-jpeg',[('BGjp',jpeg[:-30])],512,640)]
 b=io.BytesIO();im.convert('CMYK').save(b,'JPEG');bads.append(('CMYK-layer',[('BGjp',b.getvalue())],512,640))
 b=io.BytesIO();Image.new('RGB',(30001,2),'red').save(b,'JPEG');bads.append(('oversized-layer',[('BGjp',b.getvalue())],512,640))
 for label,layers,w,h in bads:
  p=f/(label+'.djvu');source=djvu(layers,w,h);p.write_bytes(source);png=p.with_suffix('.png');run('--render-page',p,1,png,ok=False);assert not png.exists()
  out=p.with_suffix('.pdf');run('--convert-pdf',p,out,ok=False);assert not out.exists() and p.read_bytes()==source
  checks.append(label+': explicit error, no output image/PDF, original retained')
 thumbnail=b'fixture-thumbnail\0'+jpeg
 nested=jpeg[:2]+b'\xff\xe2'+struct.pack('>H',len(thumbnail)+2)+thumbnail+jpeg[2:]
 _,valid=raster('nested-thumbnail',nested);assert mae(valid,Image.open(io.BytesIO(jpeg)))<3
 for label,source in [('truncated-direct',jpeg[:-30]),('truncated-with-thumbnail',nested[:-30])]:
  p=f/(label+'.pdg');p.write_bytes(source)
  run('--render-page',p,1,p.with_suffix('.png'),ok=False);run('--convert-pdf',p,p.with_suffix('.pdf'),ok=False)
  assert not p.with_suffix('.png').exists() and not p.with_suffix('.pdf').exists() and p.read_bytes()==source
 checks.append('truncated direct JPEG cannot bypass integrity checks through compressed PDF pass-through')
 # Reading/OCR uses EXIF orientation; raster export must apply that orientation only once.
 for fmt in ['JPEG','TIFF']:
  for orientation in [2,3,4,5,6,7,8]:
   exif=Image.Exif();exif[274]=orientation;b=io.BytesIO();im.save(b,fmt,exif=exif);data=b.getvalue();p,actual=raster(fmt+str(orientation),data);expected=ImageOps.exif_transpose(Image.open(io.BytesIO(data))).convert('RGB');assert mae(actual,expected)<2,(fmt,orientation)
   if orientation in [2,6]:
    target=p.with_suffix('.pdf');run('--convert-pdf',p,target);rendered=p.with_suffix('.pdf.png');run('--render-page',target,1,rendered)
    # PDF raster is sampled at its page-rendering resolution. Preserve the asymmetric orientation.
    got=Image.open(rendered).convert('RGB').resize(expected.size);assert mae(got,expected)<5,(fmt,orientation,'PDF orientation')
  checks.append(fmt+': seven EXIF rotations/reflections restored for reading and OCR')
 # Photo correction must also be shared by archive reading and PDF conversion.
 p=f/'photos.uvz'
 with zipfile.ZipFile(p,'w') as z:z.writestr('cov001.pdg',wrap(djvu(legacy)));z.writestr('000001.pdg',djvu(normal))
 assert run('--verify',p)['renderedPages']==2
 result=run('--convert-pdf',p,f/'photos.pdf');assert result['outputPages']==2
 checks.append('mixed UVZ corrected/standard photo pages read and convert through shared decoder')
 assert not list(f.glob('.uvz-*'));checks.append('failed transactions leave no temporary outputs')
print(json.dumps(dict(passed=len(checks),checks=checks),indent=2))
