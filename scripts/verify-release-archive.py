#!/usr/bin/env python3
"""Read-only gate before removing local versioned artifacts; never deletes files."""
import argparse, hashlib, json, os, shutil, subprocess, time
from pathlib import Path

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--checkout', type=Path, required=True)
p.add_argument('--version', required=True)
p.add_argument('files', type=Path, nargs='+')
a = p.parse_args()
gh = os.environ.get('GH_BIN') or shutil.which('gh')
assert gh, 'GitHub CLI missing; set GH_BIN'
repo = 'puyun1000/UVZ-Reader-Lab-for-Mac'
tag = 'v' + a.version

def api(route):
    route += ('&' if '?' in route else '?') + 'archive_check=' + str(time.time_ns())
    return json.loads(subprocess.check_output([gh, 'api', route, '-H', 'Cache-Control: no-cache'], text=True))

commit = subprocess.check_output(['git', '-C', str(a.checkout), 'rev-parse', 'refs/tags/' + tag + '^{commit}'], text=True).strip()
remote = api('repos/' + repo + '/git/ref/tags/' + tag)['object']
if remote['type'] == 'tag':
    remote = api('repos/' + repo + '/git/tags/' + remote['sha'])['object']
assert remote['type'] == 'commit' and remote['sha'] == commit, 'Source tag mismatch; keep local files'
release = api('repos/' + repo + '/releases/tags/' + tag)
assert not release['draft'] and release['tag_name'] == tag, 'No public release; keep local files'
assets = release['assets']
assert any(x['name'].endswith('.dmg') for x in assets), 'Installer missing; keep local files'
assert any(x['name'].endswith('.zip') for x in assets), 'Source bundle missing; keep local files'
assert any('SHA256SUMS' in x['name'] for x in assets), 'Checksums missing; keep local files'
assert any('verification' in x['name'] or 'validation' in x['name'].lower() for x in assets), 'Validation missing; keep local files'
verified = []
for file in a.files:
    digest = hashlib.sha256(file.read_bytes()).hexdigest()
    matches = [x for x in assets if x['name'] == file.name]
    assert len(matches) == 1, 'Remote artifact missing; keep local file: ' + file.name
    item = matches[0]
    assert item['size'] == file.stat().st_size and item.get('digest') == 'sha256:' + digest, 'Artifact mismatch; keep local file: ' + file.name
    verified.append(dict(name=file.name, bytes=item['size'], sha256=digest))
print(json.dumps(dict(version=a.version, sourceCommit=commit, publicRelease=release['html_url'], verified=verified), indent=2))
