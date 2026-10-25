"""Purpose-made horizontal and vertical fixtures; no library scans are redistributed."""
from pathlib import Path
import subprocess,json,tempfile
from PIL import Image,ImageDraw,ImageFont
r=Path(__file__).resolve().parents[1];exe=r/'UVZ Reader Lab.app/Contents/MacOS/UVZReaderLab';checks=[]
cases={
 'simplified':('zh-Hans',['书名：中国古典文学研究','作者：张明','丛书名：东亚文库','出版者：中华书局','出版日期：2021年4月','页数：268页','ISBN 978-0-306-40615-7'],{'书名':'中国古典文学研究','作者':'张明','丛书名':'东亚文库','出版社':'中华书局','出版日期':'2021.04','页数':'268','ISBN':'9780306406157'}),
 'traditional':('zh-Hant',['書名：古籍文獻研究','作者：張明','叢書名：東亞文庫','出版者：中華書局','出版日期：2021年4月','頁數：268頁','ISBN 978-0-306-40615-7'],{'书名':'古籍文獻研究','作者':'張明','丛书名':'東亞文庫','出版社':'中華書局','出版日期':'2021.04','页数':'268','ISBN':'9780306406157'}),
 'japanese':('ja-JP',['タイトル：日本の古典文学','著者：山田太郎','シリーズ：日本文学研究','発行所：東京書房','発行日：2020年4月1日','ページ数：268','ISBN 978-0-306-40615-7'],{'书名':'日本の古典文学','作者':'山田太郎','丛书名':'日本文学研究','出版社':'東京書房','出版日期':'2020.04','页数':'268','ISBN':'9780306406157'}),
 'english':('en-US',['Title: Studies in Asian History','Author: Alice Brown','Series: Asian Studies','Publisher: Example Press','Publication date: 2020.04','Pages: 268','ISBN 978-0-306-40615-7'],{'书名':'Studies in Asian History','作者':'Alice Brown','丛书名':'Asian Studies','出版社':'Example Press','出版日期':'2020.04','页数':'268','ISBN':'9780306406157'}),
 'vertical-traditional':('zh-Hant',['書名：古籍文獻研究','作者：張明','出版者：中華書局'],{'书名':'古籍文獻研究','作者':'張明','出版社':'中華書局'}),
 'vertical-japanese':('ja-JP',['タイトル：日本の古典文学','著者：山田太郎','発行所：東京書房'],{'书名':'日本の古典文学','作者':'山田太郎','出版社':'東京書房'})}
with tempfile.TemporaryDirectory(prefix='uvz-ocr013-') as td:
 root=Path(td)
 for name,(language,lines,wanted) in cases.items():
  im=Image.new('RGB',(1600,2100),'white');d=ImageDraw.Draw(im);vertical=name.startswith('vertical')
  font=ImageFont.truetype('/System/Library/Fonts/Supplemental/Times New Roman.ttf' if language=='en-US' else '/System/Library/Fonts/STHeiti Light.ttc',64 if vertical else 52)
  for i,line in enumerate(lines):
   if vertical:
    for j,c in enumerate(line):d.text((1380-i*190,100+j*100),c,fill='black',font=font)
   else:d.text((100,100+i*110),line,fill='black',font=font)
  path=root/(name+'.png');im.save(path)
  for lang,layout in [(language,'auto'),('auto','auto'),(language,'vertical' if vertical else 'horizontal')]:
   out=json.loads(subprocess.check_output([str(exe),'--ocr-image',str(path),'--language='+lang,'--layout='+layout],text=True,timeout=90))
   assert all(out['metadata'].get(k)==v for k,v in wanted.items()),(name,lang,layout,out,wanted)
   if vertical:assert out['verticalLines']>=3,(name,out)
   else:assert out['verticalLines']==0,(name,out)
   checks.append(name+' '+lang+' '+layout)
  if language=='en-US':
   for angle in [90,270]:
    rotated=root/('rotated'+str(angle)+'.png');im.rotate(angle,expand=True).save(rotated)
    out=json.loads(subprocess.check_output([str(exe),'--ocr-image',str(rotated),'--language=en-US','--layout=vertical'],text=True,timeout=90))
    assert all(out['metadata'].get(k)==v for k,v in wanted.items()),(angle,out)
    checks.append('rotated English '+str(angle))
print(json.dumps(dict(passed=len(checks),checks=checks),ensure_ascii=False,indent=2))
