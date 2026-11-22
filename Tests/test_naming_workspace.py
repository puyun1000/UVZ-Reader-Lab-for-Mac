"""The naming workbench classifies actual drawing precision and round trips a draft."""
import json
from pathlib import Path
import subprocess
import tempfile

from PIL import Image
from reportlab.pdfgen import canvas

EXE = Path(__file__).resolve().parents[1] / 'UVZ Reader Lab.app/Contents/MacOS/UVZReaderLab'


def run(*args):
    proc = subprocess.run([EXE, *args], capture_output=True, text=True, check=True)
    return json.loads(proc.stdout)


with tempfile.TemporaryDirectory(prefix='uvz-naming-workspace-') as td:
    root = Path(td)
    books = root / 'books'
    books.mkdir()
    image = root / 'scan.jpg'
    Image.new('RGB', (2480, 3508), (234, 232, 226)).save(image)

    for kind in ('vector', 'scan', 'mixed', 'uncertain'):
        pdf = canvas.Canvas(str(books / f'{kind}.pdf'), pagesize=(595, 842))
        for i in range(6):
            if kind == 'scan' or (kind == 'mixed' and i % 2 == 0):
                if not pdf.hasForm('scan'):
                    pdf.beginForm('scan')
                    pdf.drawImage(str(image), 0, 0, 595, 842)
                    pdf.endForm()
                pdf.doForm('scan')
                hidden = pdf.beginText(30, 760)
                hidden.setTextRenderMode(3)
                hidden.textLines('Invisible words\nSearchable but not drawn\nMore hidden words')
                pdf.drawText(hidden)
            elif kind != 'uncertain':
                for n in range(3):
                    pdf.drawString(20, 740 - n * 18, 'Visible fine lettering and line drawings')
                pdf.line(25, 656, 540, 655)
            pdf.showPage()
        pdf.save()
    rows = {Path(row["path"]).stem: row for row in run('--batch-propose', str(books), '--no-ocr')["books"]}
    for name, expected in dict(vector='矢量精度', scan='图像页', mixed='混合页面 · 待核对', uncertain='精度待核对').items():
        assert rows[name]['proposal']['precision']['kind'] == expected, rows[name]
    assert rows['scan']['proposal']['precision']['estimatedImageDPI'] >= 295

    source = root / 'copyright.txt'
    source.write_text('''图书在版编目（CIP）数据
文献整理导论 / （英）约翰·哈里斯著；吴清和，周简译. — 北京：文津出版社，2021.8
ISBN 978-0-306-40615-7
CIP核字
著者：[英]约翰・哈里斯
译者：吴清和、周简
整理者：林知言
2021年8月第2版
修订版
形态项：XVI，312页
定价：人民币68.00元
中图法分类号：G256.1
主题词：文献学
''', encoding='utf8')
    metadata = run('--extract-metadata', str(source))['metadata']
    assert {k: metadata.get(k) for k in ('作者', '出版地', '出版日期', '版本说明', '数字版次', '页数', '原书定价', '币种', '中图法分类号', '主题词')} == {
        '作者': '（英）约翰·哈里斯著；吴清和，周简译；林知言整理', '出版地': '北京', '出版日期': '2021.08',
        '版本说明': '修订版', '数字版次': '第2版', '页数': '312', '原书定价': '68.00', '币种': 'CNY',
        '中图法分类号': 'G256.1', '主题词': '文献学',
    }, metadata
    metadata['参考文献格式'] = '文献整理导论[M]. 北京：文津出版社，2021.'
    metadata['作者'] = '(英)约翰・哈里斯著、吴清和译'
    evidence = root / 'merge.json'
    evidence.write_text(json.dumps({'original': metadata}, ensure_ascii=False))
    suggestion = run('--batch-merge', str(evidence))
    stem = suggestion['suggestedName']
    assert stem == '文献整理导论（修订版）_（英）约翰·哈里斯著；吴清和译_文津出版社_2021.08（第2版）', suggestion
    path = books / 'vector.pdf'
    before = root / 'before.png'
    subprocess.run([EXE, '--render-page', path, '3', before], check=True)
    request = root / 'save.json'
    request.write_text(json.dumps([dict(path=str(path), stem=stem+'【印前矢量】', metadata=suggestion['metadata'], fingerprint=rows['vector']['proposal']['fingerprint'])], ensure_ascii=False))
    saved = Path(run('--batch-apply', str(request))[0]['destination'])
    assert saved.name == stem + '【印前矢量】.pdf' and not path.exists()
    after = root / 'after.png'
    subprocess.run([EXE, '--render-page', saved, '3', after], check=True)
    with Image.open(before) as original, Image.open(after) as reopened:
        assert original.size == reopened.size and original.tobytes() == reopened.tobytes()
    result = run('--inspect', str(saved))['metadata']
    for key in ('作者','参考文献格式','版本说明','数字版次','原书定价','出版地','形态项'):
        assert result[key] == suggestion['metadata'][key], (key, result)
print(json.dumps(dict(passed=8, checks=['vector, scan, mixed and uncertain classifications', 'image DPI', 'explicit credits and colophon extraction', 'edition in filename', 'filename and additional metadata round trip'])))
