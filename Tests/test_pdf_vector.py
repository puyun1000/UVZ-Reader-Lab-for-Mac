"""Vector source display at output scale, independent of the OCR bitmap."""
from pathlib import Path
import json,subprocess,tempfile,zipfile
from reportlab.pdfgen import canvas
r=Path(__file__).resolve().parents[1];exe=r/'UVZ Reader Lab.app/Contents/MacOS/UVZReaderLab';checks=[]
with tempfile.TemporaryDirectory(prefix='uvz-vector-') as t:
 p=Path(t);source=p/'vector.pdf';c=canvas.Canvas(str(source),pagesize=(547,754))
 for i in range(6):
  c.setFont('Helvetica',7);c.drawString(40,700,'Small vector letters at every magnification: 0123456789')
  c.setLineWidth(.12);c.line(30,680,510,680);c.showPage()
 c.save();raw=source.read_bytes()
 for name in ['vector.pdf','vector.pdg','vector.uvz']:
  f=p/name
  if name.endswith('pdg'):f.write_bytes(raw)
  if name.endswith('uvz'):
   with zipfile.ZipFile(f,'w') as z:z.writestr('000001.pdg',raw)
  result=subprocess.run([str(exe),'--pdf-vector-test',str(f),str(p/(name+'.png'))],capture_output=True,text=True,timeout=60);assert result.returncode==0,result.stderr
  result=json.loads(result.stdout);assert result['passed']==3 and result['renders'][-1]['width']>=result['renders'][0]['width']*4-3
  checks.append(name+': 2x, 4x, 8x match direct PDFKit output and retain vector source')
 result=subprocess.run([str(exe),'--pdf-reader-display-test',str(source)],capture_output=True,text=True,timeout=90);assert result.returncode==0,(result.stdout,result.stderr)
 result=json.loads(result.stdout);assert result['passed']==4 and result['vectorLayerInstalled'];checks.append('Actual reading window installs vector display through rotation, inversion and fit-width')
 assert source.read_bytes()==raw;checks.append('Original PDF bytes remain unchanged')
print(json.dumps(dict(passed=len(checks),checks=checks),indent=2))
