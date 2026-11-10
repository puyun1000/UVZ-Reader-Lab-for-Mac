"""Independent read-back of adjusted copies in each supported file family."""
from pathlib import Path
import io
import json
import subprocess
import tarfile
import tempfile
import zipfile

from PIL import Image, ImageDraw
from pypdf import PdfReader, PdfWriter
from reportlab.pdfgen import canvas

root = Path(__file__).resolve().parents[1]
app = root / 'UVZ Reader Lab.app'
exe = app / 'Contents/MacOS/UVZReaderLab'
checks = []
defaults = dict(rotation=0, left=0, right=0, top=0, bottom=0,
                automaticContrast=False, brightness=0, contrast=1, gamma=1)


def call(*arguments, ok=True):
    result = subprocess.run([str(exe), *map(str, arguments)], capture_output=True, text=True, timeout=180)
    assert (result.returncode == 0) == ok, (arguments, result.stderr)
    return json.loads(result.stdout) if result.stdout and result.returncode == 0 else result.stderr


def adjust(source, target, pages, ok=True, **options):
    original = source.read_bytes(), source.stat().st_mtime_ns
    result = call('--adjust-pages', source, target, pages, json.dumps(defaults | options), ok=ok)
    assert (source.read_bytes(), source.stat().st_mtime_ns) == original
    return result


def image(path, page, folder):
    destination = folder / 'render.png'
    call('--render-page', path, page, destination)
    return Image.open(destination).convert('RGB')


def assert_book_identity(source, target):
    original, result = [call('--inspect', url) for url in (source, target)]
    for field in ('metadata', 'chapters', 'pageCount'):
        assert original[field] == result[field], (field, original[field], result[field])


