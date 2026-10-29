#!/usr/bin/env python3
"""Publish sequentially to a verified tag; resume matching draft assets safely.

Set HTTPS_PROXY if needed. Authentication stays in memory and curl stdin,
never command arguments, files or output. Existing assets are never replaced.
"""
import argparse,hashlib,json,os,shutil,subprocess,time
from pathlib import Path
from urllib.parse import quote
p=argparse.ArgumentParser();p.add_argument('--checkout',type=Path,required=True);p.add_argument('--version',required=True);p.add_argument('--notes',type=Path,required=True);p.add_argument('assets',type=Path,nargs='+');a=p.parse_args()
gh=os.environ.get('GH_BIN') or shutil.which('gh');assert gh,'GitHub CLI missing; set GH_BIN'
repo='puyun1000/UVZ-Reader-Lab-for-Mac';tag='v'+a.version;checkout=a.checkout.resolve()
def git(*args):return subprocess.check_output(['git','-C',str(checkout),*args],text=True).strip()
def api(route):
 route+=('&' if '?' in route else '?')+'readerlab_verify='+str(time.time_ns())
 return json.loads(subprocess.check_output([gh,'api',route,'--header','Cache-Control: no-cache'],text=True))
assert not git('status','--porcelain'),'Commit source changes before publishing'
assert repo in git('remote','get-url','origin'),'Unexpected repository'
head=git('rev-parse','HEAD');assert git('rev-parse',tag+'^{commit}')==head,'Version tag differs from current source'
assert git('ls-remote','origin','refs/heads/main').split()[0]==head,'Push source first'
assert git('ls-remote','origin','refs/tags/'+tag+'^{}').split()[0]==head,'Push annotated tag first'
assert len({x.name for x in a.assets})==len(a.assets),'Duplicate asset names'
checksums={}
for asset in a.assets:
 assert asset.is_file(),asset
 checksums[asset.name]=hashlib.sha256(asset.read_bytes()).hexdigest()
releases='repos/'+repo+'/releases'
matching=[x for x in api(releases+'?per_page=100') if x['tag_name']==tag]
assert len(matching)<=1,'Duplicate release tags'
if not matching:
 subprocess.run([gh,'release','create',tag,'--repo',repo,'--verify-tag','--target',head,'--draft','--title','UVZ Reader Lab '+a.version,'--notes-file',str(a.notes.resolve())],check=True)
matching=[x for x in api(releases+'?per_page=100') if x['tag_name']==tag]
assert len(matching)==1,'Unable to locate release draft'
route=releases+'/'+str(matching[0]['id'])
release=api(route);token=subprocess.check_output([gh,'auth','token'],text=True).strip()
for asset in a.assets:
 existing=next((x for x in release['assets'] if x['name']==asset.name),None)
 if existing is None:
  assert release['draft'],'Refusing to append to a published release'
  print('Uploading '+asset.name,flush=True)
  upload='https://uploads.github.com/repos/'+repo+'/releases/'+str(release['id'])+'/assets?name='+quote(asset.name,safe='')
  config='\n'.join(key+' = '+json.dumps(value,ensure_ascii=False) for key,value in [('url',upload),('header','Authorization: Bearer '+token),('header','Content-Type: application/octet-stream'),('header','Expect:'),('upload-file',str(asset.resolve())),('request','POST')])+'\n'
  result=subprocess.run(['curl','--disable','--config','-','--http1.1','--silent','--show-error','--fail-with-body','--connect-timeout','30','--max-time','1200','--limit-rate','256k'],input=config,capture_output=True,text=True,timeout=1230)
  if result.returncode:raise RuntimeError('Upload incomplete; inspect the draft before retrying: '+asset.name+'; '+result.stderr)
  existing=json.loads(result.stdout)
 assert existing['size']==asset.stat().st_size,asset.name+' size differs'
 assert existing.get('digest')=='sha256:'+checksums[asset.name],asset.name+' digest differs'
 release=api(route)
del token
if release['draft']:subprocess.run([gh,'api','--method','PATCH',route,'-F','draft=false','-f','make_latest=true'],check=True,stdout=subprocess.DEVNULL)
release=api(route);assert not release['draft'] and release['tag_name']==tag
assert api('repos/'+repo+'/releases/latest')['tag_name']==tag
verified=[]
for asset in a.assets:
 remote=next(x for x in release['assets'] if x['name']==asset.name)
 assert remote['digest']=='sha256:'+checksums[asset.name] and remote['size']==asset.stat().st_size
 verified.append(dict(name=asset.name,bytes=remote['size'],sha256=checksums[asset.name],verified=True))
print(json.dumps(dict(repository=repo,tag=tag,commit=head,url=release['html_url'],assets=verified),indent=2))
