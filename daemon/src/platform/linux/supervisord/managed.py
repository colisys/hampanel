"""Linux panel helper. The daemon supplies a trusted absolute instance directory."""
import argparse
import fcntl
import json
import http.client
import os
import socket
from pathlib import Path
import re
import stat
import tempfile
import subprocess
import sys
import xmlrpc.client


class UnixConnection(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__('localhost')
        self.path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(self.path)


class UnixTransport(xmlrpc.client.Transport):
    def __init__(self, path):
        super().__init__()
        self.path = path

    def make_connection(self, host):
        return UnixConnection(self.path)


CONFIG = '''[unix_http_server]
file=%(here)s/s
chmod=0600
[supervisord]
directory=%(here)s
pidfile=%(here)s/supervisord.pid
logfile=%(here)s/supervisord.log
childlogdir=%(here)s
umask=077
[rpcinterface:supervisor]
supervisor.rpcinterface_factory=supervisor.rpcinterface:make_main_rpcinterface
[supervisorctl]
serverurl=unix://%(here)s/s
[include]
files=programs/*.ini
'''


NAME = r'[A-Za-z][A-Za-z0-9_-]{0,47}'
HEADER = '# hampanel managed program v1\n'


def render(name, argv):
    # A token whitelist alone would still permit sh -c, interpreters or env.
    if not (isinstance(argv, list) and 1 <= len(argv) <= 16 and
            all(isinstance(t, str) and re.fullmatch(r'[A-Za-z0-9_./:-]{1,128}', t) for t in argv) and
            (argv[0] == '/bin/echo' or (argv[0] == '/bin/sleep' and len(argv) == 2 and
             re.fullmatch(r'[1-9][0-9]{0,7}', argv[1])))):
        raise ValueError('expected /bin/echo tokens or /bin/sleep positive-seconds')
    return (HEADER + f'[program:{name}]\ncommand={" ".join(argv)}\n'
            'autostart=true\nautorestart=false\nstartsecs=0\n'
            'stdout_logfile=AUTO\nstderr_logfile=AUTO\n').encode()


def atomic(path, data):
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as f:
        try:
            f.write(data)
            f.close()
            os.replace(f.name, path)
        finally:
            Path(f.name).unlink(missing_ok=True)


def owned(path):
    if not path.exists() or path.is_symlink():
        return False
    st = path.stat()
    if not stat.S_ISREG(st.st_mode) or st.st_uid != os.geteuid() or st.st_mode & 0o077:
        return False
    with path.open('rb') as f:
        return f.read(len(HEADER)) == HEADER.encode()


def mutate(rpc, action, name, argv):
    if not re.fullmatch(NAME, name):
        raise ValueError('invalid program name')
    path = Path('programs') / ('panel-' + name + '.ini')
    old = None
    if action == 'create':
        if os.path.lexists(path) or any(p['group'] == name for p in rpc.getAllProcessInfo()):
            raise ValueError('program already exists')
    elif owned(path):
        old = path.read_bytes()
    else:
        raise ValueError('not a panel-managed program')
    data = None if action == 'delete' else render(name, argv)
    if any(name in groups for groups in rpc.reloadConfig()[0]):
        raise ValueError('target already has pending configuration changes')
    if data is None:
        path.unlink()
    else:
        atomic(path, data)
    try:
        # reloadConfig is reread; apply only this group, never unrelated changes.
        added, changed, removed = rpc.reloadConfig()[0]
        if action == 'create' and name not in added or action == 'delete' and name not in removed:
            raise ValueError('configuration conflict')
        if name in changed or name in removed:
            rpc.stopProcessGroup(name)
            rpc.removeProcessGroup(name)
        if name in added or name in changed:
            rpc.addProcessGroup(name)
    except Exception:
        if old is None:
            path.unlink()
        else:
            atomic(path, old)
        # If removal completed before add failed, restore the previous group too.
        added, changed, removed = rpc.reloadConfig()[0]
        if name in changed or name in removed:
            rpc.stopProcessGroup(name)
            rpc.removeProcessGroup(name)
        if name in changed or name in added:
            rpc.addProcessGroup(name)
        raise
    return True


def run(root, action, name, stream, argv=None):
    if not root.is_absolute():
        raise ValueError('absolute instance directory required')
    os.umask(0o077)
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    if root.is_symlink() or root.stat().st_uid != os.geteuid() or root.stat().st_mode & 0o077:
        raise ValueError('private, daemon-owned directory required')
    os.chdir(root)
    with open('launch.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        programs = Path('programs')
        programs.mkdir(mode=0o700, exist_ok=True)
        if programs.is_symlink() or programs.stat().st_uid != os.geteuid() or programs.stat().st_mode & 0o022:
            raise ValueError('unsafe programs directory')
        programs.chmod(0o700)
        return locked(root, action, name, stream, argv)


def locked(root, action, name, stream, argv):
    def connect():
        return xmlrpc.client.ServerProxy('http://localhost', transport=UnixTransport(str(root / 's'))).supervisor
    rpc = connect()
    if action == 'launch':
        try:
            return rpc.getState()
        except (FileNotFoundError, ConnectionRefusedError):
            pass
        atomic(Path('supervisord.conf'), CONFIG.encode())
        subprocess.run(['supervisord', '-c', str(root / 'supervisord.conf')], check=True, stdout=sys.stderr, timeout=20)
        return connect().getState()
    if action in ('create', 'update', 'delete'):
        return mutate(rpc, action, name, argv)
    if action == 'list':
        try:
            processes = rpc.getAllProcessInfo()
        except (FileNotFoundError, ConnectionRefusedError):
            return []
        return [dict(name=p['group'] + ':' + p['name'], state=p['statename'], pid=p['pid'], managed=bool(re.fullmatch(NAME, p['group'])) and owned(Path('programs') / ('panel-' + p['group'] + '.ini'))) for p in processes]
    if not re.fullmatch(r'[\w.-]+:[\w.-]+', name, re.ASCII):
        raise ValueError('expected group:process')
    if action == 'logs':
        method = rpc.tailProcessStdoutLog if stream == 'stdout' else rpc.tailProcessStderrLog
        return method(name, 0, 16384)[0]
    if action == 'restart' and rpc.getProcessInfo(name)['statename'] == 'RUNNING':
        rpc.stopProcess(name)
    return rpc.stopProcess(name) if action == 'stop' else rpc.startProcess(name)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('root', type=Path)
    parser.add_argument('action', choices=['launch', 'list', 'logs', 'start', 'stop', 'restart', 'create', 'update', 'delete'])
    parser.add_argument('name', nargs='?', default='')
    parser.add_argument('stream', nargs='?', choices=['stdout', 'stderr'], default='stdout')
    parser.add_argument('argv', nargs='?', default='[]')
    args = parser.parse_args()
    try:
        print(json.dumps(run(args.root, args.action, args.name, args.stream, json.loads(args.argv))))
    except (ValueError, OSError, xmlrpc.client.Fault, subprocess.SubprocessError) as exc:
        sys.exit(str(exc))
