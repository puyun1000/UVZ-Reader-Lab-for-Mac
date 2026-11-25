"""Native interaction regression on disposable books only."""
from pathlib import Path
import io,json,subprocess,tempfile,zipfile,sys,zlib
from PIL import Image
from pypdf import PdfReader, PdfWriter
from pypdf.generic import Fit
r=Path(__file__).resolve().parents[1];exe=r/'UVZ Reader Lab.app/Contents/MacOS/UVZReaderLab'
with tempfile.TemporaryDirectory(prefix='uvz-workflow017-') as td:
 f=Path(td);b=io.BytesIO();Image.new('RGB',(120,180),'white').save(b,'PNG')
 with zipfile.ZipFile(f/'测试书_12345678.uvz','w') as z:
  for name in ['cov001','fow001','fow002','000001','000002','000003','000005','bac001']:z.writestr(name+'.pdg',b.getvalue())
  z.writestr('BookInfo.dat','书名=测试书\n作者=原作者\n出版社=示例出版社\n出版日期=2020.01\nSS号=12345678\n')
  header=b'SSCNTS'+bytes(6)+b'Made by PdgCntEditor'+bytes(8)
  contents='自定前言|01|2|0|4|\r\n原目录|02|1|0|6|\r\n'.encode('gb18030')
  z.writestr('Bookcontents.dat',header+zlib.compress(contents)[:-4])
 (f/'pdf').mkdir()
 writer=PdfWriter();writer.add_blank_page(width=300,height=450)
 writer.add_outline_item('Original first',0,fit=Fit.xyz(left=22,top=411,zoom=1.5))
 writer.add_outline_item('Original second',0,fit=Fit.fit_horizontally(top=299))
 with (f/'pdf/same-page.pdf').open('wb') as stream:writer.write(stream)
 writer=PdfWriter();writer.add_blank_page(width=300,height=450)
 writer.add_outline_item('1',0,fit=Fit.xyz(left=22,top=411,zoom=1.5))
 with (f/'pdf/parent-child.pdf').open('wb') as stream:writer.write(stream)
 out=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else f/'report.json'
 p=subprocess.run([str(exe),'--workflow-ui-test',str(f),str(out)],capture_output=True,text=True,timeout=60)
 assert p.returncode==0,(p.stdout,p.stderr,out.read_text() if out.exists() else '')
 report=json.loads(out.read_text());assert report['passed']
 def targets(path):
  root=PdfReader(path).trailer['/Root']['/Outlines']
  first,last=root['/First'],root['/Last']
  assert first.indirect_reference!=last.indirect_reference
  return [list(node.get('/A',{}).get('/D',node.get('/Dest'))[1:]) for node in [first,last]]
 assert targets(f/'pdf/text-saved.pdf')==[['/XYZ',22,411,1.5],['/FitH',299]]
 report['checks'].append('文本全部替换分别保留 PDF 坐标、缩放和跳转样式')
 assert targets(f/'pdf/same-page.pdf')==[['/XYZ',22,411,1.5],['/Fit']]
 report['checks'].append('树形新建项使用整页目标，不继承同页已删除书签的坐标')
 out.write_text(json.dumps(report,ensure_ascii=False,indent=2))
 print(json.dumps(report,ensure_ascii=False,indent=2))
