"""On-device OCR integration: crop two columns independently; only temporary books are written."""
from pathlib import Path
import hashlib, io, json, subprocess, sys, tempfile, zipfile
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / 'UVZ Reader Lab.app/Contents/MacOS/UVZReaderLab'

def fixture(folder):
    folder=Path(folder);folder.mkdir(parents=True,exist_ok=True)
    image=Image.new('RGB',(1800,1400),'white');draw=ImageDraw.Draw(image)
    font=ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial.ttf',56)
    for xy,text in [((180,30),'DO NOT IMPORT HEADER'),((80,250),'LEFT CHAPTER ...... 1'),((80,470),'LEFT SECTION ...... 2'),((1000,250),'RIGHT CHAPTER ...... 3'),((1000,470),'RIGHT SECTION ...... 2'),((180,1300),'DO NOT IMPORT FOOTER')]:
        draw.text(xy,text,font=font,fill='black')
    image.save(folder/'two-columns.png');data=io.BytesIO();image.save(data,'PNG')
    book=folder/'book.zip'
    with zipfile.ZipFile(book,'w',zipfile.ZIP_DEFLATED) as z:
        for i in range(1,4):z.writestr(f'{i:06d}.pdg',data.getvalue())
        z.writestr('BookInfo.dat','书名=双栏目录框选测试\r\n自定义=原字段保留'.encode())
    return book

def run(*args,ok=True):
    result=subprocess.run([str(EXE),*map(str,args)],capture_output=True,text=True,timeout=90)
    assert (result.returncode==0)==ok,(args,result.stdout,result.stderr)
    return json.loads(result.stdout) if ok else result.stderr

def main():
    checks=[]
    with tempfile.TemporaryDirectory(prefix='uvz-region-') as directory:
        folder=Path(directory);book=fixture(folder);before=hashlib.sha256(book.read_bytes()).hexdigest()
        left=run('--ocr-region',book,1,0.025,0.12,0.48,0.35)
        assert all(text in left['text'] for text in ['LEFT','SECTION'])
        assert all(text not in left['text'] for text in ['RIGHT','HEADER','FOOTER'])
        assert 864<=left['width']<=866 and left['height']==490
        checks.append('实际框选裁剪尺寸与左栏OCR正确，不混入其他区域')
        right=run('--ocr-region',book,1,0.53,0.12,0.46,0.35)
        assert all(text in right['text'] for text in ['RIGHT','SECTION'])
        assert all(text not in right['text'] for text in ['LEFT','HEADER','FOOTER'])
        checks.append('右栏独立识别，顺序不受另一栏影响')
        text=folder/'contents.txt';text.write_text(left['contentsText']+'\n'+right['contentsText'])
        parsed=run('--parse-contents-text',book,text)
        assert len(parsed['chapters'])==4 and [row['page'] for row in parsed['chapters']]==[1,2,3,2]
        checks.append('两块结果追加后可直接解析为目录目标页')
        assert before==hashlib.sha256(book.read_bytes()).hexdigest()
        draft=folder/'draft.json';draft.write_text(json.dumps(dict(chapters=parsed['chapters'],metadata=parsed['metadata']),ensure_ascii=False))
        assert run('--apply-draft',book,draft)['backups']==[]
        reloaded=run('--verify',book)
        assert reloaded['chapters']==parsed['chapters'] and reloaded['metadata']['自定义']=='原字段保留' and reloaded['renderedPages']==3
        checks.append('添加前不写文件，保存后目录与BookInfo重读正确，默认无备份')
        for roi in [(0,0,0,0.2),(1.5,0,0.2,0.2),('nan',0,0.2,0.2)]:run('--ocr-region',book,1,*roi,ok=False)
        run('--ocr-region',book,99,0,0,1,1,ok=False)
        checks.append('无效区域、非有限坐标与越界页码拒绝识别')
    print(json.dumps(dict(passed=len(checks),checks=checks),ensure_ascii=False,indent=2))

if __name__=='__main__':
    if len(sys.argv)==3 and sys.argv[1]=='--fixture':print(fixture(sys.argv[2]))
    else:main()
