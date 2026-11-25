"""Information-only saves, companion moves, dates and structured copyright extraction."""
from pathlib import Path
import io, json, os, subprocess, tempfile, time, zipfile, struct
from PIL import Image
from pypdf import PdfWriter

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / 'UVZ Reader Lab.app/Contents/MacOS/UVZReaderLab'

def run(*args, ok=True):
    result = subprocess.run([str(EXE), *map(str, args)], capture_output=True, text=True, timeout=60)
    if ok:
        assert result.returncode == 0, result.stderr
        return json.loads(result.stdout)
    assert result.returncode != 0

def dates(path):
    stat = path.stat()
    return stat.st_birthtime, stat.st_mtime

def unchanged_dates(path, before):
    assert all(abs(a-b) < 0.001 for a,b in zip(dates(path), before)), (dates(path), before)

def fresh_timestamp(archive, name, start):
    entry = archive.getinfo(name)
    assert start - 2 <= time.mktime((*entry.date_time, 0, 0, -1)) <= time.time() + 1, entry.date_time
    kind, size, flags, modified = struct.unpack('<HHBI', entry.extra)
    assert (kind, size, flags) == (0x5455, 5, 1)
    assert start - 1 <= modified <= time.time() + 1, modified
    archive.fp.seek(entry.header_offset + 10)
    dos_time, dos_date = struct.unpack('<HH', archive.fp.read(4))
    year, month, day, hour, minute, second = entry.date_time
    assert dos_time == (hour << 11) | (minute << 5) | (second // 2)
    assert dos_date == ((year - 1980) << 9) | (month << 5) | day
    archive.fp.seek(entry.header_offset + 26)
    name_length, extra_length = struct.unpack('<HH', archive.fp.read(4))
    archive.fp.read(name_length)
    assert archive.fp.read(extra_length) == entry.extra

def main():
    checks = []
    with tempfile.TemporaryDirectory(prefix='uvz-info07-') as folder:
        folder = Path(folder); png = io.BytesIO(); Image.new('RGB', (120,180), 'white').save(png, 'PNG')
        book = folder/'原书名_12345678.uvz'
        old_member_date = (2001, 2, 3, 4, 5, 6)
        contents = '第一章|01|1|0|6\r\n子目录|0101|2|0|6\r\n'.encode('gb18030')
        with zipfile.ZipFile(book,'w',zipfile.ZIP_DEFLATED) as z:
            for name in ['cov001','bok001','leg001','fow001','!00001','000001','000002']:
                z.writestr(zipfile.ZipInfo(name+'.pdg', old_member_date), png.getvalue())
            z.writestr(zipfile.ZipInfo('Bookcontents.dat', old_member_date), contents)
            z.writestr(zipfile.ZipInfo('BookInfo.dat', old_member_date),'书名=原书名\r\n未知字段=原样保留'.encode('gb18030'))
        os.utime(book, (1_500_000_000,1_500_000_000)); before_dates = dates(book)
        report = run('--inspect', book)
        assert report['fallbackNavigation'] == ['封面','书名','版权','前言','目录','第一章']
        checks.append('有正文电子目录时仍列出五类实际前置入口')
        complete = folder/'目录类型.uvz'
        page_names = ['cov001','bok001','leg001','fow001','fow002','!00001','000001','att001','bac001']
        with zipfile.ZipFile(complete, 'w') as z:
            for name in page_names:
                z.writestr(name+'.pdg', png.getvalue())
        original = complete.read_bytes()
        assert run('--inspect', complete)['fallbackNavigation'] == ['封面','书名','版权','前言','目录','正文','附录','封底']
        assert complete.read_bytes() == original
        checks.append('无电子目录时按页序给实际存在的八种类型各补一个入口')
        plan = folder/'sections.json'
        chapters = [
            dict(title='导读分组', page=0, level=0),
            dict(title='编校说明', page=5, level=1),
            dict(title='目录总目', page=6, level=0),
            dict(title='第一篇', page=7, level=0),
            dict(title='补遗', page=8, level=0),
            dict(title='书末', page=9, level=0),
        ]
        plan.write_text(json.dumps(dict(chapters=chapters, metadata={}), ensure_ascii=False))
        run('--apply-draft', complete, plan, '--contents-only')
        report_sections = run('--inspect', complete)
        assert report_sections['chapters'] == chapters
        assert report_sections['fallbackNavigation'] == ['封面','书名','版权','导读分组','目录总目','第一篇','补遗','书末']
        checks.append('按真实目标类型去重，前言子项保留层级，目录、正文、附录和封底均采用实际书签')

        partial = folder/'缺页书签.uvz'
        with zipfile.ZipFile(partial, 'w') as z:
            for name in ['fow002','000001','bac001']:
                z.writestr(name+'.pdg', png.getvalue())
            z.writestr('Bookcontents.dat', '原序|01|1|0|4\n正文标题|02|1|0|6')
        partial_report = run('--inspect', partial)
        assert partial_report['fallbackNavigation'] == ['原序 · 未定位','正文标题','封底']
        assert partial_report['unresolvedTargets'] == ['fow1', None]
        checks.append('旧书签目标暂未定位仍按原类型识别，其他类型继续补缺')

        change = folder/'change.json'
        metadata = dict(report['metadata'], ISBN='9780306406157',作者='测试作者',出版日期='2026.03',丛书名='研究丛书')
        change.write_text(json.dumps(dict(stem='新书名',metadata=metadata),ensure_ascii=False))
        saving_at = time.time()
        renamed = Path(run('--update-information',book,change)['path'])
        assert renamed.name=='新书名.uvz' and not book.exists()
        unchanged_dates(renamed,before_dates)
        with zipfile.ZipFile(renamed) as z:
            assert z.read('Bookcontents.dat')==contents
            assert z.getinfo('Bookcontents.dat').date_time == old_member_date
            fresh_timestamp(z, 'BookInfo.dat', saving_at)
            for name in ['cov001','bok001','leg001','fow001','!00001','000001','000002']:
                assert z.read(name+'.pdg')==png.getvalue()
                assert z.getinfo(name+'.pdg').date_time == old_member_date
        checks.append('信息保存写入 BookInfo 的实际时间，其他 ZIP 条目的日期保留')
        reread=run('--inspect',renamed)
        assert reread['metadata']==metadata and len(reread['chapters'])==2
        checks.append('信息保存和改名保留外部创建修改日期、原始目录字节、图像与自定义字段')
        # A directory save must preserve even the original metadata encoding and bytes.
        with zipfile.ZipFile(renamed) as z:
            original_info=z.read('BookInfo.dat')
            original_info_entry=z.getinfo('BookInfo.dat')
        draft=folder/'draft.json'; draft.write_text(json.dumps(dict(chapters=[dict(title='只改目录',page=6,level=0)],metadata={'书名':'不应写入'})))
        saving_at = time.time()
        run('--apply-draft',renamed,draft,'--contents-only')
        with zipfile.ZipFile(renamed) as z:
            assert z.read('BookInfo.dat')==original_info
            entry=z.getinfo('BookInfo.dat')
            assert (entry.date_time, entry.extra)==(original_info_entry.date_time, original_info_entry.extra)
            fresh_timestamp(z, 'Bookcontents.dat', saving_at)
        checks.append('目录保存写入 Bookcontents 的实际时间，BookInfo 原时间保留')
        unchanged_dates(renamed,before_dates)
        checks.append('独立目录保存不重写 BookInfo，且保留日期')
        # Turning off date preservation must update modification date.
        change.write_text(json.dumps(dict(stem='新书名',metadata=metadata)))
        run('--update-information',renamed,change,'--update-dates')
        assert renamed.stat().st_mtime>1_700_000_000
        checks.append('日期选项关闭时更新修改日期')
        # PDF with a native outline, then metadata-only companion creation.
        pdf=folder/'原文.pdf'; w=PdfWriter(); w.add_blank_page(width=320,height=480);w.add_outline_item('原生目录',0)
        with pdf.open('wb') as out:w.write(out)
        original_pdf=pdf.read_bytes(); os.utime(pdf,(1_500_000_000,1_500_000_000));pdf_dates=dates(pdf)
        change.write_text(json.dumps(dict(stem='原文',metadata={'书名':'PDF测试','ISBN':'9780306406157'})))
        run('--update-information',pdf,change)
        sidecar=Path(str(pdf)+'.uvzmeta'); assert not sidecar.exists()
        assert run('--inspect',pdf)['chapters'][0]['title']=='原生目录'
        unchanged_dates(pdf,pdf_dates)
        checks.append('PDF 信息内嵌保存，不生成旁置文件，保留原生目录与日期')
        change.write_text(json.dumps(dict(stem='中文PDF改名',metadata={'书名':'更正书名','ISBN':'9780306406157'})))
        newpdf=Path(run('--update-information',pdf,change)['path']);newsidecar=Path(str(newpdf)+'.uvzmeta')
        assert not pdf.exists() and not sidecar.exists() and not newsidecar.exists()
        saved_pdf=newpdf.read_bytes()
        unchanged_dates(newpdf,pdf_dates)
        assert run('--inspect',newpdf)['metadata']['书名']=='更正书名'
        checks.append('PDF 中文改名同步写入信息，无旁置文件，保持日期并可重读')
        occupied=folder/'已存在.pdf';occupied.write_bytes(b'existing')
        run('--rename-book',newpdf,'已存在',ok=False)
        conflict=folder/'目录冲突.pdf.uvzmeta';conflict.mkdir();(conflict/'keep').write_bytes(b'keep')
        run('--rename-book',newpdf,'目录冲突',ok=False)
        run('--rename-book',newpdf,'../逃逸',ok=False)
        assert newpdf.read_bytes()==saved_pdf and occupied.read_bytes()==b'existing' and (conflict/'keep').read_bytes()==b'keep'
        checks.append('拒绝覆盖 PDF 与已有旁存目录，拒绝路径跳转，失败保留源文件')
        # Extraction includes plain labels, OCR split labels, and noise that must not become author.
        raw=folder/'copyright.txt';raw.write_text('图书在版编目（CIP）数据\n测试书 / 张三著. — 北京 : 示例出版社, 2026.3\n（研究丛书）\nISBN 978-0-306-40615-7\n书名 测试书\n著\n者 张三\n责任编辑 李四\n装帧设计 王五\n出版发行\n示例出版社\n2026年3月第1版\n页数 268页\nSS号 12345678\nDXID 000123456789')
        info=run('--extract-metadata',raw)['metadata']
        assert info['ISBN']=='9780306406157' and info['作者']=='张三' and info['出版社']=='示例出版社' and info['书名']=='测试书'
        assert info['出版日期']=='2026.03' and info['页数']=='268' and info['SS号']=='12345678' and info['DX号']=='000123456789'
        checks.append('版权页无冒号与跨行标签提取，排除编辑设计人员干扰并规范各字段')
        raw.write_text('图书在版编目(CIP)数据\n测试书 / 张三著. — 南京：江\n苏人民出版社，2026.3\nISBN 9780306406157')
        assert run('--extract-metadata',raw)['metadata']['出版社']=='江苏人民出版社'
        checks.append('跨行 CIP 出版社保留完整名称')
        raw.write_text('ISBN 9780306406158\n责任编辑 李四\n定价 268元\n字数 290千字')
        info=run('--extract-metadata',raw)['metadata'];assert not any(k in info for k in ['ISBN','作者','页数'])
        checks.append('无校验依据的 ISBN、无作者与无页数均留空')
    print(json.dumps(dict(passed=len(checks),checks=checks),ensure_ascii=False,indent=2))

if __name__=='__main__':main()
