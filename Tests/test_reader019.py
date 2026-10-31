from pathlib import Path
from PIL import Image,ImageDraw,ImageFont
import json,subprocess,tempfile
r=Path(__file__).resolve().parents[1];exe=r/'UVZ Reader Lab.app/Contents/MacOS/UVZReaderLab';checks=[]
def run(*a):
 p=subprocess.run([str(exe),*map(str,a)],capture_output=True,text=True,timeout=120);assert p.returncode==0,p.stderr;return json.loads(p.stdout)
with tempfile.TemporaryDirectory() as t:
 d=Path(t);f=d/'hk.txt';f.write_text('書名：香港歷史研究\n出版機構：香港學術出版社\n初版日期：中華民國113年5月\nISBN 978-0-306-40615-7')
 x=run('--extract-metadata',f)['metadata'];assert x['出版社']=='香港學術出版社' and x['出版日期']=='2024.05',x;checks.append('港台出版機構、初版日期與民國紀年保留原文字形')
 im=Image.new('RGB',(1600,2100),'white');draw=ImageDraw.Draw(im);font=ImageFont.truetype('/System/Library/Fonts/STHeiti Light.ttc',52)
 for i,line in enumerate(['書名：古籍文獻研究','作者：張明','出版機構：中華書局','出版日期：2021年4月']):draw.text((100,100+150*i),line,fill=(235,235,235),font=font)
 im.save(d/'faint.png');(d/'faint.pdg').write_bytes((d/'faint.png').read_bytes());x=run('--ocr-metadata',d/'faint.pdg');assert x['metadata'].get('书名')=='古籍文獻研究',x;checks.append('发白繁体页面（灰度235/255）可提取书名')
 from reportlab.pdfgen import canvas
 books=d/'books';books.mkdir();c=canvas.Canvas(str(books/'tail.pdf'),pagesize=(600,800))
 for i in range(23):
  if i==22:c.drawImage(str(d/'faint.png'),0,0,width=600,height=800)
  c.showPage()
 c.save();x=run('--batch-propose',books);row=next(v for v in x['books'] if v['path'].endswith('tail.pdf'));pages=[p['physical'] for p in row['proposal']['pages']]
 assert pages==list(range(1,11))+list(range(14,24)),pages;checks.append('23页PDF覆盖前10及末10页，尾页版权数据参与识别')
print(json.dumps(dict(passed=len(checks),checks=checks),ensure_ascii=False,indent=2))
