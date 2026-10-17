"""Stock-editor tests. Creates isolated profiles, kills only its own children."""
import argparse, json, os, pathlib, shutil, signal, stat, subprocess, tempfile, time
p = argparse.ArgumentParser()
p.add_argument('--binary', type=pathlib.Path, required=True)
p.add_argument('--mod-version', type=int, choices=(3, 4), required=True)
p.add_argument('--label', required=True)
p.add_argument('--reader-binary', type=pathlib.Path)
p.add_argument('--reader-mod-version', type=int, choices=(3, 4))
a = p.parse_args()
assert bool(a.reader_binary) == bool(a.reader_mod_version), 'Reader binary and API version must be specified together'
binary = a.binary
r = pathlib.Path(__file__).resolve().parent
runs = r / 'test-runs'
runs.mkdir(exist_ok=True)
f = pathlib.Path(tempfile.mkdtemp(prefix=a.label + '-', dir=runs))
u = f / 'userdir'
u.mkdir()
subprocess.run(['python3', str(r / 'tools/install.py'), '--userdir', str(u), '--mod-version', str(a.mod_version)], check=True, stdout=subprocess.DEVNULL)
(u / 'init.lua').write_bytes((r / 'tests/profile/init.lua').read_bytes())
(f / 'source.tex').write_bytes(b'BASE\n')
children = []
checks = []

def launch(mode):
    env = os.environ.copy()
    env.update(LITE_USERDIR=str(u), RECOVERY_FIXTURE=str(f), RECOVERY_MODE=mode, RECOVERY_SUITE=str(r / 'tests/unit.lua'), SDL_VIDEODRIVER='dummy')
    with (f / (mode + '.log')).open('wb') as log:
        ch = subprocess.Popen([str(binary.resolve()), str(f)], cwd=f, env=env, stdout=log, stderr=log)
    children.append(ch)
    return ch

def wait(ch, name):
    deadline = time.monotonic() + 25
    while time.monotonic() < deadline:
        assert not (f / 'FAIL.txt').exists(), (f / 'FAIL.txt').read_text() if (f / 'FAIL.txt').exists() else ''
        if (f / name).exists():
            return
        assert ch.poll() is None, (name, ch.returncode, (f / 'error.txt').read_text() if (f / 'error.txt').exists() else '')
        time.sleep(0.025)
    raise AssertionError('Timed out: ' + str(f / name))

def stop(ch):
    ch.kill()
    assert ch.wait(timeout=5) == -signal.SIGKILL
try:
    ch = launch('unit')
    wait(ch, 'unit.done')
    assert ch.wait(timeout=5) == 0
    checks.append('PASS native unit and injected-failure suite')
    (f / 'source.tex').write_bytes(b'BASE\n')
    ch = launch('writer')
    wait(ch, 'writer.ready')
    checks.append('PASS real periodic named and unnamed snapshots')
    ch2 = launch('observer')
    wait(ch2, 'observer.done')
    assert ch2.wait(timeout=5) == 0
    checks.append('PASS active-session exclusion')
    stop(ch)
    if a.reader_binary:
        binary = a.reader_binary
        entry = u / 'plugins/recovery/init.lua'
        text = entry.read_text()
        text = text.replace('-- mod-version:' + str(a.mod_version), '-- mod-version:' + str(a.reader_mod_version), 1)
        entry.write_text(text)
    ch = launch('restore')
    wait(ch, 'restore.ready')
    checks.append('PASS SIGKILL restart preserves text CRLF Unicode and multicursors')
    stop(ch)
    (f / 'restore.ready').unlink()
    ch = launch('restore')
    wait(ch, 'restore.ready')
    checks.append('PASS second crash preserves exactly two copies')
    stop(ch)
    ch = launch('save')
    wait(ch, 'save.done')
    assert ch.wait(timeout=5) == 0
    checks.append('PASS stock save retires snapshots')
    ch = launch('probe')
    wait(ch, 'probe.done')
    assert ch.wait(timeout=5) == 0
    checks.append('PASS saved copies not offered on next startup')
    (f / 'writer.ready').unlink()
    ch = launch('writer')
    wait(ch, 'writer.ready')
    stop(ch)
    ch = launch('discard')
    wait(ch, 'discard.done')
    assert ch.wait(timeout=5) == 0
    (f / 'probe.done').unlink()
    ch = launch('probe')
    wait(ch, 'probe.done')
    assert ch.wait(timeout=5) == 0
    checks.append('PASS actual stock Quit No preserves and Yes retires snapshots before exit')
    assert (f / 'source.tex').read_bytes() == b'BASE\n'
    checks.append('PASS source remains byte-identical')
    for base, dirs, files in os.walk(u / 'recovery-v1'):
        assert stat.S_IMODE(os.stat(base).st_mode) == 448
        for name in files:
            assert stat.S_IMODE((pathlib.Path(base) / name).stat().st_mode) == 384
    checks.append('PASS private recovery directory/file permissions')
    result = {'label': a.label, 'passed': True, 'checks': checks, 'unit_result': (f / 'unit-results.txt').read_text(), 'fixture': str(f), 'binary': str(a.binary), 'mod_version': a.mod_version, 'reader_binary': str(a.reader_binary) if a.reader_binary else None, 'reader_mod_version': a.reader_mod_version}
    (f / 'result.json').write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2), flush=True)
finally:
    for ch in children:
        if ch.poll() is None:
            ch.kill()
            ch.wait(timeout=5)
