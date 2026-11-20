"""Run as non-root with clamd/clamdscan on PATH; TMPDIR must fit a Unix socket."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

helper = Path(__file__).resolve().with_name('clamav.py')
with tempfile.TemporaryDirectory(prefix='', dir=os.environ.get('TMPDIR')) as tmp:
    root = Path(tmp)
    db = Path(tmp) / 'db'
    db.mkdir()
    (db / 'test.ndb').write_text('HamPanelFixture:0:*:48414d50414e454c5f434c414d41565f46495854555245\n')

    def call(*args, code=0):
        result = subprocess.run([sys.executable, helper, root, *args], capture_output=True, text=True, timeout=210)
        assert result.returncode == code, (args, result.stdout, result.stderr)
        print(result.stdout.strip())
        return json.loads(result.stdout)

    try:
        assert not call('status')['active']
        failed = call('initialize', '--database', root / 'missing', code=2)
        assert 'error' in failed and not (root / 'clamd.conf').exists()
        fake = root / 'fake'
        fake.mkdir()
        stub = fake / 'clamd'
        stub.write_text('#!/bin/sh\necho simulated startup failure\nexit 1\n')
        stub.chmod(0o700)
        blocked = subprocess.run([sys.executable, helper, root, 'initialize', '--database', db],
                                 capture_output=True, text=True, timeout=15,
                                 env={**os.environ, 'PATH': str(fake) + os.pathsep + os.environ['PATH']})
        assert blocked.returncode == 2 and 'simulated startup failure' in blocked.stdout
        assert not (root / 'clamd.conf').exists()
        assert call('initialize', '--database', db)['ok']
        assert call('status')['active']
        assert call('initialize', '--database', db)['ok']
        for text, verdict in [('ordinary text for clean scan', 'clean'), ('HAMPANEL_CLAMAV_FIXTURE', 'infected')]:
            sample = Path(tmp) / 'test file'
            sample.write_text(text)
            assert call('scan', '--path', sample)['verdict'] == verdict
        target = root / 'target directory'
        nested = target / 'nested'
        nested.mkdir(parents=True)
        (target / 'ordinary.txt').write_text('ordinary text')
        clean = call('scan', '--path', target)
        assert (clean['verdict'], clean['exit_code']) == ('clean', 0)
        marker = 'HAMPANEL_CLAMAV_FIXTURE'
        for name in ('one.txt', 'two.txt'):
            (nested / name).write_text(marker)
        hit = call('scan', '--path', target)
        assert (hit['verdict'], hit['exit_code']) == ('infected', 1)
        for name in ('one.txt', 'two.txt'):
            assert str(nested / name) in hit['output'] and (nested / name).read_text() == marker
        assert 'error' in call('scan', '--path', 'relative', code=2)
    finally:
        sock = root / 's'
        if sock.exists():
            os.kill(int((root / 'pid').read_text()), signal.SIGTERM)
            for _ in range(100):
                if not sock.exists():
                    break
                time.sleep(0.1)
            assert not sock.exists(), 'private clamd did not shut down'
