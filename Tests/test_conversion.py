"""PDF conversion, identity mapping and source/target safety on disposable fixtures."""
from pathlib import Path
import io,json,subprocess,tempfile,zipfile,hashlib,tarfile,shutil
from PIL import Image
from pypdf import PdfReader,PdfWriter
from reportlab.pdfgen import canvas
R=Path(__file__).resolve().parents[1];EXE=R/'UVZ Reader Lab.app/Contents/MacOS/UVZReaderLab'
def run(source,target,*flags,ok=True):
 p=subprocess.run([str(EXE),'--convert-pdf',str(source),str(target),*flags],capture_output=True,text=True,timeout=180)
 if ok:assert p.returncode==0,p.stderr;return json.loads(p.stdout)
 assert p.returncode!=0,(p.stdout,p.stderr);return p.stderr

def image(mode,color,fmt='JPEG',orientation=1):
 im=Image.new(mode,(120,180),color);b=io.BytesIO();e=Image.Exif();e[274]=orientation
 im.save(b,fmt,dpi=(200,200),exif=e);return b.getvalue()
def archive(path,pages,meta=None,contents=None):
 with zipfile.ZipFile(path,'w',zipfile.ZIP_DEFLATED) as z:
  for name,data in pages.items():z.writestr('书籍/'+name,data)
  if meta is not None:z.writestr('书籍/BookInfo.dat','\r\n'.join(k+'='+v for k,v in meta.items()).encode())
  if contents is not None:z.writestr('书籍/Bookcontents.dat',contents.encode())
def outlines(pdf):
 result=[]
 def visit(items):
  for x in items:
   if isinstance(x,list):visit(x)
   else:result.append((x.title,pdf.get_destination_page_number(x)))
 visit(pdf.outline);return result

