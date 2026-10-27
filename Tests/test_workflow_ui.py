"""Native interaction regression on disposable books only."""
from pathlib import Path
import io,json,subprocess,tempfile,zipfile,sys
from PIL import Image
r=Path(__file__).resolve().parents[1];exe=r/'UVZ Reader Lab.app/Contents/MacOS/UVZReaderLab'
with tempfile.TemporaryDirectory(prefix='uvz-workflow017-') as td:
 f=Path(td);b=io.BytesIO();Image.new('RGB',(120,180),'white').save(b,'PNG')
 with zipfile.ZipFile(f/'测试书_12345678.uvz','w') as z:
  for name in ['cov001','000001','000002','000003']:z.writestr(name+'.pdg',b.getvalue())
  z.writestr('BookInfo.dat','书名=测试书\n作者=原作者\n出版社=示例出版社\n出版日期=2020.01\nSS号=12345678\n')
  z.writestr('Bookcontents.dat','原目录|01|1|0|6\n')
 out=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else f/'report.json'
 p=subprocess.run([str(exe),'--workflow-ui-test',str(f),str(out)],capture_output=True,text=True,timeout=60)
 assert p.returncode==0,(p.stdout,p.stderr,out.read_text() if out.exists() else '')
 report=json.loads(out.read_text());assert report['passed'];print(json.dumps(report,ensure_ascii=False,indent=2))
