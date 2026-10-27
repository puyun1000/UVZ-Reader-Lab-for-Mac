#!/usr/bin/env python3
"""Package the clean committed source and the current signed build on macOS."""
import argparse,hashlib,json,plistlib,re,subprocess,tempfile,zipfile
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--checkout',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--evidence',type=Path,required=True);a=p.parse_args()
r=a.checkout.resolve();out=a.output.resolve();out.mkdir(exist_ok=True)
def run(*args):return subprocess.check_output(list(map(str,args)),stderr=subprocess.STDOUT).decode()
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def signed(p):run('codesign','--verify','--deep','--strict',p)
assert not run('git','-C',r,'status','--porcelain').strip(),'Commit source first'
commit=run('git','-C',r,'rev-parse','HEAD').strip();info=plistlib.loads((r/'Info.plist').read_bytes());version=info['CFBundleShortVersionString'];build=info['CFBundleVersion'];stem='UVZReaderLab-'+version
sourcezip=out/(stem+'.zip');dmg=out/(stem+'-macOS-arm64.dmg');report=out/(stem+'-verification.json');sums=out/(stem+'-SHA256SUMS.txt')
assert not any(x.exists() for x in [sourcezip,dmg,report,sums]),'Release outputs already exist'
evidence=json.loads(a.evidence.read_text());assert evidence['version']==version
with tempfile.TemporaryDirectory(prefix='uvz-package-') as td:
 f=Path(td);source=f/'UVZReaderLab';source.mkdir();files=run('git','-C',r,'ls-files','-z').split('\0')[:-1]
 for name in files:
  target=source/name;target.parent.mkdir(parents=True,exist_ok=True)
  target.write_bytes(subprocess.check_output(['git','-C',str(r),'show','HEAD:'+name]));target.chmod((r/name).stat().st_mode&0o777)
 run('ditto','-x','-k',r/'UVZ Reader Lab.zip',source)
 app=source/'UVZ Reader Lab.app';signed(app)
 for name in ['UserGuide','ReleaseNotes']:assert (app/'Contents/Resources'/ (name+'.md')).read_bytes()==(r/'Resources'/(name+'.md')).read_bytes()
 for manifest in [app/'Contents/Info.plist',*app.glob('Contents/PlugIns/*/Contents/Info.plist')]:
  values=plistlib.loads(manifest.read_bytes());assert values['CFBundleShortVersionString']==version and values['CFBundleVersion']==build
 binaries=[]
 for path in app.rglob('*'):
  if not path.is_file():continue
  with path.open('rb') as stream:magic=stream.read(4)
  if magic!=bytes.fromhex('cffaedfe'):continue
  assert run('lipo','-archs',path).strip()=='arm64'
  assert re.search(r'minos\s+14\.0(?:\s|$)',run('xcrun','vtool','-show-build',path))
  assert '/opt/homebrew/' not in run('otool','-L',path)
  binaries.append(str(path.relative_to(app)))
 assert len(binaries)==7,binaries
 run('ditto','-c','-k','--keepParent','--norsrc',source,sourcezip)
 with zipfile.ZipFile(sourcezip) as z:
  for name in files:assert z.read('UVZReaderLab/'+name)==(r/name).read_bytes()
 disk=f/'disk';disk.mkdir();run('ditto','--norsrc',app,disk/app.name);(disk/'Applications').symlink_to('/Applications')
 (disk/'Install.txt').write_text('UVZ Reader Lab '+version+'\n\n\u5c06\u5e94\u7528\u62d6\u5165Applications\u6587\u4ef6\u5939\u5b89\u88c5\u3002\n\u9002\u7528\u4e8eApple\u82af\u7247Mac\uff0cmacOS14\u6216\u66f4\u9ad8\u7248\u672c\u3002\n\u672c\u7248\u4e3a\u4e34\u65f6\u7b7e\u540d\uff0c\u672a\u7ecfApple\u516c\u8bc1\u3002\n\u529f\u80fd\u548c\u66f4\u65b0\u8bf4\u660e\u89c1\u5e94\u7528\u7684\u5e2e\u52a9\u83dc\u5355\u3002\n',encoding='utf-8')
 run('hdiutil','create','-volname','UVZ Reader Lab '+version,'-srcfolder',disk,'-fs','HFS+','-format','UDZO',dmg)
 run('hdiutil','verify',dmg);mount=f/'mounted';mount.mkdir()
 run('hdiutil','attach','-nobrowse','-readonly','-mountpoint',mount,dmg)
 try:
  inside=mount/app.name;signed(inside);assert (mount/'Applications').resolve()==Path('/Applications')
  for path in app.rglob('*'):
   if path.is_file():assert digest(path)==digest(inside/path.relative_to(app))
  copied=f/'copied.app';run('ditto','--norsrc',inside,copied);signed(copied)
  model=json.loads(run(inside/'Contents/MacOS/UVZReaderLab','--model-tests'));assert model['passed']==24
 finally:run('hdiutil','detach',mount)
 evidence.update(sourceCommit=commit,sourceArchiveSHA256=digest(sourcezip),packaging=dict(architecture='arm64',minimumOS='14.0',testedOS=run('sw_vers','-productVersion').strip(),adHocSigned=True,appleNotarized=False,machOBuildTargets=binaries,executableSHA256=digest(app/'Contents/MacOS/UVZReaderLab'),sourceFilesMatchCommit=True),installer=dict(file=dmg.name,bytes=dmg.stat().st_size,sha256=digest(dmg),diskImageVerified=True,mountedReadOnly=True,signatureVerifiedInImageAndAfterCopy=True,applicationHashesMatchRelease=True,modelChecksFromImage=24,applicationsShortcutVerified=True))
report.write_text(json.dumps(evidence,ensure_ascii=False,indent=2)+'\n')
sums.write_text(''.join(digest(x)+'  '+x.name+'\n' for x in [dmg,sourcezip,report]))
print(json.dumps(dict(version=version,commit=commit,installer=str(dmg),source=str(sourcezip)),indent=2))
