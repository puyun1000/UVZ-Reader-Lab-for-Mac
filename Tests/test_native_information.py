from pathlib import Path
import subprocess,json,shutil,tempfile,hashlib,os
from pypdf import PdfWriter,PdfReader
r=Path(__file__).resolve().parents[1];exe=r/'UVZ Reader Lab.app/Contents/MacOS/UVZReaderLab';helper=r/'UVZ Reader Lab.app/Contents/Helpers/djvused';checks=[]
def run(*args,ok=True):
 p=subprocess.run([str(exe),*map(str,args)],capture_output=True,text=True,timeout=120)
 if ok:assert p.returncode==0,p.stderr;return json.loads(p.stdout) if p.stdout.strip() else None
 assert p.returncode!=0;return p.stderr
with tempfile.TemporaryDirectory(prefix='uvz-native013-') as td:
 f=Path(td)
 for ext in ['pdf','djvu']:
  src=f/('original.'+ext)
  if ext=='djvu':
   import tarfile
   with tarfile.open(r/'ThirdParty/DjVuLibre/djvulibre-3.5.30.tar.gz') as tar: src.write_bytes(tar.extractfile('djvulibre-3.5.30/doc/djvulibre-book-en.djvu').read())
  if ext=='pdf':
   from reportlab.pdfgen import canvas
   c=canvas.Canvas(str(src),pagesize=(320,480));c.setTitle('Original Title');c.setAuthor('Original Author')
   c.bookmarkPage('first');c.addOutlineEntry('Original chapter','first')
   for page in range(3):
    c.setFillColorRGB(page/3,0.3,0.6);c.rect(20,20,160,180,fill=1);c.setFillColorRGB(0,0,0);c.drawString(30,430,'Text page '+str(page+1));c.linkURL('https://example.com',(20,20,100,70));c.showPage()
   c.save();pdf=PdfReader(src);n=len(pdf.pages);outline=pdf.outline
   streams=[p.get_contents().get_data() for p in pdf.pages];texts=[p.extract_text() for p in pdf.pages]
   render=f/'before.png';run('--render-page',src,1,render);pixels=render.read_bytes()
  else:
   text=subprocess.check_output([str(helper),'-u','-e','print-pure-txt; print-outline',str(src)])
  vals={'书名':'繁體書名','作者':'張明','出版社':'中華書局','丛书名':'研究文庫','出版日期':'2020.04','ISBN':'9780306406157','未知字段':'保留"引号"与反斜线\\'}
  os.utime(src,(1500000000,1500000000));born=src.stat().st_birthtime
  plan=f/'plan.json';plan.write_text(json.dumps(dict(stem='更改名字',metadata=vals),ensure_ascii=False))
  dest=Path(run('--update-information',src,plan)['path'])
  assert not src.exists() and not Path(str(dest)+'.uvzmeta').exists()
  assert run('--inspect',dest)['metadata']==vals
  assert dest.stat().st_mtime==1500000000 and abs(dest.stat().st_birthtime-born)<0.001
  if ext=='pdf':
   after=PdfReader(dest);assert len(after.pages)==n and [p.extract_text() for p in after.pages]==texts
   assert after.outline[0].title==outline[0].title and all(len(p['/Annots'])==1 for p in after.pages)
   run('--render-page',dest,1,f/'after.png');assert (f/'after.png').read_bytes()==pixels
   checks.append('PDF text, annotations, original outline and rendered pixels preserved')
  else:assert subprocess.check_output([str(helper),'-u','-e','print-pure-txt; print-outline',str(dest)]).lstrip(b'\n\f')==text.lstrip(b'\n\f')
  checks.append(ext+' simultaneously saves all Unicode fields and name, retains dates and document structure, no sidecar')
  # Standard fields edited by another application override the app's extended snapshot.
  external=f/('external.'+ext);shutil.copy2(dest,external)
  if ext=='pdf':
   original=PdfReader(external);writer=PdfWriter();writer.clone_document_from_reader(original);writer.add_metadata({'/Title':'External title'});writer.write(external)
  else:
   import re
   raw=subprocess.check_output([str(helper),'-u','-e','select; print-meta',str(external)]).decode()
   raw=re.sub(r'(?m)^title\t.*$', 'title\t"External title"',raw)
   script=f/'external.dsed';script.write_text('select; set-meta\n'+raw+'\n.\n')
   subprocess.run([str(helper),'-u','-f',str(script),'-s',str(external)],check=True)
  assert run('--inspect',external)['metadata']['书名']=='External title';checks.append(ext+' reads standard field changes made by another application')
  # Legacy information-only companion is migrated into the document and removed.
  legacy=Path(str(dest)+'.uvzmeta');legacy.mkdir();(legacy/'BookInfo.dat').write_text('书名=舊版標題\n自定义=舊版資料')
  loaded=run('--inspect',dest)['metadata'];assert loaded['书名']=='舊版標題';plan.write_text(json.dumps(dict(stem=dest.stem,metadata=loaded),ensure_ascii=False));run('--update-information',dest,plan)
  assert not legacy.exists() and run('--inspect',dest)['metadata']['自定义']=='舊版資料'
  checks.append(ext+' migrates legacy information-only sidecar without loss')
  # Existing directory edits and unknown companion files survive migration and renaming.
  legacy.mkdir();(legacy/'BookInfo.dat').write_text('书名=旧旁存');(legacy/'Bookcontents.dat').write_text('目录|01|1|0|6\r\n');(legacy/'user-note.txt').write_text('keep')
  loaded=run('--inspect',dest)['metadata'];plan.write_text(json.dumps(dict(stem='迁移目录',metadata=loaded),ensure_ascii=False));new=Path(run('--update-information',dest,plan)['path']);side=Path(str(new)+'.uvzmeta')
  assert (side/'user-note.txt').read_text()=='keep' and not (side/'Bookcontents.dat').exists() and not (side/'BookInfo.dat').exists()
  assert run('--inspect',new)['chapters']==[dict(title='目录',page=1,level=0)]
  assert run('--inspect',new)['metadata']['书名']=='旧旁存';checks.append(ext+' retains pre-existing directory edits and user files; no metadata sidecar remains')
  before=new.read_bytes();plan.write_text(json.dumps(dict(stem='迁移目录',metadata=loaded),ensure_ascii=False));run('--update-information',new,plan,'--backup');assert any(x.read_bytes()==before for x in f.glob(new.name+'.backup-*'));checks.append(ext+' explicit backup stores the pre-edit document')
 # Independent tools see standard PDF keys, while every custom field round-trips natively.
 dest=f/'迁移目录.pdf';assert PdfReader(dest).metadata.title=='旧旁存';checks.append('PDF standard Title is visible outside the app')
 # Encrypted input cannot silently lose encryption during saving.
 enc=f/'encrypted.pdf';w=PdfWriter();w.add_blank_page(200,300);w.encrypt('');w.write(enc);before=enc.read_bytes();plan.write_text(json.dumps(dict(stem='encrypted-rename',metadata={'书名':'x'})))
 run('--update-information',enc,plan,ok=False);assert enc.read_bytes()==before and not (f/'encrypted-rename.pdf').exists();checks.append('encrypted PDF rejected without changing or renaming the original')
 assert not list(f.glob('.uvz-info-*'));checks.append('all transaction temporary files removed')
print(json.dumps(dict(passed=len(checks),checks=checks),ensure_ascii=False,indent=2))
