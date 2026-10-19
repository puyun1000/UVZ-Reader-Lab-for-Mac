"""Read-only book-corpus sampling: python3 Tests/test_corpus.py /book/folder

Uses the same fixed seed as the 0.3 release verification. ZIP selection covers
sampled HH variants, then adds three random books with and without contents.
Six random PDFs are sampled at 12 evenly spaced pages each. No books are saved.
"""
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import json
import random
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / 'UVZ Reader Lab.app/Contents/MacOS/UVZReaderLab'

def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    folder = Path(sys.argv[1]).resolve()
    rng = random.Random(20261016)
    books, selected, covered = [], [], set()
    for path in sorted(folder.rglob('*.zip')):
        with zipfile.ZipFile(path) as z:
            pages = [i for i in z.infolist() if i.filename.lower().endswith('.pdg') and '__MACOSX' not in i.filename]
            contents = any(i.filename.lower().endswith(('bookcontents.dat', 'catalog.dat', 'catalog.xml')) for i in z.infolist())
            kinds = set()
            for index in sorted({0, len(pages)//2, len(pages)-1}) if pages else []:
                with z.open(pages[index]) as page:
                    head = page.read(140)
                if head.startswith(b'HH') and len(head) >= 57:
                    kind = 'HH-text' if head[3] == 0x46 else f'HH-{head[15]:02x}'
                    kinds.add(kind + f'/flag{head[56]:02x}')
            books.append((path, contents))
            if kinds - covered:
                selected.append((path, '--verify'))
                covered |= kinds
    for wanted in [True, False]:
        candidates = [p for p, toc in books if toc == wanted and p not in [s[0] for s in selected]]
        selected.extend((p, '--verify') for p in rng.sample(candidates, min(3, len(candidates))))
    pdfs = sorted(folder.rglob('*.pdf'))
    selected.extend((p, '--sample-verify') for p in rng.sample(pdfs, min(6, len(pdfs))))
    def check(item):
        path, mode = item
        before = (path.stat().st_size, path.stat().st_mtime_ns)
        result = subprocess.run([str(EXE), mode, str(path)], capture_output=True, text=True, timeout=360)
        try:
            report = json.loads(result.stdout)
        except ValueError:
            report = {}
        unchanged = before == (path.stat().st_size, path.stat().st_mtime_ns)
        row = dict(file=path.name, mode=mode, success=result.returncode == 0, pages=report.get('pageCount'),
                   rendered=report.get('renderedPages'), chapters=len(report.get('chapters', [])),
                   failures=report.get('failures', []), originalUnchanged=unchanged,
                   error=result.stderr[-2500:] if result.returncode else '')
        print(('PASS ' if row['success'] else 'FAIL ') + path.name, file=sys.stderr, flush=True)
        return row
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(check, selected))
    report = dict(seed=20261016, books=len(results), passed=sum(r['success'] for r in results),
                  renderedPages=sum(r['rendered'] or 0 for r in results),
                  allOriginalsUnchanged=all(r['originalUnchanged'] for r in results), results=results)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    if report['passed'] != report['books'] or not report['allOriginalsUnchanged']:
        raise SystemExit(1)

if __name__ == '__main__':
    main()
