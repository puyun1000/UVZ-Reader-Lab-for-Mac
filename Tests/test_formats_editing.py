"""Round-trip integration tests. Only temporary fixtures are modified."""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess
import tarfile
import tempfile
import zipfile
from PIL import Image
from pypdf import PdfWriter

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / 'UVZ Reader Lab.app/Contents/MacOS/UVZReaderLab'

def run(*args, ok=True):
    result = subprocess.run([str(EXE), *map(str, args)], capture_output=True, text=True, timeout=180)
    if ok:
        assert result.returncode == 0, (args, result.stderr)
        return json.loads(result.stdout) if result.stdout.strip() else None
    assert result.returncode != 0, (args, result.stdout)
    return result.stderr

def draft(path, chapters, metadata):
    path.write_text(json.dumps(dict(chapters=chapters, metadata=metadata), ensure_ascii=False))
    return path

def main():
    checks = []
    with tempfile.TemporaryDirectory(prefix='uvz-formats-') as folder:
        folder = Path(folder)
        image = folder / 'page.png'
        Image.new('RGB', (80, 120), 'red').save(image)
        png = image.read_bytes()
        pdf = folder / '示例.pdf'
        writer = PdfWriter()
        for _ in range(3): writer.add_blank_page(width=320, height=480)
        writer.add_metadata({'/Title': 'PDF原生标题', '/Author': '作者'})
        parent = writer.add_outline_item('PDF第一章', 0)
        writer.add_outline_item('PDF子目录', 1, parent=parent)
        with pdf.open('wb') as out: writer.write(out)
        before_pdf = pdf.read_bytes()
        result = run('--verify', pdf)
        assert result['pageCount'] == result['renderedPages'] == 3
        assert result['title'] == 'PDF原生标题'
        assert [c['level'] for c in result['chapters']] == [0, 1]
        checks.append('独立 PDF 三页渲染、原生书名与多级目录导入')
        tiff = folder / '多页.tiff'
        Image.new('RGB', (60, 80), 'red').save(tiff, save_all=True, append_images=[Image.new('RGB', (90, 50), 'green'), Image.new('RGB', (70, 100), 'blue')])
        result = run('--verify', tiff)
        assert result['pageCount'] == result['renderedPages'] == 3
        for i, size, color in [(1, (60, 80), (255, 0, 0)), (2, (90, 50), (0, 128, 0)), (3, (70, 100), (0, 0, 255))]:
            out = folder / f'frame{i}.png'
            run('--render-page', tiff, i, out)
            with Image.open(out) as frame:
                assert frame.size == size
                assert frame.convert('RGB').getpixel((20, 20)) == color
        checks.append('多页 TIFF 按帧展开，逐帧像素颜色和尺寸对应')
        pdgdir = folder / 'PDG书籍'; pdgdir.mkdir()
        for name in ['cov001', '000001', '000002']:
            (pdgdir / f'{name}.pdg').write_bytes(png)
        (pdgdir / 'Bookinfo.dat').write_bytes('书名=文件夹书籍\r\n自定义=保留'.encode('gb18030'))
        assert run('--verify', pdgdir)['renderedPages'] == 3
        assert run('--verify', pdgdir / '000001.pdg')['renderedPages'] == 1
        checks.append('直接打开 PDG 文件夹和单个 PDG 页面')
        archive = folder / '中文.zip'
        originals = {f'书籍/{p.name}': p.read_bytes() for p in pdgdir.iterdir()}
        originals['其他.txt'] = b'retain this ancillary file'
        with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as z:
            z.comment = b'Preserve archive comment'
            for name, value in originals.items():
                member = zipfile.ZipInfo(name, date_time=(2025, 4, 3, 12, 30, 0))
                member.compress_type = zipfile.ZIP_DEFLATED
                member.external_attr = 0o100644 << 16
                member.comment = b'Keep member comment'
                member.extra = b'\xfe\xca\x03\x00abc'
                z.writestr(member, value)
        original_zip = archive.read_bytes()
        chapters = [dict(title='封面目录', page=1, level=0), dict(title='正文子项', page=2, level=1), dict(title='第二章', page=3, level=0)]
        metadata = {'书名': '改后书名', '作者': '新作者', '自定义': '仍然保留'}
        edit = draft(folder / 'draft.json', chapters, metadata)
        result = run('--apply-draft', archive, edit, '--backup')
        assert len(result['backups']) == 1
        assert Path(result['backups'][0]).read_bytes() == original_zip
        with zipfile.ZipFile(archive) as z:
            assert z.testzip() is None
            for name, value in originals.items():
                if name.lower().endswith('bookinfo.dat'): continue
                assert z.read(name) == value, name
                member = z.getinfo(name)
                assert member.date_time == (2025, 4, 3, 12, 30, 0)
                assert member.external_attr == 0o100644 << 16 and member.comment == b'Keep member comment'
                assert member.extra == b'\xfe\xca\x03\x00abc'
            assert z.comment == b'Preserve archive comment'
            assert z.read('书籍/BookInfo.dat').decode().find('自定义=仍然保留') >= 0
        result = run('--verify', archive)
        assert result['renderedPages'] == 3 and result['title'] == '改后书名'
        assert result['chapters'] == chapters
        checks.append('ZIP 内目录与 BookInfo 原位保存、原件备份、Python 独立 CRC 校验和所有页面/附属文件不变')
        # Second save replaces existing metadata instead of introducing duplicate names.
        backups_before = set(folder.glob('*.backup-*'))
        default_save = run('--apply-draft', archive, edit)
        assert default_save['backups'] == [] and set(folder.glob('*.backup-*')) == backups_before
        checks.append('默认保存不生成备份，显式开启备份仍完整保留原文件')
        with zipfile.ZipFile(archive) as z:
            assert len(z.namelist()) == len(set(n.lower() for n in z.namelist()))
        checks.append('重复保存不生成大小写重复的 DAT 项')
        # Streamed ZIPs use data descriptors; preserving them must not break external readers.
        import io
        class NonSeekable(io.BytesIO):
            def seekable(self): return False
            def seek(self, *args): raise io.UnsupportedOperation()
        stream = NonSeekable()
        with zipfile.ZipFile(stream, 'w', zipfile.ZIP_DEFLATED) as z:
            z.writestr('000001.pdg', png); z.writestr('000002.pdg', png); z.writestr('000003.pdg', png)
        streamed = folder / 'streamed.zip'; streamed.write_bytes(stream.getvalue())
        run('--apply-draft', streamed, edit)
        with zipfile.ZipFile(streamed) as z:
            assert z.testzip() is None and z.read('000001.pdg') == png
        checks.append('流式 ZIP 数据描述符和原有 ZIP 注释/时间/属性保留')
        saved = archive.read_bytes()
        for bad in [[dict(title='失效', page=999, level=0)], [dict(title='层级跳跃', page=1, level=2)], [dict(title='竖|线', page=1, level=0)]]:
            run('--apply-draft', archive, draft(edit, bad, metadata), ok=False)
            assert archive.read_bytes() == saved
        run('--apply-draft', archive, draft(edit, chapters, {'坏=键': '值'}), ok=False)
        assert archive.read_bytes() == saved
        checks.append('越界页码、非法目录层级/标题和非法元数据拒绝保存且源文件不变')
        edit = draft(edit, chapters, metadata)
        renamed = Path(run('--rename-book', archive, '修改后的文件名')['path'])
        assert not archive.exists() and renamed.read_bytes() == saved
        occupied = folder / '已存在.zip'; occupied.write_bytes(b'occupied')
        run('--rename-book', renamed, '已存在', ok=False)
        run('--rename-book', renamed, '../越界', ok=False)
        assert renamed.read_bytes() == saved and occupied.read_bytes() == b'occupied'
        checks.append('ZIP 中文改名保留字节，拒绝覆盖和路径跳转')
        # DAT folder writes and sidecars use the same independently checked structure.
        run('--apply-draft', pdgdir, edit)
        assert run('--inspect', pdgdir)['chapters'] == chapters
        checks.append('PDG 文件夹 DAT 保存与重新读取')
        for document in [pdf, tiff]:
            original = document.read_bytes()
            run('--apply-draft', document, edit)
            reread = run('--verify', document)
            assert reread['chapters'] == chapters and reread['metadata']['自定义'] == '仍然保留'
            assert document.read_bytes() == original
        assert pdf.read_bytes() == before_pdf
        checks.append('PDF、TIFF 目录和元数据旁存重读，原文档字节不变')
        # Official upstream DjVu fixtures, distributed inside the corresponding source archive.
        source = ROOT / 'ThirdParty/DjVuLibre/djvulibre-3.5.30.tar.gz'
        with tarfile.open(source) as tar:
            name = 'djvulibre-3.5.30/doc/djvulibre-book-en.djvu'
            djvu = folder / '真实多页.djvu'; djvu.write_bytes(tar.extractfile(name).read())
        result = run('--inspect', djvu)
        assert result['pageCount'] == 57 and len(result['chapters']) > 10
        for page in [1, 5, 57]:
            out = folder / f'djvu{page}.png'
            run('--render-page', djvu, page, out)
            with Image.open(out) as rendered:
                assert max(rendered.size) <= 4000 and min(rendered.size) > 1000
                assert rendered.convert('L').getextrema()[0] < 100
        checks.append('上游真实 57 页 DjVu 页数/原生目录和首中末页解码')
        original = djvu.read_bytes()
        run('--apply-draft', djvu, edit)
        assert run('--inspect', djvu)['chapters'] == chapters and djvu.read_bytes() == original
        checks.append('DjVu 编辑目录旁存重读且原文档不变')
        bad = folder / '坏.djvu'; bad.write_bytes(b'not a DjVu')
        run('--inspect', bad, ok=False)
        bad = folder / '坏.tiff'; bad.write_bytes(b'not TIFF')
        run('--inspect', bad, ok=False)
        checks.append('损坏 DjVu / TIFF 返回明确错误')
        empty = []
        run('--apply-draft', renamed, draft(edit, empty, metadata))
        result = run('--inspect', renamed)
        assert not result['chapters'] and result['fallbackNavigation'] == ['封面']
        checks.append('删除全部目录后回退基础信息，不自动列正文页码')
    print(json.dumps({'passed': len(checks), 'checks': checks}, ensure_ascii=False, indent=2))

if __name__ == '__main__': main()
