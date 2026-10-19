"""Compare native decoding with the pinned upstream algorithm using generated files.

Pillow is needed only for this test suite, not by the application.
"""
from pathlib import Path
import hashlib
import io
import json
import struct
import subprocess
import sys
import tempfile
import zipfile
import zlib
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).parent / 'Reference'))
import pdg_decoder as reference

EXE = ROOT / 'UVZ Reader Lab.app/Contents/MacOS/UVZReaderLab'

def command(*args):
    return subprocess.run([str(EXE), *map(str, args)], capture_output=True, text=True, timeout=25)

def header(kind, length, width=64, height=96, text=False):
    result = bytearray(140)
    result[:2] = b'HH'
    result[15] = kind
    result[20] = 24
    struct.pack_into('<HH', result, 16, width, height)
    struct.pack_into('<II', result, 24, 140, length)
    result[64:112] = bytes(range(48))
    if text: result[2:4] = b'\x02F'
    return result

def encrypt_block(raw, keys):
    values = list(struct.unpack('<4I', raw))
    for round_number in reversed(range(16)):
        total = (0xE3779B90 + round_number * 0x61C88647) & 0xffffffff
        v = values
        v[0] = (v[0] + ((v[1] + total) ^ (keys[1] + (v[1] >> 5)) ^ (keys[0] + ((v[1] << 4) & 0xffffffff)))) & 0xffffffff
        v[1] = (v[1] + ((v[2] + total) ^ (keys[2] + ((v[2] << 4) & 0xffffffff)) ^ (keys[3] + (v[2] >> 5)))) & 0xffffffff
        v[2] = (v[2] + ((v[3] + total) ^ (keys[3] + (v[3] >> 5)) ^ (keys[0] + ((v[3] << 4) & 0xffffffff)))) & 0xffffffff
        v[3] = (v[3] + ((v[0] + total) ^ (keys[1] + (v[0] >> 5)) ^ (keys[2] + ((v[0] << 4) & 0xffffffff)))) & 0xffffffff
    return struct.pack('<4I', *values)

def encode(payload, h):
    kind = h[15]
    if kind == 0: return payload
    if kind == 1: return bytes(value ^ b'3.141592'[i % 8] for i, value in enumerate(payload))
    if 2 <= kind <= 5:
        keys = bytearray(hashlib.md5(h[64:112]).digest())
        mix = {3: b'SUPERSTA', 4: b'SSREADER', 5: b'e#fgF%3*'}.get(kind)
        if mix:
            for i in range(8): keys[i] ^= mix[i]
        words = struct.unpack('<4I', keys)
        encoded = bytearray(payload)
        for at in range(0, len(encoded) & ~15, 16): encoded[at:at + 16] = encrypt_block(encoded[at:at + 16], words)
        return bytes(encoded)
    captured = []
    originals = [reference._op_48b80, reference._op_48bf0, reference._op_48cc0]
    try:
        reference._op_48b80 = reference._op_48bf0 = reference._op_48cc0 = lambda a, b, out: captured.append((a, b))
        reference._decode_type_11_to_1c(h, payload)
    finally:
        reference._op_48b80, reference._op_48bf0, reference._op_48cc0 = originals
    a, b = captured[0]
    out = bytearray(payload)
    if kind <= 0x14 and a != b:
        lo, hi = sorted((a, b)); offset = 19 if hi - lo == 17 else 17
        out[lo] = payload[hi] ^ payload[lo + offset]
        out[hi] = payload[lo] ^ payload[hi + offset]
    elif kind <= 0x18: originals[1](a, b, out)
    elif a != b:
        middle = (a >> 1) + (b >> 1)
        out[a] = ((out[a] + b) & 255) ^ (out[middle] if middle != a else 0)
    return bytes(out)

def simple_pdf():
    # Self-contained two-page PDF; distinct media boxes test physical-page expansion.
    objects = [b'<< /Type /Catalog /Pages 2 0 R >>', b'<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>',
               b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 120 180] /Resources << >> /Contents 5 0 R >>',
               b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 180 120] /Resources << >> /Contents 5 0 R >>',
               b'<< /Length 0 >>\nstream\n\nendstream']
    result = bytearray(b'%PDF-1.4\n'); offsets = [0]
    for i, obj in enumerate(objects, 1):
        offsets.append(len(result)); result.extend(f'{i} 0 obj\n'.encode() + obj + b'\nendobj\n')
    start = len(result)
    result.extend(f'xref\n0 {len(offsets)}\n0000000000 65535 f \n'.encode())
    for offset in offsets[1:]: result.extend(f'{offset:010d} 00000 n \n'.encode())
    result.extend(f'trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{start}\n%%EOF\n'.encode())
    return bytes(result)