with tempfile.TemporaryDirectory(prefix='uvz-adjust-') as temp:
    work = Path(temp)
    raw = work / 'raw.pdf'
    pdf = work / 'source.pdf'
    drawing = canvas.Canvas(str(raw), pagesize=(400, 600))
    drawing.setTitle('Adjusted book')
    drawing.setAuthor('Sample author')
    for n in range(1, 5):
        drawing.drawString(80, 310, f'Text on page {n}')
        drawing.setFillColorRGB(0.7, 0.7, 0.7)
        drawing.rect(55, 85, 130, 170, fill=1)
        drawing.linkURL('https://example.com', (55, 100, 120, 140))
        drawing.showPage()
    drawing.save()
    document = PdfWriter(clone_from=raw)
    for page in document.pages:
        page.cropbox.lower_left = (40, 70)
        page.cropbox.upper_right = (360, 570)
    document.pages[1].rotate(90)
    document.add_outline_item('Adjusted', 1)
    document.add_outline_item('Unchanged', 2)
    document.write(pdf)

    vector = work / 'vector.pdf'
    assert adjust(pdf, vector, '2', rotation=1, left=0.1, top=0.2)['adjusted'] == 1
    assert_book_identity(pdf, vector)
    before, after = PdfReader(pdf), PdfReader(vector)
    assert after.pages[1].rotation == 180 and after.pages[0].rotation == 0
    assert len(after.pages[1]['/Annots']) == 1
    assert [p.extract_text() for p in after.pages] == [p.extract_text() for p in before.pages]
    assert tuple(after.pages[1].mediabox) == tuple(before.pages[1].mediabox)
    box = after.pages[1].cropbox
    assert abs(float(box.width) - 256) < 0.2 and abs(float(box.height) - 450) < 0.2, box
    checks.append('PDF nonzero CropBox and inherited orientation, text and links retained')

    raster = work / 'tone.pdf'
    assert adjust(pdf, raster, '1,3-4', brightness=-0.18, contrast=1.25)['adjusted'] == 3
    assert_book_identity(pdf, raster)
    edited = PdfReader(raster)
    assert not edited.pages[0].extract_text() and edited.pages[1].extract_text().strip() == before.pages[1].extract_text().strip()
    assert image(raster, 1, work).getpixel((20, 20))[0] < image(pdf, 1, work).getpixel((20, 20))[0] - 10
    checks.append('PDF disjoint tonal edits visibly saved and only selected pages rasterized')

    png = io.BytesIO()
    cover = Image.new('RGB', (160, 240), 'white')
    paint = ImageDraw.Draw(cover)
    paint.rectangle((0, 0, 79, 119), fill='red')
    paint.rectangle((80, 0, 159, 119), fill='green')
    cover.save(png, 'PNG', dpi=(240, 300))
    book = work / 'source.uvz'
    with zipfile.ZipFile(book, 'w', zipfile.ZIP_DEFLATED) as archive:
        archive.writestr('Book/cov001.pdg', png.getvalue())
        archive.writestr('Book/000001_4.pdg', pdf.read_bytes())
        archive.writestr('Book/BookInfo.dat', '书名=示例\n作者=示例作者')
        archive.writestr('Book/Bookcontents.dat', '目标|01|2|0|6\r\n')
        archive.writestr('Book/other.txt', 'Retain unrelated data')
        archive.comment = b'Fixture archive comment'
    adjusted = work / 'cover.uvz'
    adjust(book, adjusted, '1', rotation=1, top=0.1)
    assert_book_identity(book, adjusted)
    with zipfile.ZipFile(adjusted) as archive, zipfile.ZipFile(book) as original:
        assert archive.testzip() is None and archive.comment == original.comment
        assert all(archive.read(n) == original.read(n) for n in original.namelist() if not n.endswith('cov001.pdg'))
        output = Image.open(io.BytesIO(archive.read('Book/cov001.pdg')))
        assert output.size == (216, 160) and output.getpixel((200, 30))[0] > 230
        assert all(abs(a - b) < 1 for a, b in zip(output.info['dpi'], (300, 240)))
    checks.append('UVZ preserves unrelated archive members and writes cropped, rotated cover pixels')

    adjusted = work / 'segment.uvz'
    adjust(book, adjusted, '3', rotation=1, contrast=1.5)
    assert_book_identity(book, adjusted)
    with zipfile.ZipFile(adjusted) as archive:
        segment = PdfReader(io.BytesIO(archive.read('Book/000001_4.pdg')))
        assert len(segment.pages) == 4
        assert not segment.pages[1].extract_text()
        assert segment.pages[0].extract_text().strip() == before.pages[0].extract_text().strip()
        assert segment.pages[2].extract_text().strip() == before.pages[2].extract_text().strip()
    checks.append('UVZ text-PDG segment keeps unaffected pages and original logical numbering')

    djvu = work / 'source.djvu'
    with tarfile.open(root / 'ThirdParty/DjVuLibre/djvulibre-3.5.30.tar.gz') as vendor:
        djvu.write_bytes(vendor.extractfile('djvulibre-3.5.30/doc/djvulibre-book-en.djvu').read())
    plan = work / 'outline.json'
    plan.write_text(json.dumps(dict(metadata={'书名':'DjVu 编辑样本','作者':'测试作者'}, chapters=[dict(title='验证目录', page=2, level=0)])))
    call('--apply-draft', djvu, plan)
    turned = work / 'turned.djvu'
    adjust(djvu, turned, '1', rotation=1)
    assert_book_identity(djvu, turned)
    first = image(djvu, 1, work)
    second = image(djvu, 2, work)
    assert image(turned, 1, work).size == first.size[::-1]
    checks.append('DjVu native rotation and original bookmark targets')

    scanned = work / 'scanned.djvu'
    adjust(djvu, scanned, '1,3', rotation=1, left=0.05, top=0.1, contrast=1.18)
    assert_book_identity(djvu, scanned)
    assert image(scanned, 1, work).size == (first.height-int(first.height*0.1), first.width-int(first.width*0.05))
    assert image(scanned, 2, work).tobytes() == second.tobytes()
    checks.append('DjVu crop and re-encode selected pages, leaving unchanged page pixels exact')

    single = work / 'single.djvu'
    ppm = work / 'colored.ppm'
    cover.save(ppm, 'PPM')
    subprocess.run([str(app / 'Contents/Helpers/c44'), '-dpi', '240', str(ppm), str(single)],
                   check=True, capture_output=True, timeout=30)
    single_adjusted = work / 'single-copy.djvu'
    adjust(single, single_adjusted, '1', rotation=1, top=0.1)
    result = image(single_adjusted, 1, work)
    assert result.size == (216, 160)
    red = result.getpixel((200, 30))
    assert red[0] > 175 and red[1] < 90 and red[2] < 90, red
    checks.append('Standalone DjVu crop and clockwise rotation preserve visible orientation')

    existing = vector.read_bytes()
    assert '已存在' in adjust(pdf, vector, '1', ok=False, rotation=1)
    assert vector.read_bytes() == existing
    target = work / 'invalid.pdf'
    for expression in ('0', '3-2', '1,,2', '5'):
        adjust(pdf, target, expression, ok=False, rotation=1)
    adjust(pdf, target, '1', ok=False, right=0.95)
    (work / 'invalid.pdf.uvzmeta').mkdir()
    assert '已存在' in adjust(pdf, target, '1', ok=False, rotation=1)
    assert not target.exists() and not list(work.glob('.uvz-adjust-*'))
    checks.append('Invalid page ranges, crop and existing targets leave source and destination intact')

print(json.dumps(dict(passed=len(checks), checks=checks), ensure_ascii=False, indent=2))
