"""Folder proposals and guarded writes on disposable archive, PDF and PDG-folder fixtures."""
from pathlib import Path
import hashlib,io,json,os,subprocess,tempfile,zipfile
from PIL import Image
from pypdf import PdfWriter
ROOT=Path(__file__).resolve().parents[1];EXE=ROOT/'UVZ Reader Lab.app/Contents/MacOS/UVZReaderLab'
def run(*args,ok=True):
 p=subprocess.run([str(EXE),*map(str,args)],capture_output=True,text=True,timeout=90)
 assert (p.returncode==0)==ok,(args,p.stdout,p.stderr)
 return json.loads(p.stdout) if p.stdout else None

def main():
 checks=[]
 with tempfile.TemporaryDirectory(prefix='uvz-batch-') as temp:
  root=Path(temp);lib=root/'library';lib.mkdir();payload=io.BytesIO();Image.new('RGB',(90,120),'white').save(payload,'PNG');png=payload.getvalue()
  meta={'书名':'港口史','作者':'林明著','出版社':'示例出版社','出版日期':'2020.08','SS号':'12345678','丛书名':'史料丛书','自定项':'保留'}
  def archive(path):
   with zipfile.ZipFile(path,'w') as z:
    z.writestr('cov001.pdg',png);z.writestr('000001.pdg',png);z.writestr('BookInfo.dat','\r\n'.join(k+'='+v for k,v in meta.items()).encode('gb18030'));z.writestr('Bookcontents.dat','篇一|01|1|0|6\r\n'.encode('gb18030'))
  a=lib/'初名_12345678.uvz';archive(a);before=a.read_bytes();os.utime(a,(1500000000,1500000000));dates=(a.stat().st_birthtime,a.stat().st_mtime)
  loose=lib/'散页书';loose.mkdir();(loose/'cov001.pdg').write_bytes(png);(loose/'000001.pdg').write_bytes(png);(loose/'BookInfo.dat').write_text('书名=散页书\n作者=叶平',encoding='utf-8')
  nested=lib/'子目录';nested.mkdir();archive(nested/'次级.uvz')
  hidden=lib/'.hidden.uvz';archive(hidden);archive(lib/'原件.backup-2026.zip');(lib/'别名.uvz').symlink_to(a);(lib/'缓存.uvzmeta').mkdir();archive(lib/'缓存.uvzmeta/假书.uvz')
  pdf=lib/'文档.pdf';writer=PdfWriter();writer.add_blank_page(width=120,height=180)
  with pdf.open('wb') as out:writer.write(out)
  def propose(recursive=False):return run('--batch-propose',lib,'--no-ocr',*(['--recursive'] if recursive else []))
  out=propose();assert out['count']==3,out;assert {Path(x['path']).name for x in out['books']}=={a.name,loose.name,pdf.name}
  assert propose(True)['count']==4;checks.append('识别直接子文件夹中的PDG书；递归可选；跳过隐藏、备份、旁存与符号链接')
  row=next(b for b in out['books'] if Path(b['path']).resolve()==a.resolve());assert row['proposal']['metadata']['自定项']=='保留' and len(row['candidates'])==2 and row['candidates'][1].startswith('【史料丛书】')
  assert a.read_bytes()==before and a.stat().st_mtime==dates[1] and len(list(lib.glob('*.backup-*')))==1
  checks.append('读取BookInfo生成两种格式并保留自定义字段；只分析不写书')
  plan=root/'plan.json'
  def apply(requests,ok=True,*options):plan.write_text(json.dumps(requests,ensure_ascii=False));return run('--batch-apply',plan,*options,ok=ok)
  def request(row,stem,metadata=None):return dict(path=row['path'],stem=stem,metadata=metadata,fingerprint=row['proposal']['fingerprint'])
  r=request(row,'规范名称');apply([r]);new=lib/'规范名称.uvz';assert new.read_bytes()==before and not a.exists() and new.stat().st_mtime==dates[1] and abs(new.stat().st_birthtime-dates[0])<.001
  checks.append('默认只改名，保持整书字节与创建修改日期')
  stale=dict(r,path=str(new),stem='陈旧建议');new.write_bytes(before+b'changed');apply([stale],ok=False);assert new.exists() and not (lib/'陈旧建议.uvz').exists();new.write_bytes(before)
  checks.append('分析后文件改变时拒绝应用，保留原路径')
  current=next(b for b in propose()['books'] if Path(b['path']).resolve()==new.resolve())
  conflict=lib/'已有.uvz';conflict.write_bytes(b'existing');apply([request(current,'已有')],ok=False);assert conflict.read_bytes()==b'existing'
  companion=lib/'旁存冲突.uvz.uvzmeta';companion.mkdir();apply([request(current,'旁存冲突')],ok=False)
  apply([request(current,'同名'),request(current,'同名')],ok=False);assert new.exists()
  apply([request(current,'../逃逸')],ok=False);apply([request(current,'坏:名')],ok=False)
  checks.append('覆盖、旁存冲突、批次重复和非法路径在写入前阻止')
  apply([request(current,'普'*90)]);long=lib/(('普'*90)+'.uvz');assert long.exists();new=long
  checks.append('允许实际文件系统支持的中文长文件名，不按UTF8字节错误截短')
  current=next(b for b in propose()['books'] if Path(b['path']).resolve()==new.resolve())
  m=dict(meta,书名='修订书名');apply([request(current,'信息保存',m)],True,'--backup');new=lib/'信息保存.uvz'
  with zipfile.ZipFile(new) as z:assert z.read('cov001.pdg')==png and z.read('Bookcontents.dat')=='篇一|01|1|0|6\r\n'.encode('gb18030')
  assert run('--inspect',new)['metadata']==m;assert any('.backup-' in p.name and p.read_bytes()==before for p in lib.iterdir() if p.is_file())
  checks.append('勾选保存信息时更新DAT，保留图像、目录和未知字段，按选项生成备份')
  pdfr=next(b for b in propose()['books'] if Path(b['path']).resolve()==pdf.resolve());pdfbytes=pdf.read_bytes();apply([request(pdfr,'PDF新名称',{'书名':'PDF测试'})]);newpdf=lib/'PDF新名称.pdf';side=Path(str(newpdf)+'.uvzmeta');assert newpdf.read_bytes()==pdfbytes and (side/'BookInfo.dat').exists()
  pdfr=next(b for b in propose()['books'] if Path(b['path']).resolve()==newpdf.resolve());oldside=side;apply([request(pdfr,'PDF再次更名')]);assert not oldside.exists() and (lib/'PDF再次更名.pdf.uvzmeta/BookInfo.dat').exists()
  checks.append('PDF原始字节不变，信息旁存文件夹随两次改名迁移')
  current=next(b for b in propose()['books'] if Path(b['path']).resolve()==loose.resolve());apply([request(current,'散页规范名称',{'书名':'散页修订','作者':'叶平'})]);newloose=lib/'散页规范名称';assert (newloose/'000001.pdg').read_bytes()==png and run('--inspect',newloose)['metadata']['书名']=='散页修订'
  checks.append('PDG文件夹作为一本书改名，可选保存信息并保持页面')
  side=lib/'PDF再次更名.pdf.uvzmeta';pdfr=next(b for b in propose()['books'] if Path(b['path']).name=='PDF再次更名.pdf');(side/'BookInfo.dat').write_text('书名=外部更改');apply([request(pdfr,'旁存变更拒绝')],ok=False)
  checks.append('原文档未变但旁存信息改变时也拒绝旧建议')
  merge=root/'merge.json';merge.write_text(json.dumps(dict(original={'书名':'已有','出版日期':'2020','SS号':'12345678'},evidence=[dict(field='书名',value='另一书',source='CIP著录',inferred=False),dict(field='出版日期',value='2020.08',source='出版信息',inferred=False),dict(field='作者',value='甲',source='封面',inferred=True)])))
  m=run('--batch-merge',merge);assert m['metadata']['书名']=='已有' and m['metadata']['出版日期']=='2020.08' and '书名来源不一致' in m['reviewReasons'] and '作者为版面推测' in m['reviewReasons']
  checks.append('合并保留已有值并列出冲突，允许同年年月补齐，推测值需核对')
 print(json.dumps(dict(passed=len(checks),checks=checks),ensure_ascii=False,indent=2))
if __name__=='__main__':main()
