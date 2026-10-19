"""Type-specific page numbers, directory draft recovery and an optional real book."""
from pathlib import Path
import io, json, subprocess, sys, tempfile, zipfile
from PIL import Image
from pypdf import PdfWriter

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT/'UVZ Reader Lab.app/Contents/MacOS/UVZReaderLab'

def run(*args, ok=True):
    r = subprocess.run([str(EXE), *map(str, args)], capture_output=True, text=True, timeout=60)
    if ok:
        assert r.returncode == 0, (args, r.stderr)
        return json.loads(r.stdout)
    assert r.returncode != 0, (args, r.stdout)
    return r.stderr

def main():
    checks = []
    with tempfile.TemporaryDirectory(prefix='uvz-page-map09-') as directory:
        folder = Path(directory); image = io.BytesIO(); Image.new('RGB', (20,30), 'white').save(image,'PNG')
        book = folder/'书籍.uvz'
        with zipfile.ZipFile(book,'w',zipfile.ZIP_DEFLATED) as out:
            for name in ['cov001','bok001','leg001','fow001','!00001','000470','000473','000474','att001','cov002']:
                out.writestr(name+'.pdg', image.getvalue())
            out.writestr('BookInfo.dat', '书名=测试书\n页数=2'.encode())
        result = run('--resolve-page',book,5,473)
        assert result['physical']==7 and result['file']=='000473.pdg' and result['range']=='470—474'
        checks.append('按真实页面文件查找正文473，不受BookInfo页数与物理总页数限制')
        for token in ['４７３','000473','000473.pdg','正文473','473']:
            assert run('--resolve-page',book,5,token)['physical']==7
        checks.append('正文页号兼容全角数字、补零、页面文件名和中文类型')
        assert run('--resolve-page',book,3,1)['physical']==4
        assert run('--resolve-page',book,4,1)['physical']==5
        assert run('--resolve-page',book,7,2)['physical']==10
        assert run('--resolve-page',book,5,'fow1')['physical']==4
        checks.append('类型内数字分别定位前言、目录和封底，显式前缀可跨类型定位')
        assert run('--resolve-page',book,-1,7)['file']=='000473.pdg'
        assert run('--resolve-page',book,5,'@7')['file']=='000473.pdg'
        checks.append('物理页与@物理页保持明确入口')
        error = run('--resolve-page',book,5,471,ok=False)
        assert '正文' in error and '470—474' in error
        run('--resolve-page',book,3,473,ok=False)
        checks.append('缺页与错误类型不按序号误跳，提示具体类型和可用范围')
        text = folder/'目录.txt'; text.write_text('前言一\t1\n前言待修\t999')
        draft = run('--parse-contents-text',book,text,1,3,'--draft')
        assert draft['chapters'][0]['page']==4 and draft['chapters'][1]['page']==0 and draft['unresolvedTargets'][1]=='fow999'
        assert 'fow999' in draft['text']
        checks.append('分区裸数字使用当前类型，错误页号保留为可编辑草稿')
        run('--parse-contents-text',book,text,1,3,ok=False)
        payload = folder/'bad-draft.json'; payload.write_text(json.dumps(dict(chapters=[dict(title='错误页',page=0,level=0,unresolvedTarget='999')],metadata={})))
        before = book.read_bytes(); run('--apply-draft',book,payload,ok=False); assert book.read_bytes()==before
        checks.append('草稿允许未匹配页号，严格解析及保存仍拒绝错误且源文件不变')
        text.write_text('正文\t473\n\t子目录\t474\n前言\tfow1')
        parsed = run('--parse-contents-text',book,text)
        text.write_text(parsed['text']); assert run('--parse-contents-text',book,text)['chapters']==parsed['chapters']
        checks.append('正文、前置和多级目录的数字页号往返不丢目标')
        duplicate = folder/'重号.uvz'
        with zipfile.ZipFile(duplicate,'w') as out:
            for name in ['000473_1.pdg','000473_2.pdg']: out.writestr(name,image.getvalue())
        assert '多个' in run('--resolve-page',duplicate,5,473,ok=False)
        assert run('--resolve-page',duplicate,5,'@2')['physical']==2
        checks.append('重复页号拒绝含糊定位，物理页仍可明确选择')
        pdf=folder/'sample.pdf'; writer=PdfWriter()
        for _ in range(4): writer.add_blank_page(width=200,height=300)
        with pdf.open('wb') as out:writer.write(out)
        text.write_text('正文\t1\n前置\t-1')
        assert [c['page'] for c in run('--parse-contents-text',pdf,text,2)['chapters']]==[2,1]
        text.write_text('无类型\tfow1');run('--parse-contents-text',pdf,text,2,ok=False)
        checks.append('PDF正文基准与负页号兼容，不把PDG前缀当作PDF正文页号')
    if len(sys.argv)>1:
        real=Path(sys.argv[1]); result=run('--resolve-page',real,5,473)
        assert result['file']=='000473.pdg' and result['physical']==493
        checks.append('真实张纯一集正文473等于物理493')
        error=run('--resolve-page',real,5,441,ok=False)
        assert all(s in error for s in ['441—446','440','447','含断号','不代表图像缺失','其他类型'])
        assert '书中不存在' not in error
        checks.append('真实441按正文查找明确提示类型断号，不据此声称图像缺失')
        result=run('--resolve-page',real,5,'fow7')
        assert result['file']=='fow007.pdg' and result['physical']==14 and result['group']==3
        assert run('--resolve-page',real,3,7)['physical']==14
        checks.append('改造基督教之讨论标题页实际位于前言7，支持类型前缀及类型内页号')
        with tempfile.TemporaryDirectory(prefix='uvz-typed-target-') as directory:
            folder=Path(directory); text=folder/'contents.txt'
            lines=[f'前项{i}\t1' for i in range(1,10)]
            text.write_text('\n'.join(lines+['改造基督教之讨论\t441']))
            assert '第 10 行' in run('--parse-contents-text',real,text,ok=False)
            text.write_text('\n'.join(lines+['改造基督教之讨论\tfow7']))
            parsed=run('--parse-contents-text',real,text)
            assert parsed['chapters'][9]['page']==14
            text.write_text(parsed['text'])
            assert run('--parse-contents-text',real,text)['chapters']==parsed['chapters']
            copy=folder/'test-copy.uvz'
            subprocess.run(['cp','-c',str(real),str(copy)],check=True)
            payload=folder/'draft.json'
            payload.write_text(json.dumps(dict(chapters=parsed['chapters'],metadata=parsed['metadata'])))
            run('--apply-draft',copy,payload,'--contents-only')
            text.write_text(subprocess.check_output([str(EXE),'--export-contents-text',str(copy)],text=True))
            saved=run('--parse-contents-text',copy,text)
            assert saved['chapters']==parsed['chapters']
            with zipfile.ZipFile(real) as before,zipfile.ZipFile(copy) as after:
                unchanged=[n for n in before.namelist() if Path(n).name.lower()!='bookcontents.dat']
                assert all(before.getinfo(n).CRC==after.getinfo(n).CRC and before.read(n)==after.read(n) for n in unchanged)
        checks.append('真实第10行441报错可用fow7修正；副本保存重读正确且全部页面与BookInfo字节不变')
    print(json.dumps(dict(passed=len(checks),checks=checks),ensure_ascii=False,indent=2))

if __name__=='__main__':main()
