"""Real loopback explicit FTPS acceptance; needs pure-ftpd, pure-pw, openssl."""
import ftplib
import io
import os
from pathlib import Path
import secrets
import signal
import socket
import ssl
import subprocess as sp
import sys
import tempfile
import time

helper = Path(__file__).resolve().parents[1] / 'daemon/libexec/pure_ftpd.py'
with tempfile.TemporaryDirectory(dir=os.getenv('COMMANDCODE_SCRATCHPAD')) as tmp:
    root = Path(tmp)
    if os.geteuid() == 0:
        root.chmod(0o711)
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    def cmd(action, *args):
        return [sys.executable, str(helper), action, tmp, *args]
    sp.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
            '-subj', '/CN=localhost', '-addext', 'subjectAltName=IP:127.0.0.1',
            '-keyout', str(root/'key'), '-out', str(root/'cert')], check=True, stderr=sp.DEVNULL)
    pem = root/'server.pem'
    pem.write_bytes((root/'cert').read_bytes() + (root/'key').read_bytes())
    pem.chmod(0o600)
    sp.run(cmd('init', '--port', str(port)), check=True)
    pw = secrets.token_hex(24)
    sp.run(cmd('add', '--name', 'tester', '--uid', str(os.getuid() or 65534), '--gid', str(os.getgid() or 65534)), input=pw.encode(), check=True)
    assert root.stat().st_mode & 0o777 == 0o711
    assert (root / 'homes').stat().st_mode & 0o777 == 0o711
    assert (root / 'users.pdb').stat().st_mode & 0o077 == 0
    assert pem.stat().st_mode & 0o077 == 0
    if os.geteuid() == 0:
        sp.run([sys.executable, '-c', '''
import os, sys
from pathlib import Path
root = Path(sys.argv[1])
os.setgroups([])
os.setgid(65534)
os.setuid(65534)
probe = root / 'homes/tester/write-probe'
probe.write_bytes(b'ok')
probe.unlink()
for path in ('pure-ftpd.conf', 'server.pem', 'users.pdb'):
    try:
        (root / path).read_bytes()
    except PermissionError:
        continue
    raise AssertionError(path + ' readable')
print('PASS: uid 65534 writes home; config, PEM and PureDB denied', flush=True)
''', str(root)], check=True)
    proc = sp.Popen(cmd('start'), start_new_session=True)
    try:
        for _ in range(80):
            if proc.poll() is not None:
                raise RuntimeError('server exited')
            try:
                ftp = ftplib.FTP(timeout=4)
                ftp.connect('127.0.0.1', port)
                break
            except ConnectionRefusedError:
                time.sleep(.1)
        else:
            raise RuntimeError('not ready')
        def denied(fn):
            try:
                fn()
            except ftplib.error_perm:
                return
            raise AssertionError('unexpected success')
        try:
            ftp.login('tester', pw)
        except ftplib.error_temp as e:
            assert str(e).startswith('421') and 'TLS' in str(e)
        else:
            raise AssertionError('plaintext login accepted')
        finally:
            ftp.close()
        def client():
            ftp = ftplib.FTP_TLS(context=ssl.create_default_context(cafile=str(root/'cert')), timeout=30)
            ftp.connect('127.0.0.1', port)
            return ftp
        with client() as ftp:
            ftp.login('tester', pw)
            def clear_list():
                ftp.prot_c()
                ftp.nlst()
            denied(clear_list)
            ftp.prot_p()
            payload = os.urandom(4096)
            ftp.storbinary('STOR sample', io.BytesIO(payload))
            assert 'sample' in ftp.nlst()
            out = io.BytesIO()
            ftp.retrbinary('RETR sample', out.write)
            assert out.getvalue() == payload
        sp.run(cmd('delete', '--name', 'tester'), check=True)
        with client() as ftp:
            denied(lambda: ftp.login('tester', pw))
        print('PASS: plaintext denied, private LIST/STOR/RETR, deleted login denied')
    finally:
        if proc.poll() is None:
            os.killpg(proc.pid, signal.SIGTERM)
        proc.wait(timeout=10)
