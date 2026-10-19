"""Integration tests against the compiled reader, using small synthetic archives."""
from pathlib import Path
import io
import json
import struct
import subprocess
import sys
import tempfile
import zipfile
import zlib

ROOT = Path(__file__).resolve().parents[1]
EXECUTABLE = ROOT / 'UVZ Reader Lab.app/Contents/MacOS/UVZReaderLab'
# A tiny valid PNG. Structural tests do not require third-party Python modules.
import base64
PNG = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jrL8AAAAASUVORK5CYII=')

def run(path, mode='--inspect'):
    result = subprocess.run([str(EXECUTABLE), mode, str(path)], capture_output=True, text=True, timeout=30)
    return result.returncode, result.stdout, result.stderr

def write(path, files, method=zipfile.ZIP_DEFLATED):
    with zipfile.ZipFile(path, 'w', compression=method) as archive:
        for name, data in files:
            archive.writestr(name, data)

def main():
    passed = []
    with tempfile.TemporaryDirectory(prefix='uvz-lab-tests-') as folder:
        root = Path(folder)
        ordered = root / 'ordered.uvz'
        names = ['cov002.pdg', '000010.pdg', 'fow002.pdg', '!00002.pdg', 'leg001.pdg',
                 'cov001.pdg', '000002.pdg', 'att001.pdg', 'bok001.pdg', '!00001.pdg', 'fow001.pdg']
        write(ordered, [(f'书籍/{name}', PNG) for name in names] + [('书籍/Bookinfo.dat', '书名=中文测试\r\n作者=测试者'.encode('gb18030'))])
        code, out, err = run(ordered)
        assert code == 0, err
        result = json.loads(out)
        assert result['title'] == '中文测试', result
        expected = ['cov001.pdg', 'bok001.pdg', 'leg001.pdg', 'fow001.pdg', 'fow002.pdg', '!00001.pdg', '!00002.pdg', '000002.pdg', '000010.pdg', 'att001.pdg', 'cov002.pdg']
        assert [p['file'] for p in result['pages']] == expected
        passed.append('中文 UTF-8 文件名、GB18030 元数据与页面排序')

        underscore = root / 'underscore.zip'
        write(underscore, [('000010_0001.pdg', PNG), ('000002_9999.pdg', PNG)])
        code, out, err = run(underscore)
        assert code == 0, err
        assert [p['number'] for p in json.loads(out)['pages']] == [2, 10]
        passed.append('下划线后缀不干扰正文页序')

        contents_text = '第一章|01|1|0|6\r\n第一节|0101|2|0|6\r\n失效项|02|999|0|6\r\n'
        contents = root / 'contents.zip'
        write(contents, [('000001.pdg', PNG), ('000002.pdg', PNG), ('Bookcontents.dat', contents_text.encode('gb18030'))])
        code, out, err = run(contents)
        assert code == 0, err
        report = json.loads(out)
        assert report['chapters'] == [{'title': '第一章', 'page': 1, 'level': 0}, {'title': '第一节', 'page': 2, 'level': 1}], report
        assert '1 条' in report['contentsNotice'], report
        passed.append('明文电子目录的层级、页码对应与失效记录处理')

        compressed = root / 'compressed-contents.zip'
        compressed_data = b'SSCNTS' + bytes(34) + zlib.compress(contents_text.encode('gb18030'))
        write(compressed, [('000001.pdg', PNG), ('000002.pdg', PNG), ('Bookcontents.dat', compressed_data)])
        code, out, err = run(compressed)
        assert code == 0, err
        assert json.loads(out)['chapters'] == report['chapters']
        passed.append('SSCNTS 目录的 40 字节头与 zlib 解压')

        multi = root / 'multi.zip'
        write(multi, [('a/000001.pdg', PNG), ('b/000002.pdg', PNG)])
        code, out, err = run(multi)
        assert code != 0 and '多个 PDG 文件夹' in err, (code, out, err)
        passed.append('多本书混装时明确拒绝')

        duplicate = root / 'duplicate.zip'
        write(duplicate, [('000001.pdg', PNG), ('000001.PDG', PNG)])
        code, out, err = run(duplicate)
        assert code != 0 and '重复页面' in err, (code, out, err)
        passed.append('大小写变体的重复页面被识别')

        truncated = root / 'truncated.zip'
        truncated.write_bytes(ordered.read_bytes()[:-10])
        code, out, err = run(truncated)
        assert code != 0 and '中央目录' in err, (code, out, err)
        passed.append('截断压缩包返回错误')

        corrupt = root / 'corrupt.zip'
        write(corrupt, [('000001.pdg', PNG)], zipfile.ZIP_STORED)
        data = bytearray(corrupt.read_bytes())
        start = 30 + struct.unpack_from('<H', data, 26)[0]
        data[start + 10] ^= 0x55
        corrupt.write_bytes(data)
        code, out, err = run(corrupt, '--verify')
        assert code != 0
        assert 'CRC' in json.loads(out)['failures'][0]['error']
        passed.append('受损页面通过 CRC 被拒绝')

        inconsistent = root / 'inconsistent.zip'
        write(inconsistent, [('000001.pdg', PNG)], zipfile.ZIP_STORED)
        data = bytearray(inconsistent.read_bytes()); data[30] ^= 1; inconsistent.write_bytes(data)
        code, out, err = run(inconsistent, '--verify')
        assert code != 0 and '文件名不一致' in json.loads(out)['failures'][0]['error']
        passed.append('本地页头与中央目录不一致时拒绝')

        encoded = root / 'encoded.zip'
        write(encoded, [('000001.pdg', b'HH' + b'\0' * 138)])
        code, out, err = run(encoded, '--verify')
        assert code != 0 and 'PDG' in json.loads(out)['failures'][0]['error']
        passed.append('无有效数据范围的 PDG 文件明确报错')

    print(json.dumps({'passed': len(passed), 'checks': passed}, ensure_ascii=False, indent=2))

if __name__ == '__main__':
    main()
