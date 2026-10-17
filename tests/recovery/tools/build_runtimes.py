"""Build pinned, unmodified editors into an explicit NEW directory; no system install."""
import argparse, json, os, pathlib, subprocess
p = argparse.ArgumentParser()
p.add_argument('--root', type=pathlib.Path, required=True)
a = p.parse_args()
r = a.root.expanduser().resolve()
assert not r.exists(), 'Build destination must be new'
assert 'ws' not in r.parts and r != (pathlib.Path.home() / '.config/lite-xl').resolve()
r.mkdir(parents=True)
spec = json.loads((pathlib.Path(__file__).resolve().parents[1] / 'tests/runtimes.json').read_text())
for name, item in spec.items():
    src = r / name
    env = os.environ.copy()
    env['CCACHE_DIR'] = str(r / 'ccache')

    def run(args, cwd=r):
        subprocess.run(args, cwd=cwd, env=env, check=True)
    run(['git', 'init', str(src)])
    run(['git', 'fetch', '--depth', '1', item['repo'], item['commit']], src)
    run(['git', 'checkout', '--detach', 'FETCH_HEAD'], src)
    run(['meson', 'setup', 'build', '--buildtype=debugoptimized', '--prefix=/runtime'], src)
    run(['meson', 'compile', '-C', 'build'], src)
    run(['meson', 'install', '-C', 'build', '--no-rebuild', '--skip-subprojects', '--destdir=stage'], src)
    print(name, src / 'build/stage/runtime/bin/lite-xl', flush=True)
