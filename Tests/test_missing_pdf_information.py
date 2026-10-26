"""Missing /Info regression: only disposable copies are saved or renamed.

Pass --source PATH to repeat the same transaction on a real PDF without
modifying it. No source path or page text is included in the report.
"""
from pathlib import Path
import hashlib, json, os, shutil, subprocess, sys, tempfile
from pypdf import PdfReader, PdfWriter
from reportlab.pdfgen import canvas
from PIL import Image
ROOT=Path(__file__).resolve().parents[1]
EXE=ROOT/'UVZ Reader Lab.app/Contents/MacOS/UVZReaderLab'
def run(*args,ok=True):
 p=subprocess.run([str(EXE),*map(str,args)],capture_output=True,text=True,timeout=240)
 if ok:
  assert p.returncode==0,p.stderr
  return json.loads(p.stdout) if p.stdout.strip() else None
 assert p.returncode!=0
 return p.stderr

def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def outline(r):
 out=[]
 def visit(xs,level=0):
  for x in xs:
   if isinstance(x,list):visit(x,level+1)
   else:out.append((x.title,r.get_destination_page_number(x),level))
 visit(r.outline);return out

def main():
 checks=[]
 with tempfile.TemporaryDirectory(prefix='uvz-no-info-') as td:
  root=Path(td);sample=root/'origin.pdf'
  if '--source' in sys.argv:
   source=Path(sys.argv[sys.argv.index('--source')+1]);identity=(digest(source),source.stat().st_mtime_ns,source.stat().st_birthtime)
   shutil.copy2(source,sample)
  else:
   c=canvas.Canvas(str(sample),pagesize=(320,480));c.bookmarkPage('first');c.addOutlineEntry('Opening','first')
   for page in range(4):
    c.setFillColorRGB(.1*page,.2,.7);c.rect(30,30,100+page*10,200,fill=True);c.drawString(30,440,'Semantic text '+str(page))
    c.linkURL('https://example.com',(30,30,130,230));c.showPage()
   c.save();w=PdfWriter();w.clone_document_from_reader(PdfReader(sample));w._info=None;w.write(sample)
  before=PdfReader(sample);assert before.metadata is None
  count=len(before.pages);selected=sorted(set([0,min(1,count-1),min(36,count-1),count-1]))
  structure=[(tuple(p.mediabox),p.get('/Rotate',0),len(p.get('/Annots',[])),p.extract_text()) for p in before.pages]
  chapters=outline(before);pixels={}
  for i in selected:
   p=root/f'before-{i}.png';run('--render-page',sample,i+1,p);pixels[i]=Image.open(p).convert('RGB').tobytes()
  for filename in ['scan_9780306406157_31f49ccbXXXX.pdf','short.pdf']:
   working=root/filename;shutil.copy2(sample,working);os.utime(working,(1500000000,1500000000));birth=working.stat().st_birthtime
   for step,stem in enumerate([working.stem,'renamed-'+working.stem]):
    values={'书名':'繁體書名：近代史','作者':'作者甲','丛书名':'史料文庫','出版社':'出版社乙','出版日期':'2020.05','页数':str(count),'ISBN':'9780306406157','SS号':'','DX号':'','摘要':'摘要第二次' if step else '摘要第一次','自定义':'引号"与反斜线\\'}
    plan=root/'plan.json';plan.write_text(json.dumps(dict(stem=stem,metadata=values),ensure_ascii=False))
    previous=working;working=Path(run('--update-information',working,plan)['path'])
    assert working.exists() and (previous==working or not previous.exists())
    if step==0:assert working.read_bytes().startswith(sample.read_bytes()),'original PDF byte stream must remain verbatim'
    assert run('--inspect',working)['metadata']==values
    after=PdfReader(working)
    assert len(after.pages)==count and outline(after)==chapters
    assert [(tuple(p.mediabox),p.get('/Rotate',0),len(p.get('/Annots',[])),p.extract_text()) for p in after.pages]==structure
    assert after.metadata.title==values['书名'] and after.metadata['/ISBN']==values['ISBN']
    assert working.stat().st_mtime==1500000000 and abs(working.stat().st_birthtime-birth)<.001
    assert not Path(str(working)+'.uvzmeta').exists()
    for i in selected:
     p=root/f'after-{i}.png';run('--render-page',working,i+1,p);assert Image.open(p).convert('RGB').tobytes()==pixels[i]
    checks.append(('ISBN/hash filename' if filename.startswith('scan') else 'short filename')+f': transaction {step+1}, native fields, rename, outlines, annotations, text, dates and rendered pixels')
  if '--source' not in sys.argv:
   objects=[b'<< /Type /Catalog /Pages 2 0 R >>',b'<< /Type /Pages /Count 1 /Kids [3 0 R] >>',b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 320 480] /Contents 4 0 R /Resources << >> >>',b'<< /Length 0 >>\nstream\n\nendstream']
   raw=bytearray(b'%PDF-1.5\n');offsets=[0]
   for i,obj in enumerate(objects,1):offsets.append(len(raw));raw.extend(f'{i} 0 obj\n'.encode()+obj+b'\nendobj\n')
   start=len(raw);offsets.append(start);xref=b'\x00'+bytes(6)+b''.join(b'\x01'+n.to_bytes(4,'big')+bytes(2) for n in offsets[1:])
   raw.extend(f'5 0 obj\n<< /Type /XRef /Size 6 /Root 1 0 R /W [1 4 2] /Length {len(xref)} >>\nstream\n'.encode()+xref+f'\nendstream\nendobj\nstartxref\n{start}\n%%EOF\n'.encode())
   for inherited in [False,True]:
    data=bytes(raw)
    if inherited:
     at=len(data);data+=f'6 0 obj\nnull\nendobj\nxref\n6 1\n{at:010d} 00000 n \ntrailer\n<< /Size 7 /Root 1 0 R /Prev {start} >>\nstartxref\n{at+20}\n%%EOF\n'.encode()
    path=root/('inherited.pdf' if inherited else 'xref-stream.pdf');path.write_bytes(data)
    plan.write_text(json.dumps(dict(stem=path.stem,metadata={'书名':'信息字典测试','摘要':'摘要测试'}),ensure_ascii=False))
    run('--update-information',path,plan)
    assert path.read_bytes().startswith(data)
    assert PdfReader(path).metadata.title=='信息字典测试'
    checks.append('missing Info: '+('incremental revision and xref stream' if inherited else 'xref stream'))
  conversion=root/'conversion.pdf';run('--convert-pdf',sample,conversion)
  assert PdfReader(conversion).metadata.title and run('--inspect',conversion)['metadata'].get('书名')
  checks.append('PDF conversion also retains new information when the source has no Info dictionary')
  assert not list(root.glob('.uvz-*'));checks.append('no transaction debris or new metadata sidecars')
  if '--source' in sys.argv:
   assert identity==(digest(source),source.stat().st_mtime_ns,source.stat().st_birthtime);checks.append('real source digest and dates unchanged')
  print(json.dumps(dict(passed=len(checks),pages=count,renderedSamples=len(selected),checks=checks),ensure_ascii=False,indent=2))
if __name__=='__main__':main()
