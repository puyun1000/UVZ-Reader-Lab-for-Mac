"""Page recoding must preserve image bytes, DAT identities and ZIP metadata."""
from pathlib import Path
import io,json,os,struct,subprocess,sys,tempfile,zipfile,zlib,shutil
from PIL import Image,ImageDraw,ImageFont
from pypdf import PdfWriter
R=Path(__file__).resolve().parents[1];EXE=R/'UVZ Reader Lab.app/Contents/MacOS/UVZReaderLab'
def run(*args,ok=True):
 r=subprocess.run([str(EXE),*map(str,args)],capture_output=True,text=True,timeout=160)
 if ok:assert r.returncode==0,(args,r.stderr);return json.loads(r.stdout)
 assert r.returncode!=0,(args,r.stdout);return r.stderr
def png(color):
 b=io.BytesIO();Image.new('RGB',(60,90),color).save(b,'PNG');return b.getvalue()
def payload(folder,changes):
 p=folder/'changes.json';p.write_text(json.dumps(changes));return p
def change(page,group,number):return dict(page=page,group=group,number=number)
class Streaming(io.BytesIO):
 def seekable(self):return False
 def seek(self,*args):raise io.UnsupportedOperation()
def archive(p,files,contents=None,streaming=False,compressed=False):
 buf=Streaming() if streaming else io.BytesIO()
 with zipfile.ZipFile(buf,'w',zipfile.ZIP_DEFLATED) as out:
  out.comment=b'book comment retained'
  for name,value in files.items():
   e=zipfile.ZipInfo('中文书/'+name,(2001,2,3,4,5,6));e.compress_type=zipfile.ZIP_DEFLATED;e.external_attr=0o100644<<16;e.comment=b'member comment'
   if name.startswith('fow'):
    raw=e.filename.encode();extra=b'\x01'+struct.pack('<I',zlib.crc32(raw))+raw
    e.extra=struct.pack('<HH',0x7075,len(extra))+extra+struct.pack('<HH',0xbeef,3)+b'xyz'
   out.writestr(e,value)
  if contents is not None:
   data=contents.encode()
   if compressed:data=b'SSCNTS'+b'\x00'*34+zlib.compress(data)
   out.writestr('中文书/Bookcontents.dat',data)
  out.writestr('中文书/BookInfo.dat','书名=测试书\r\n自定义=不变\r\n'.encode())
  out.writestr('中文书/附属.txt','附属不变'.encode())
 p.write_bytes(buf.getvalue())
