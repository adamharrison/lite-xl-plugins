"""Install to an explicit, non-live USERDIR; no network, no existing files replaced."""
import argparse, pathlib, shutil
p = argparse.ArgumentParser()
p.add_argument('--userdir', required=True, type=pathlib.Path)
p.add_argument('--mod-version', required=True, type=int, choices=(3, 4))
a = p.parse_args()
u = a.userdir.expanduser().resolve()
assert u != (pathlib.Path.home() / '.config/lite-xl').resolve(), 'Refusing the live profile'
assert 'ws' not in u.parts, 'Workspace paths are excluded'
src = pathlib.Path(__file__).resolve().parents[3] / 'plugins/recovery'
dst = u / 'plugins/recovery'
assert not dst.exists(), 'Destination already exists; inspect and back it up first'
shutil.copytree(src, dst)
p = dst / 'init.lua'
header, body = p.read_text().split('\n', 1)
assert header.startswith('-- mod-version:'), 'Missing plugin API declaration'
p.write_text('-- mod-version:' + str(a.mod_version) + '\n' + body)
print(dst)
