"""Native PDF/DjVu outline transactions and legacy directory migration."""
from pathlib import Path
import json,subprocess,tempfile,tarfile,hashlib,os
from pypdf import PdfReader, PdfWriter
from pypdf.generic import DictionaryObject, Fit, NameObject, TextStringObject
from PIL import Image
from reportlab.pdfgen import canvas
r=Path(__file__).resolve().parents[1];exe=r/'UVZ Reader Lab.app/Contents/MacOS/UVZReaderLab';checks=[]
def run(*args,ok=True):
 p=subprocess.run([str(exe),*map(str,args)],capture_output=True,text=True,timeout=180)
 assert (p.returncode==0)==ok,(args,p.stderr)
 return json.loads(p.stdout) if p.stdout and p.returncode==0 else p.stderr
with tempfile.TemporaryDirectory(prefix='uvz-native-contents-') as td:
 f=Path(td)
 chapters=[dict(title='无页码父项',page=0,level=0),dict(title='长标题：'+('文字'*60),page=1,level=1),dict(title='第三页',page=3,level=1),dict(title='后部',page=4,level=0)]
 for ext in ['pdf','djvu']:
  path=f/('book.'+ext)
  if ext=='pdf':
   c=canvas.Canvas(str(path),pagesize=(300,450));c.setTitle('Original title');c.setAuthor('Original author')
   for i in range(4):c.drawString(20,400,f'Text {i+1}');c.linkURL('https://example.com',(20,20,80,60));c.showPage()
   c.save();source_pdf=PdfReader(path);text=[p.extract_text() for p in source_pdf.pages];original_info=source_pdf.metadata
  else:
   with tarfile.open(r/'ThirdParty/DjVuLibre/djvulibre-3.5.30.tar.gz') as t:path.write_bytes(t.extractfile('djvulibre-3.5.30/doc/djvulibre-book-en.djvu').read())
  os.utime(path,(1500000000,1500000000));birth=path.stat().st_birthtime
  before=f/('before-'+ext+'.png');run('--render-page',path,1,before);pixels=Image.open(before).convert('RGB').tobytes()
  plan=f/'draft.json';plan.write_text(json.dumps(dict(chapters=chapters,metadata={'书名':'Must not be saved for contents-only'}),ensure_ascii=False))
  old=run('--inspect',path)['metadata'];original_bytes=path.read_bytes();run('--apply-draft',path,plan,'--contents-only')
  info=run('--inspect',path);assert info['chapters']==chapters and info['metadata']==old
  assert not Path(str(path)+'.uvzmeta').exists()
  assert path.stat().st_mtime==1500000000 and abs(path.stat().st_birthtime-birth)<.001
  checks.append(ext+': grouped multilingual outlines embedded, metadata/dates retained, no sidecar')
  if ext=='pdf':
   pdf=PdfReader(path);assert len(pdf.outline)==3 and pdf.get_destination_page_number(pdf.outline[1][1])==2
   assert path.read_bytes().startswith(original_bytes)
   for key in ['/Trapped','/CreationDate','/ModDate','/Creator','/Producer']:
    assert type(pdf.metadata[key]) is type(original_info[key]) and pdf.metadata[key]==original_info[key],key
   assert [p.extract_text() for p in pdf.pages]==text and all(len(p['/Annots'])==1 for p in pdf.pages)
  else:
   outline=subprocess.check_output([str(r/'UVZ Reader Lab.app/Contents/Helpers/djvused'),'-u','-e','print-outline',str(path)]).decode();assert '"#3"' in outline and '无页码父项' in outline
  run('--render-page',path,1,f/'after.png');assert Image.open(f/'after.png').convert('RGB').tobytes()==pixels
  checks.append(ext+': independent outline inspection and rendered pixels match')
  # Invalid directories cannot partly save the information dictionary.
  original=path.read_bytes();bad=dict(chapters=[dict(title='Bad target',page=100000,level=0)],metadata={'书名':'wrong'})
  plan.write_text(json.dumps(bad));run('--apply-draft',path,plan,ok=False);assert path.read_bytes()==original;checks.append(ext+': invalid directory leaves metadata and original bytes unchanged')
  # Old DAT directories are imported and retired; unrelated user files are retained.
  side=Path(str(path)+'.uvzmeta');side.mkdir();(side/'Bookcontents.dat').write_text('迁移标题|01|2|0|6\n');(side/'BookInfo.dat').write_text('书名=旧信息\n自定义=保留\n');(side/'keep.txt').write_text('user data')
  change=f/'change.json';values=run('--inspect',path)['metadata'];values['出版社']='修订出版社';change.write_text(json.dumps(dict(stem='renamed-'+ext,metadata=values),ensure_ascii=False))
  target=Path(run('--update-information',path,change)['path']);remaining=Path(str(target)+'.uvzmeta')
  assert not path.exists() and (remaining/'keep.txt').read_text()=='user data'
  assert not (remaining/'Bookcontents.dat').exists() and not (remaining/'BookInfo.dat').exists()
  assert run('--inspect',target)['chapters']==[dict(title='迁移标题',page=2,level=0)] and run('--inspect',target)['metadata']==values
  checks.append(ext+': rename migrates legacy DAT outline and information, retains unknown user files')
  # Clearing all nodes must remove native bookmarks, and explicit backup is exact.
  plan.write_text(json.dumps(dict(chapters=[],metadata={})));before=target.read_bytes();result=run('--apply-draft',target,plan,'--contents-only','--backup')
  assert any(Path(p).read_bytes()==before for p in result['backups']) and run('--inspect',target)['chapters']==[]
  checks.append(ext+': clear native directory and exact original backup')
 # A title-only edit keeps old /XYZ parameters and an external action verbatim.
 path=f/'target-types.pdf'; writer=PdfWriter()
 for _ in range(3): writer.add_blank_page(width=300,height=450)
 master=writer.add_outline_item('Original XYZ',1,fit=Fit.xyz(left=17,top=423,zoom=1.25))
 writer.add_outline_item('Original FitH',2,parent=master,fit=Fit.fit_horizontally(top=388))
 external=writer.add_outline_item('External action',None)
 external.get_object()[NameObject('/A')]=DictionaryObject({NameObject('/S'):NameObject('/URI'),NameObject('/URI'):TextStringObject('https://example.com/reference')})
 writer.set_page_label(0,0,style='/r')
 with path.open('wb') as stream:writer.write(stream)
 raw=path.read_bytes()
 plan.write_text(json.dumps(dict(chapters=[dict(title='Renamed XYZ',page=2,level=0),dict(title='Original FitH',page=3,level=1),dict(title='External action',page=0,level=0)],metadata={})))
 run('--apply-draft',path,plan,'--contents-only')
 original=PdfReader(path); outline=original.trailer['/Root']['/Outlines']['/First']
 assert path.read_bytes().startswith(raw) and original.page_labels[0]=='i'
 assert original.outline[0]['/Title']=='Renamed XYZ'
 assert list(outline['/A']['/D'][1:])==['/XYZ',17,423,1.25]
 assert list(outline['/First']['/A']['/D'][1:])==['/FitH',388]
 assert outline['/Next']['/A']['/URI']=='https://example.com/reference'
 checks.append('PDF title-only editing preserves XYZ, FitH, external action and PageLabels')
 assert not list(f.glob('.uvz-*'));checks.append('all native directory transaction scratch files removed')
print(json.dumps(dict(passed=len(checks),checks=checks),ensure_ascii=False,indent=2))