def main():
 checks=[]
 with tempfile.TemporaryDirectory(prefix='uvz-recode-') as tmp:
  f=Path(tmp);book=f/'source.uvz'
  files={'fow007.pdg':png('red'),'000440.pdg':png('green'),'000447.pdg':png('blue')}
  dat='章节|01|7|0|4\r\n正文|02|447|0|6\r\n失效记录|03|999|0|6\r\n'
  archive(book,files,dat,streaming=True,compressed=True)
  original=book.read_bytes();mtime=946684800012345678;os.utime(book,ns=(mtime,mtime))
  findings=run('--page-audit',book);assert any('441—446' in x['text'] for x in findings)
  plan=payload(f,[change(1,5,441)]);d=run('--plan-pages',book,plan)
  assert d['renames']=={'fow007.pdg':'000441.pdg'} and book.read_bytes()==original
  checks.append('类型断号检查与修改预览只读原文件')
  with zipfile.ZipFile(book) as z:before={n:(z.read(n),z.getinfo(n)) for n in z.namelist()}
  run('--correct-pages',book,plan,'--backup')
  assert abs(book.stat().st_mtime_ns-mtime)<1000 and next(f.glob('source.uvz.backup-*')).read_bytes()==original
  with zipfile.ZipFile(book) as z:
   assert z.testzip() is None and z.comment==b'book comment retained'
   assert z.read('中文书/000441.pdg')==files['fow007.pdg']
   for name in ['000440.pdg','000447.pdg']:assert z.read('中文书/'+name)==files[name]
   e=z.getinfo('中文书/000441.pdg');old=before['中文书/fow007.pdg'][1]
   assert e.date_time==old.date_time and e.external_attr==old.external_attr and e.comment==old.comment and e.CRC==old.CRC and e.flag_bits&8
   assert b'xyz' in e.extra and struct.pack('<H',0x7075) not in e.extra
   text=z.read('中文书/Bookcontents.dat').decode()
   assert '章节|01|441|0|6' in text and '失效记录|03|999|0|6' in text
   assert z.read('中文书/BookInfo.dat')==before['中文书/BookInfo.dat'][0]
   assert z.read('中文书/附属.txt')==before['中文书/附属.txt'][0]
  check=run('--inspect',book);assert [c['page'] for c in check['chapters']]==[2,3]
  checks.extend(['ZIP页面实际改名与重排，图像字节不变','流式ZIP描述符、CRC、成员时间属性注释、压缩包注释及非路径扩展字段保留','压缩目录同步旧页面目标，并保留失效记录、书籍信息和附属文件','备份逐字节保留原件，默认保持修改日期'])
  # Swapping selected target identities is valid; no page may overwrite another.
  swap=f/'swap.zip';archive(swap,{'000001.pdg':png('red'),'000002.pdg':png('blue')},'甲|01|1|0|6\n乙|02|2|0|6')
  run('--correct-pages',swap,payload(f,[change(1,5,2),change(2,5,1)]))
  with zipfile.ZipFile(swap) as z:
   assert z.read('中文书/000001.pdg')==png('blue') and z.read('中文书/000002.pdg')==png('red')
   assert '甲|01|2|0|6' in z.read('中文书/Bookcontents.dat').decode()
  checks.append('同时交换页号时保留两张原图与各自目录目标')
  for changes in [[change(1,5,447)],[change(1,5,-1)],[change(1,9,1)],[change(99,5,1)],[change(1,0,2)],[change(1,5,1),change(1,5,2)]]:
   before=book.read_bytes();run('--correct-pages',book,payload(f,changes),ok=False);assert book.read_bytes()==before
  checks.append('重号、非法类型页号、越界位置、重复设置和错误封面编号拒绝且原件不变')
  # A suffixed target is still the same semantic page number.
  dup=f/'duplicate.uvz';archive(dup,{'fow007.pdg':png('red'),'000441_note.pdg':png('blue')})
  run('--correct-pages',dup,payload(f,[change(1,5,441)]),ok=False)
  checks.append('兼容后缀文件的语义重号冲突检查')
  folder=f/'folder';folder.mkdir()
  for name,data in files.items():(folder/name).write_bytes(data)
  (folder/'Bookcontents.dat').write_text('章节|01|7|0|4\n正文|02|447|0|6')
  (folder/'BookInfo.dat').write_text('书名=文件夹\n原值=保持')
  before_info=(folder/'BookInfo.dat').read_bytes();os.utime(folder,ns=(mtime,mtime))
  run('--correct-pages',folder,payload(f,[change(1,5,441)]),'--backup')
  assert not (folder/'fow007.pdg').exists() and (folder/'000441.pdg').read_bytes()==files['fow007.pdg']
  assert '441|0|6' in (folder/'Bookcontents.dat').read_text() and (folder/'BookInfo.dat').read_bytes()==before_info
  assert abs(folder.stat().st_mtime_ns-mtime)<1000 and next(f.glob('folder.backup-*')).is_dir()
  assert run('--inspect',folder)['chapters'][0]['page']==2
  checks.append('PDG文件夹分阶段保存、同步目录、保留图像信息日期及完整备份')
  swapfolder=f/'swap-folder';swapfolder.mkdir()
  (swapfolder/'000001.pdg').write_bytes(png('red'));(swapfolder/'000002.pdg').write_bytes(png('blue'))
  run('--correct-pages',swapfolder,payload(f,[change(1,5,2),change(2,5,1)]))
  assert (swapfolder/'000001.pdg').read_bytes()==png('blue') and (swapfolder/'000002.pdg').read_bytes()==png('red')
  checks.append('文件夹互换编号采用临时名，避免覆盖原图')
  # Unchanged multi-page text PDG references must retain their logical offsets.
  writer=PdfWriter();writer.add_blank_page(width=200,height=300);writer.add_blank_page(width=200,height=300);buf=io.BytesIO();writer.write(buf)
  mixed=f/'mixed.uvz';archive(mixed,{'fow007.pdg':png('red'),'000001.pdg':buf.getvalue()},'文本第二页|01|2|0|6\n待改|02|7|0|4')
  run('--correct-pages',mixed,payload(f,[change(1,5,3)]))
  with zipfile.ZipFile(mixed) as z:assert '文本第二页|01|2|0|6' in z.read('中文书/Bookcontents.dat').decode()
  before=mixed.read_bytes();run('--correct-pages',mixed,payload(f,[change(1,5,99)]),ok=False);assert mixed.read_bytes()==before
  checks.append('保留未修改多页文本PDG的逻辑页号，拒绝逐页改其文件编码')
  pdf=f/'document.pdf';pdf.write_bytes(buf.getvalue());before=pdf.read_bytes();run('--correct-pages',pdf,payload(f,[change(1,5,2)]),ok=False);assert pdf.read_bytes()==before
  checks.append('其他文档格式不误用PDG编码纠正')
  no=f/'no-directory.uvz';archive(no,files)
  run('--correct-pages',no,payload(f,[change(1,5,441)]))
  with zipfile.ZipFile(no) as z:assert not any(n.lower().endswith('bookcontents.dat') for n in z.namelist())
  assert not list(f.glob('no-directory.uvz.backup-*'))
  checks.append('无目录时不凭空创建目录，默认不备份')
  damaged=f/'damaged.uvz';archive(damaged,files)
  data=bytearray(damaged.read_bytes())
  with zipfile.ZipFile(damaged) as z:
   entry=z.getinfo('中文书/附属.txt');at=entry.header_offset;n,ex=struct.unpack_from('<HH',data,at+26);data[at+30+n+ex]^=1
  damaged.write_bytes(data);before=damaged.read_bytes();run('--correct-pages',damaged,payload(f,[change(1,5,441)]),ok=False);assert damaged.read_bytes()==before
  checks.append('保存前校验原有成员CRC，受损附属文件也拒绝修改')
  image=Image.new('RGB',(1000,1500),'white');draw=ImageDraw.Draw(image);font=ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial.ttf',52)
  draw.text((70,60),'400',font=font,fill='black');draw.text((70,330),'A page for checking its printed number.',font=font,fill='black')
  buf=io.BytesIO();image.save(buf,'PNG');margin=f/'margin.uvz';archive(margin,{'000001.pdg':buf.getvalue()})
  before=margin.read_bytes();findings=run('--page-audit',margin,'--current-page=1')
  assert any(item.get('suggestedNumber')==400 and item['id']=='printed:0' for item in findings) and margin.read_bytes()==before
  checks.append('正文页眉识别与编码不同会给出待确认建议，检查不修改图书')
 print(json.dumps(dict(passed=len(checks),checks=checks),ensure_ascii=False,indent=2))
if __name__=='__main__':main()
