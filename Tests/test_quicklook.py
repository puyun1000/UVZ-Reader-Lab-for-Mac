"""Requires a registered UVZ Reader Lab thumbnail extension. Optional argument: real UVZ/ZIP sample. All writes use .build/QuickLookTests."""
from pathlib import Path
import hashlib,io,json,shutil,struct,subprocess,sys,zipfile,zlib
from PIL import Image
from pypdf import PdfWriter
from pypdf.generic import DecodedStreamObject,NameObject
root=Path(__file__).resolve().parents[1];folder=root/'.build/QuickLookTests';folder.mkdir(parents=True,exist_ok=True);checks=[]
client=folder/'ThumbnailClient'
subprocess.run(['xcrun','swiftc',str(root/'QuickLook/Tests/ThumbnailClient.swift'),'-framework','AppKit','-framework','QuickLookThumbnailing','-o',str(client)],check=True)
def png(color):
 stream=io.BytesIO();Image.new('RGB',(400,600),color).save(stream,'PNG');return stream.getvalue()
def archive(name,entries):
 path=folder/(name+'.uvz')
 with zipfile.ZipFile(path,'w',zipfile.ZIP_DEFLATED) as out:
  for key,data in entries:out.writestr(key,data)
 return path
cases=[]
cases.append((archive('cover-priority08',[('000001.pdg',png('blue')),('cov001.pdg',png('red'))]),(255,0,0)))
cases.append((archive('first-page08',[('000001.pdg',png('#207769'))]),(32,119,105)))
cases.append((archive('valid-second-cover08',[('cov000.pdg',b'broken'),('cov001.pdg',png('green'))]),(0,128,0)))
writer=PdfWriter();page=writer.add_blank_page(width=400,height=600);stream=DecodedStreamObject();stream.set_data(b'1 0 0 rg 0 0 400 600 re f');page[NameObject('/Contents')]=writer._add_object(stream);pdf=io.BytesIO();writer.write(pdf)
packed=zlib.compress(pdf.getvalue());head=bytearray(140);head[:4]=b'HH\x02F';struct.pack_into('<II',head,24,140,len(packed))
cases.append((archive('text-pdg08',[('cov001.pdg',head+packed)]),(255,0,0)))
for path,color in cases:
 before=hashlib.sha256(path.read_bytes()).hexdigest();stat=path.stat();out=path.with_suffix('.png')
 r=subprocess.run([str(client),str(path),str(out)],capture_output=True,text=True,timeout=30);assert r.returncode==0,(path,r.stdout,r.stderr)
 with Image.open(out) as im:
  assert im.width<im.height and max(im.size)<=800
  pixel=im.convert('RGB').getpixel((im.width//2,im.height//2));assert all(abs(a-b)<=3 for a,b in zip(pixel,color)),(pixel,color)
 assert hashlib.sha256(path.read_bytes()).hexdigest()==before and path.stat().st_mtime_ns==stat.st_mtime_ns
 checks.append(path.stem+': system thumbnail, correct cover/color and ratio; source unchanged')
for name,data in [('corrupt08',b'broken'),('empty08',None)]:
 path=folder/(name+'.uvz')
 if data:path.write_bytes(data)
 else:archive(name,[('readme.txt',b'no pages')])
 r=subprocess.run([str(client),str(path),str(path.with_suffix('.png'))],capture_output=True,text=True,timeout=30);assert r.returncode!=0,(path,r.stdout,r.stderr)
 checks.append(name+': unsupported or damaged input returns no thumbnail')
if len(sys.argv)>1:
 source=Path(sys.argv[1]);real=folder/'real-book.uvz';shutil.copyfile(source,real)
 before=hashlib.sha256(real.read_bytes()).hexdigest();stat=real.stat()
 r=subprocess.run([str(client),str(real),str(folder/'real-thumbnail.png')],capture_output=True,text=True,timeout=30);assert r.returncode==0,(r.stdout,r.stderr)
 assert hashlib.sha256(real.read_bytes()).hexdigest()==before and real.stat().st_mtime_ns==stat.st_mtime_ns
 checks.append('Real book: system cover thumbnail; source unchanged')
report=dict(passed=len(checks),checks=checks,thumbnailExtension='local.uvzreaderlab.rebuild.thumbnail',systemAPI='QLThumbnailGenerator')
(folder/'thumbnail-report08.json').write_text(json.dumps(report,ensure_ascii=False,indent=2));print(json.dumps(report,ensure_ascii=False,indent=2))