def main():
 checks=[]
 with tempfile.TemporaryDirectory(prefix='uvz-conversion-') as td:
  root=Path(td);source=root/'【研究丛书】图书_作者_出版社_2020.04_12345678.zip';target=source.with_suffix('.pdf')
  gray=image('L',128);rgb=image('RGB','red');rot=image('RGB','blue',orientation=6)
  metadata={'书名':'图书：研究','作者':'甲著','丛书名':'研究丛书','出版社':'示例出版社','出版日期':'2020.04','页数':'1','SS号':'12345678','ISBN':'9780306406157','自定义':'未知值保留'}
  archive(source,{'cov001.pdg':gray,'leg001.pdg':rgb,'000001.pdg':rot},metadata,'分组|01|0|0|0\r\n正文|0101|1|0|6\r\n')
  before=(source.read_bytes(),source.stat().st_mtime_ns,source.stat().st_birthtime)
  result=run(source,target);pdf=PdfReader(target)
  assert result['sourcePages']==result['outputPages']==result['jpegPassThrough']==3 and not result['skipped']
  assert target.name==source.with_suffix('.pdf').name;checks.append('完整源名与三页JPEG直通')
  objects=[p['/Resources']['/XObject']['/Image'].get_object() for p in pdf.pages]
  assert [x._data for x in objects]==[gray,rgb,rot] and [str(x['/ColorSpace']) for x in objects]==['/DeviceGray','/DeviceRGB','/DeviceRGB'];checks.append('逐页压缩字节与灰度RGB声明准确')
  assert tuple(float(v) for v in pdf.pages[0].mediabox[2:])==(43.2,64.8)
  assert tuple(float(v) for v in pdf.pages[2].mediabox[2:])==(64.8,43.2);checks.append('可信来源DPI与EXIF旋转页尺寸')
  info=json.loads(pdf.metadata['/UVZReaderLabMetadata']);assert info==metadata and info['页数']=='1' and len(pdf.pages)==3;checks.append('扩展书目信息保留，书目页数不混同物理页数')
  assert outlines(pdf)==[('分组',None),('正文',2)];checks.append('多级书签分组和真实物理目的页')
  assert before==(source.read_bytes(),source.stat().st_mtime_ns,source.stat().st_birthtime);assert not Path(str(source)+'.uvzmeta').exists();checks.append('转换不改来源内容日期，不新建信息旁存')
  old=target.read_bytes();run(source,target,ok=False);assert target.read_bytes()==old;checks.append('已有目标拒绝覆盖')
  run(target,target,ok=False);assert target.read_bytes()==old;checks.append('拒绝把来源PDF覆盖为自身')
  # A physical bad page is skipped only by explicit choice; destinations are remapped.
  bad=root/'坏页.zip';archive(bad,{'cov001.pdg':gray,'000001.pdg':b'corrupt','000002.pdg':rgb},metadata,'坏页目标|01|1|0|6\r\n好页目标|02|2|0|6\r\n')
  dest=root/'坏页.pdf';run(bad,dest,ok=False);assert not dest.exists() and not list(root.glob('.uvz-convert-*'));checks.append('默认坏页停止并清理临时输出')
  result=run(bad,dest,'--skip-bad');partial=Path(result['output']);pdf=PdfReader(partial)
  assert partial.name=='坏页.partial.pdf' and result['skipped']==[2] and result['outputPages']==2 and not dest.exists()
  assert outlines(pdf)==[('坏页目标',None),('好页目标',1)];checks.append('部分完成明确命名并重新映射目录，失去目标不错误跳转')
  run(bad,dest,'--skip-bad',ok=False);checks.append('部分PDF同样防覆盖')
  cancel=root/'cancel.pdf';run(source,cancel,'--cancel-after=1',ok=False);assert not cancel.exists() and not list(root.glob('.uvz-convert-*'));checks.append('逐页取消无正式结果或临时文件残留')
  # PNG/1-bit pages use lossless streams, never lossy JPEG by default.
  binary=Image.new('1',(120,180),1);binary.putpixel((10,10),0);b=io.BytesIO();binary.save(b,'PNG')
  loss=root/'无损.zip';archive(loss,{'000001.pdg':b.getvalue(),'000002.pdg':image('RGB','green','PNG')});result=run(loss,root/'无损.pdf');pdf=PdfReader(result['output'])
  x=pdf.pages[0]['/Resources']['/XObject']['/Image'].get_object();assert x['/BitsPerComponent']==1 and x['/Filter']=='/FlateDecode';assert result['losslessPages']==2;checks.append('黑白一位与彩色PNG无损输出')
  # Different TIFF frames keep their own dimensions.
  tif=root/'多页.tiff';Image.new('RGB',(60,80),'red').save(tif,save_all=True,append_images=[Image.new('RGB',(90,50),'green')],dpi=(200,200))
  result=run(tif,root/'多页.pdf');pdf=PdfReader(result['output']);assert len(pdf.pages)==2 and [int(p['/Resources']['/XObject']['/Image'].get_object()['/Width']) for p in pdf.pages]==[60,90];checks.append('多页TIFF逐帧输出而非重复首页')
  high=root/'high-depth.tiff';Image.new('I;16',(32,48),1025).save(high,dpi=(200,200))
  error=run(high,root/'high-depth.pdf',ok=False);assert '位深' in error and not (root/'high-depth.pdf').exists();checks.append('高位深图像明确拒绝，不静默降低精度')
  # Native PDF and PDF-wrapped PDG must remain searchable, rather than screenshots.
  text=root/'文字.pdf';c=canvas.Canvas(str(text),pagesize=(320,480));c.bookmarkPage('one');c.addOutlineEntry('Native chapter','one');c.drawString(30,420,'Preserve searchable text');c.linkURL('https://example.com',(30,30,100,70));c.showPage();c.drawString(30,420,'Second text page');c.linkRect('Back','one',(30,30,100,70));c.save()
  native=root/'native-out.pdf';result=run(text,native);pdf=PdfReader(native)
  assert 'Preserve searchable text' in pdf.pages[0].extract_text() and len(pdf.pages[0]['/Annots'])==1 and pdf.outline[0].title=='Native chapter';checks.append('原生PDF文字、注释与目录保留')
  mixed=root/'文字PDG.zip';archive(mixed,{'cov001.pdg':gray,'000001.pdg':text.read_bytes()},metadata,'第二页|01|2|0|6\r\n')
  result=run(mixed,root/'文字PDG.pdf');pdf=PdfReader(result['output'])
  assert len(pdf.pages)==3 and 'Preserve searchable text' in pdf.pages[1].extract_text() and 'Second text page' in pdf.pages[2].extract_text();checks.append('混合JPEG与多页文本PDG保留可搜索文字')
  assert outlines(pdf)==[('第二页',2)];checks.append('多页文本PDG目录映射按实际展开页')
  # Existing native PDF catalog stays unchanged when no metadata or override is requested.
  copy=root/'native-copy.pdf';run(text,copy,'--no-metadata');assert copy.read_bytes()==text.read_bytes();checks.append('关闭信息改写且无目录覆盖时PDF保留原始字节')
  side=Path(str(text)+'.uvzmeta');side.mkdir();(side/'Bookcontents.dat').write_text('分组|01|0|0|0\n第二页|0101|2|0|6\n')
  modified=root/'native-directory.pdf';run(text,modified);pdf=PdfReader(modified)
  assert outlines(pdf)==[('分组',None),('第二页',1)] and 'Preserve searchable text' in pdf.pages[0].extract_text()
  assert len(pdf.pages[0]['/Annots'])==1 and pdf.pages[1]['/Annots'][0].get_object()['/Dest'][0]==pdf.pages[0].indirect_reference
  checks.append('PDF目录覆盖保留分组、原文、外链与返回首页的链接')
  # Quartz must honor rotated pages and nonzero media-box origins in text PDG.
  adjusted=root/'rotated-text.pdf';writer=PdfWriter(clone_from=text)
  for page in writer.pages:page.mediabox.lower_left=(10,20);page.mediabox.upper_right=(330,500);page.rotate(90)
  writer.write(adjusted);wrapped=root/'rotated-pdg.zip';archive(wrapped,{'000001.pdg':adjusted.read_bytes()})
  adjusted_out=root/'rotated-pdg.pdf';run(wrapped,adjusted_out);pdf=PdfReader(adjusted_out)
  assert tuple(float(v) for v in pdf.pages[0].mediabox[2:])==(480,320)
  render=shutil.which('pdftoppm');assert render,'PDF rendering test dependency missing'
  for doc,prefix in [(adjusted,'before-rotation'),(adjusted_out,'after-rotation')]:
   subprocess.run([render,'-f','1','-singlefile','-r','72','-png',str(doc),str(root/prefix)],check=True,capture_output=True)
  from PIL import ImageChops,ImageStat,ImageOps
  a=Image.open(root/'before-rotation.png').convert('RGB');b=Image.open(root/'after-rotation.png').convert('RGB')
  assert a.size==b.size and max(ImageStat.Stat(ImageChops.difference(a,b)).mean)<1.5
  checks.append('文本PDG旋转与非零页面原点保持实际显示位置')
  # Check visual orientation against Pillow, rather than comparing the writer to itself.
  patch=Image.new('RGB',(120,180));patch.paste('red',(0,0,60,90));patch.paste('green',(60,0,120,90));patch.paste('blue',(0,90,60,180));patch.paste('yellow',(60,90,120,180))
  for orientation in range(1,9):
   exif=Image.Exif();exif[274]=orientation;buf=io.BytesIO();patch.save(buf,'JPEG',dpi=(72,72),exif=exif)
   book=root/f'orientation{orientation}.zip';out=root/f'orientation{orientation}.pdf';archive(book,{'000001.pdg':buf.getvalue()});run(book,out)
   subprocess.run([render,'-f','1','-singlefile','-r','72','-png',str(out),str(root/'orientation')],check=True,capture_output=True)
   expected=ImageOps.exif_transpose(Image.open(io.BytesIO(buf.getvalue())));actual=Image.open(root/'orientation.png').convert('RGB')
   assert expected.size==actual.size
   for x,y in [(0.25,0.25),(0.75,0.25),(0.25,0.75),(0.75,0.75)]:
    point=(int(x*actual.width),int(y*actual.height));assert max(abs(a-b) for a,b in zip(expected.getpixel(point),actual.getpixel(point)))<6
  checks.append('八种EXIF方向与独立图像解码结果逐象限核对')
  fallback_source=root/'缺少信息_12345678.zip';archive(fallback_source,{'000001.pdg':gray})
  fallback_out=root/'fallback-info.pdf';run(fallback_source,fallback_out);pdf=PdfReader(fallback_out)
  assert json.loads(pdf.metadata['/UVZReaderLabMetadata'])['SS号']=='12345678';checks.append('BookInfo缺SS号时沿用单书窗口的文件名回退')
  plain=root/'无信息.pdf';result=run(source,plain,'--no-bookmarks','--no-metadata');pdf=PdfReader(plain);assert not pdf.outline and '/Title' not in pdf.metadata and json.loads(pdf.metadata['/UVZReaderLabMetadata'])=={};checks.append('可明确关闭新PDF的元数据与书签')
  # Reject invalid options before output creation.
  run(source,root/'invalid.pdf','--dpi=0',ok=False);assert not (root/'invalid.pdf').exists();checks.append('DPI选项预检')
  # Bundled DjVu decodes at original resolution and never uses black-only mode.
  djvu=root/'示例.djvu'
  with tarfile.open(R/'ThirdParty/DjVuLibre/djvulibre-3.5.30.tar.gz') as tar:djvu.write_bytes(tar.extractfile('djvulibre-3.5.30/doc/djvulibre-book-en.djvu').read())
  original=djvu.read_bytes();result=run(djvu,root/'示例.pdf');pdf=PdfReader(result['output']);assert len(pdf.pages)==57 and result['losslessPages']==57 and djvu.read_bytes()==original;checks.append('57页DjVu原色无损转换且不改来源')
  assert len(pdf.outline)>10;checks.append('DjVu原生目录写入PDF')
 print(json.dumps({'passed':len(checks),'checks':checks},ensure_ascii=False,indent=2))
if __name__=='__main__':main()
