#!/usr/bin/env python3
"""Run the generated-fixture regression suite without changing user books."""
from pathlib import Path
import concurrent.futures,json,subprocess,sys
r=Path(__file__).resolve().parents[1];exe=r/'UVZ Reader Lab.app/Contents/MacOS/UVZReaderLab'
models=['text-conversion','online-model','naming-model','model','editing-model','region-model']
tests=['conversion','multilingual_ocr','native_information','metadata_rules','archive','decoder','formats_editing','contents_text','region_ocr','information','bibliographic','batch_naming','decoder_extended','missing_pdf_information','native_contents','pdf_outline_streams','raster_fidelity']
jobs=[(name,[str(exe),'--'+name+'-tests']) for name in models]+[(name,[sys.executable,str(r/'Tests'/('test_'+name+'.py'))]) for name in tests]
def run(job):
 name,cmd=job;p=subprocess.run(cmd,capture_output=True,text=True,timeout=240)
 if p.returncode:raise RuntimeError(name+': '+p.stderr)
 return name,json.loads(p.stdout)
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:results=dict(pool.map(run,jobs))
print(json.dumps(dict(passed=sum(x['passed'] for x in results.values()),results=results),ensure_ascii=False,indent=2))
