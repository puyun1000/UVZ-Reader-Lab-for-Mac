"""Incremental outlines with compressed catalogs, pages, xrefs and PNG predictors."""
from pathlib import Path
import json,struct,zlib,tempfile,subprocess
from pypdf import PdfReader
r=Path(__file__).resolve().parents[1];exe=r/'UVZ Reader Lab.app/Contents/MacOS/UVZReaderLab'
def pdf(predictor=False,classic=False,hybrid=False):
 values=[b'<< /Type /Catalog /Pages 2 0 R >>',b'<< /Type /Pages /Count 1 /Kids [3 0 R] >>',b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 320 480] /Resources << >> /Contents 4 0 R >>']
 payload=b'';headers=[]
 for i,v in enumerate(values,1):headers.extend([str(i),str(len(payload))]);payload+=v+b'\n'
 header=(' '.join(headers)+' ').encode();stream=zlib.compress(header+payload)
 raw=bytearray(b'%PDF-1.5\n');offsets={}
 def obj(n,b):offsets[n]=len(raw);raw.extend(f'{n} 0 obj\n'.encode()+b+b'\nendobj\n')
 previous=None
 if classic or hybrid:
  for i,v in enumerate(values,1):obj(i,v)
 if classic:
  previous=len(raw);raw.extend(b'xref\n0 4\n0000000000 65535 f \n')
  for i in range(1,4):raw.extend(f'{offsets[i]:010d} 00000 n \n'.encode())
  raw.extend(f'trailer\n<< /Root 1 0 R /Size 4 >>\nstartxref\n{previous}\n%%EOF\n'.encode())
 obj(4,b'<< /Length 0 >>\nstream\n\nendstream')
 obj(5,f'<< /Type /ObjStm /N 3 /First {len(header)} /Filter /FlateDecode /Length {len(stream)} >>\nstream\n'.encode()+stream+b'\nendstream')
 start=len(raw);offsets[6]=start
 entries=[(0,0,65535)]+([(1,offsets[i],0) for i in [1,2,3]] if hybrid else [(2,5,i) for i in [0,1,2]])+[(1,offsets[i],0) for i in [4,5,6]]
 rows=[struct.pack('>BIH',*e) for e in entries]
 if predictor:
  prev=bytes(7);result=b''
  for row in rows:result+=b'\x02'+bytes((a-b)&255 for a,b in zip(row,prev));prev=row
 else:result=b''.join(rows)
 packed=zlib.compress(result);params=b' /DecodeParms << /Predictor 12 /Columns 7 >>' if predictor else b''
 if previous is not None:params+=f' /Prev {previous}'.encode()
 obj(6,f'<< /Type /XRef /Size 7 /Root 1 0 R /W [1 4 2] /Filter /FlateDecode /Length {len(packed)}'.encode()+params+b' >>\nstream\n'+packed+b'\nendstream')
 raw.extend(f'startxref\n{start}\n%%EOF\n'.encode())
 if hybrid:
  obj(7,b'null');at=len(raw);raw.extend(b'xref\n0 8\n0000000000 65535 f \n')
  for i in range(1,8):raw.extend(f'{offsets[i]:010d} 00000 n \n'.encode())
  raw.extend(b'trailer\n<< /Root 1 0 R /Size 8')
  raw.extend(f' /XRefStm {start}'.encode() if hybrid else f' /Prev {start}'.encode())
  raw.extend(f' >>\nstartxref\n{at}\n%%EOF\n'.encode())
 return bytes(raw)
def run(*args,ok=True):
 p=subprocess.run([str(exe),*map(str,args)],capture_output=True,text=True,timeout=40)
 assert (p.returncode==0)==ok,(args,p.stderr)
 return json.loads(p.stdout) if p.stdout and p.returncode==0 else p.stderr
checks=[]
with tempfile.TemporaryDirectory(prefix='pdf-outline-streams-') as td:
 f=Path(td)
 for label,pred,classic,hybrid in [('compressed',False,False,False),('predictor',True,False,False),('mixed-chain',True,True,False),('hybrid',False,False,True)]:
  p=f/(label+'.pdf');raw=pdf(pred,classic,hybrid);p.write_bytes(raw);assert len(PdfReader(p).pages)==1
  chapters=[dict(title='分组',page=0,level=0),dict(title='目标页',page=1,level=1)];values={'书名':'压缩对象目录','ISBN':'9780306406157'}
  plan=f/'draft.json';plan.write_text(json.dumps(dict(chapters=chapters,metadata=values),ensure_ascii=False))
  for i in range(3):
   previous=p.read_bytes();run('--apply-draft',p,plan);assert p.read_bytes().startswith(previous)
   info=run('--inspect',p);assert info['chapters']==chapters and info['metadata']==values
   independent=PdfReader(p);assert independent.get_destination_page_number(independent.outline[1][0])==0
  checks.append(label+': three outline revisions preserve original bytes, destinations and metadata')
 # Refuse invalid indexes without changing the original file.
 p=f/'invalid.pdf';raw=pdf().replace(b'/W [1 4 2]',b'/W [1 9 2]');p.write_bytes(raw)
 run('--apply-draft',p,plan,ok=False);assert p.read_bytes()==raw;checks.append('invalid xref widths rejected without replacing the original')
print(json.dumps(dict(passed=len(checks),checks=checks),ensure_ascii=False,indent=2))
