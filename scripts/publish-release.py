#!/usr/bin/env python3
"""Publish verified assets for an existing pushed source commit; never moves tags."""
import argparse,hashlib,json,os,shutil,subprocess
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--checkout',type=Path,required=True);p.add_argument('--version',required=True);p.add_argument('--notes',type=Path,required=True);p.add_argument('assets',type=Path,nargs='+');a=p.parse_args()
gh=os.environ.get('GH_BIN') or shutil.which('gh');assert gh,'GitHub CLI missing; set GH_BIN'
repo='puyun1000/UVZ-Reader-Lab-for-Mac';tag='v'+a.version;checkout=a.checkout.resolve()
def git(*args):return subprocess.check_output(['git','-C',str(checkout),*args],text=True).strip()
assert not git('status','--porcelain'),'Commit source changes before publishing'
remote=git('remote','get-url','origin');assert 'puyun1000/UVZ-Reader-Lab-for-Mac' in remote,'Unexpected repository'
head=git('rev-parse','HEAD');assert git('rev-parse',tag+'^{commit}')==head,'Version tag does not point at current source'
assert git('ls-remote','origin','refs/heads/main').split()[0]==head,'Push source main before publishing'
checksums={}
for asset in a.assets:
 assert asset.is_file(),asset
 checksums[asset.name]=hashlib.sha256(asset.read_bytes()).hexdigest()
existing=subprocess.run([gh,'release','view',tag,'--repo',repo],capture_output=True)
assert existing.returncode!=0,'Release already exists; inspect it instead of overwriting assets'
subprocess.run([gh,'release','create',tag,'--repo',repo,'--verify-tag','--target',head,'--title','UVZ Reader Lab '+a.version,'--notes-file',str(a.notes.resolve()),*[str(x.resolve()) for x in a.assets]],check=True)
print(json.dumps({'repository':repo,'tag':tag,'commit':head,'localSHA256':checksums},ensure_ascii=False,indent=2))