def main():
    checks = []
    with tempfile.TemporaryDirectory(prefix='uvz-native-decoder-') as folder:
        tmp = Path(folder)
        image = Image.new('RGB', (64, 96))
        image.putdata([(x * 3 % 256, y * 2 % 256, (x + y) % 256) for y in range(96) for x in range(64)])
        buffer = io.BytesIO(); image.save(buffer, format='PNG')
        payload = buffer.getvalue().ljust(8192, b'\0')
        for kind in [0, 1, 2, 3, 4, 5, *range(0x11, 0x1d)]:
            h = header(kind, len(payload)); data = bytes(h) + encode(payload, h)
            decoded, _ = reference.pdg_decode_pure_bytes(data, 64, 96)
            assert decoded == payload, f'bad generated fixture: {kind:#x}'
            src = tmp / f'{kind:02x}.pdg'; dest = tmp / f'{kind:02x}.png'; src.write_bytes(data)
            result = command('--decode-page', src, dest)
            assert result.returncode == 0, (kind, result.stderr)
            assert dest.read_bytes() == payload, f'native payload mismatch: {kind:#x}'
            checks.append(f'PDG {kind:#04x} 解码与独立参考实现一致')

        def code(table, value):
            length, encoded, _ = next(item for item in table if item[2] == value)
            return f'{encoded:0{length}b}'
        horizontal_white = code(reference._MODE_CODES, 2) + code(reference._RUN_WHITE_CODES, 32) + code(reference._RUN_BLACK_CODES, 192) + code(reference._RUN_BLACK_CODES, 32)
        horizontal_black = code(reference._MODE_CODES, 3) + code(reference._MODE_CODES, 2) + code(reference._RUN_BLACK_CODES, 32) + code(reference._RUN_WHITE_CODES, 192) + code(reference._RUN_WHITE_CODES, 32)
        bitstreams = [('white', '11' * 24, 24), ('black', '0001' * 24, 24),
                      ('horizontal-white', horizontal_white, 1), ('horizontal-black', horizontal_black, 1)]
        for positive, negative in [(4, 7), (5, 8), (6, 9)]:
            bitstreams.append((f'vertical-{positive}-{negative}', '11' + code(reference._MODE_CODES, positive) + code(reference._MODE_CODES, negative) + '1', 2))
        for name, bits, height in bitstreams:
            bits += '0' * ((8 - len(bits) % 8) % 8)
            stream = bytes(int(bits[i:i + 8], 2) for i in range(0, len(bits), 8))
            h = header(0, len(stream), width=256, height=height); h[20] = 1
            data = bytes(h) + stream
            expected, _ = reference.pdg_decode_pure_bytes(data, 256, height)
            src = tmp / f'{name}.pdg'; dest = tmp / f'{name}.bmp'; src.write_bytes(data)
            result = command('--decode-page', src, dest)
            assert result.returncode == 0, result.stderr
            assert dest.read_bytes() == expected, name
            checks.append(f'黑白位流 {name} 与参考解码像素一致')

        pdf = simple_pdf()
        for compressed in [False, True]:
            packed = zlib.compress(pdf) if compressed else pdf
            h = header(0, len(packed), text=True)
            path = tmp / f'text-{compressed}.zip'
            with zipfile.ZipFile(path, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
                archive.writestr('000001.pdg', bytes(h) + packed)
                archive.writestr('Bookcontents.dat', '第二页|01|2|0|6'.encode())
            result = command('--verify', path)
            assert result.returncode == 0, (result.stdout, result.stderr)
            report = json.loads(result.stdout)
            assert report['pageCount'] == report['renderedPages'] == 2, report
            assert report['chapters'][0]['page'] == 2, report
            checks.append(f'文本 PDG（压缩={compressed}）的 PDF 分页、渲染和目录页码')

        src = tmp / 'bad.pdg'; dest = tmp / 'bad.png'
        for change in [lambda h: struct.pack_into('<I', h, 24, 0xffffffff), lambda h: h.__setitem__(56, 1), lambda h: h.__setitem__(15, 0xff)]:
            h = header(0, len(payload)); change(h); src.write_bytes(h + payload)
            result = command('--decode-page', src, dest)
            assert result.returncode != 0, 'malformed PDG accepted'
        checks.append('异常范围、预处理与不支持编码被拒绝')
    print(json.dumps({'passed': len(checks), 'checks': checks}, ensure_ascii=False, indent=2))

if __name__ == '__main__': main()
