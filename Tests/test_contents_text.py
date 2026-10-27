"""Independent text/DAT round-trip tests for the PdgCntEditor-style editor."""
from pathlib import Path
import io,json,subprocess,tempfile,zipfile
from PIL import Image
from pypdf import PdfWriter
ROOT=Path(__file__).resolve().parents[1]
EXE=ROOT/'UVZ Reader Lab.app/Contents/MacOS/UVZReaderLab'
def run(*args,ok=True):
 r=subprocess.run([str(EXE),*map(str,args)],capture_output=True,text=True,timeout=30)
 if ok:
  assert r.returncode==0,(args,r.stderr)
  return json.loads(r.stdout)
 assert r.returncode!=0,(args,r.stdout)
 return r.stderr

def main():
 checks=[]
 with tempfile.TemporaryDirectory(prefix='uvz-text-') as directory:
  p=Path(directory); b=io.BytesIO();Image.new('RGB',(20,30),'white').save(b,'PNG')
  book=p/'题名_12345678.zip'
  names=['cov001','bok001','leg001','fow001','!00001','000001','000002','000003','000004','att001','cov002']
  with zipfile.ZipFile(book,'w') as z:
   for name in names:z.writestr(name+'.pdg',b.getvalue())
  assert run('--inspect',book)['filenameSuggestion']=='题名_12345678'
  checks.append('无BookInfo时从仅书名加SS号的文件名提取字段，生成不重复SS号')
  text=p/'contents.txt'
  source='第一部\n\t正文第一章\t1\n\t第二章\t3\n封面\tcov1\n书名\tbok1\n版权\tleg1\n前言\tfow1\n目录\t!1\n附录\tatt1\n封底\tbac2'
  text.write_text(source)
  parsed=run('--parse-contents-text',book,text)
  assert [c['page'] for c in parsed['chapters']]==[0,6,8,1,2,3,4,5,10,11]
  assert [c['level'] for c in parsed['chapters']][:3]==[0,1,1]
  checks.append('TAB 层级、无跳转分组、八类 PDG 书籍页号到物理页映射')
  text.write_text(parsed['text']); again=run('--parse-contents-text',book,text)
  assert parsed['chapters']==again['chapters']
  checks.append('文本导入导出保持名称、页码与层级')
  draft=p/'draft.json';draft.write_text(json.dumps({'chapters':parsed['chapters'],'metadata':{}},ensure_ascii=False))
  run('--apply-draft',book,draft)
  reread=run('--inspect',book)
  assert reread['chapters']==parsed['chapters']
  assert reread['fallbackNavigation'][:5]==['封面','书名','版权','前言','目录'] and reread['fallbackNavigation'][5]=='第一部'
  checks.append('含无跳转父节点的多级目录写入 DAT 并重读')
  text.write_text('物理跳转\t@8')
  assert run('--parse-contents-text',book,text)['chapters'][0]['page']==8
  checks.append('@物理页码直接定位')
  for bad in ['越界\t999','跳层\n\t\t子项\t1','竖|线\t1','重复TAB\t多余\t1','未知前缀\tfoo1']:
   text.write_text(bad);err=run('--parse-contents-text',book,text,ok=False);assert err
  checks.append('非法页号、层级、标题及分隔符拒绝解析并提供错误')
  text.write_text('OCR标题  2\n\t子节  3')
  split=run('--parse-contents-text',book,text)['split']
  assert split=='OCR标题\t2\n\t子节\t3'
  text.write_text(split);assert [c['page'] for c in run('--parse-contents-text',book,text)['chapters']]==[7,8]
  checks.append('OCR 行末页码分离后可直接解析，保留缩进')
  for original,expected in [('无页码分组','无页码分组'),('\t无页码子项','\t无页码子项'),('年份标题 2024\t','年份标题 2024\t'),('标题……3','标题\t3'),('\t子项　４','\t子项\t４')]:
   prefix='根节点\n' if original.startswith('\t') else '';text.write_text(prefix+original);assert run('--parse-contents-text',book,text)['split']==prefix+expected
  checks.append('页号整理仅分隔真实后缀，保留无页码标题、层级、点线与全角空格数字')
  text.write_text('年份标题 2024');result=run('--parse-contents-text',book,text);assert result['text']=='年份标题 2024' and result['chapters'][0]['page']==0
  checks.append('无目标的分组不输出末尾TAB，数字标题导出后仍保留分组含义')
  pdf=p/'sample.pdf';w=PdfWriter()
  for _ in range(8):w.add_blank_page(width=100,height=160)
  with pdf.open('wb') as out:w.write(out)
  text.write_text('前页\t-1\n正文\t1\n\t子节\t2')
  result=run('--parse-contents-text',pdf,text,3)
  assert [c['page'] for c in result['chapters']]==[2,3,4]
  text.write_text(result['text']);assert run('--parse-contents-text',pdf,text,3)['chapters']==result['chapters']
  checks.append('PDF 正文基准页与前置负页码往返')
  for value in ['坏页\t0','越界\t7','前置越界\t-3']:
   text.write_text(value);run('--parse-contents-text',pdf,text,3,ok=False)
  checks.append('PDF 基准页换算越界及零页码拒绝')
 print(json.dumps({'passed':len(checks),'checks':checks},ensure_ascii=False,indent=2))
if __name__=='__main__':main()
