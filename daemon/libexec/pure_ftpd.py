"""Private Pure-FTPd instance. Caller supplies a trusted, service-owned parent."""
import argparse
import fcntl
import os
from pathlib import Path
import re
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['init', 'start', 'add', 'delete'])
    parser.add_argument('root', type=Path)
    parser.add_argument('--port', type=int, default=2121)
    parser.add_argument('--name')
    parser.add_argument('--uid', type=int)
    parser.add_argument('--gid', type=int)
    args = parser.parse_args()
    root = args.root.resolve()
    if not re.fullmatch(r'/[a-zA-Z0-9_./-]+', str(root)) or not 1024 <= args.port <= 65535:
        parser.error('invalid path or port')
    os.umask(0o077)
    root.mkdir(mode=0o711, exist_ok=True)
    if root.stat().st_uid != os.geteuid() or root.stat().st_mode & 0o066:
        parser.error('instance directory must be owned by service and not readable or writable by others')
    os.chdir(root)
    with open('lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        conf = Path('pure-ftpd.conf')
        if args.action == 'init':
            if conf.exists():
                parser.error('already initialized')
            # Administrator provisions the trusted certificate and key bundle.
            if not Path('server.pem').is_file() or Path('server.pem').stat().st_mode & 0o077:
                parser.error('private server.pem required')
            Path('users').touch()
            subprocess.run(['pure-pw', 'mkdb', 'users.pdb', '-f', 'users'], check=True)
            Path('homes').mkdir(mode=0o711, exist_ok=True)
            Path('homes').chmod(0o711)
            Path('config.new').write_text(f'''Bind 127.0.0.1,{args.port}
IPV4Only yes
Daemonize no
DontResolve yes
NoAnonymous yes
ChrootEveryone yes
TLS 3
CertFile {root}/server.pem
PureDB {root}/users.pdb
PIDFile {root}/pure-ftpd.pid
''')
            Path('config.new').replace(conf)
            # The mapped FTP identity needs search (not listing) permission.
            root.chmod(0o711)
        elif not conf.is_file():
            parser.error('not initialized')
        elif args.action == 'start':
            os.execlp('pure-ftpd', 'pure-ftpd', str(root / conf))
        else:
            if not re.fullmatch('[a-z][a-z0-9_-]{0,31}', args.name or ''):
                parser.error('invalid virtual name')
            cmd = ['pure-pw', 'user' + ('add' if args.action == 'add' else 'del'), args.name, '-f', 'users.next']
            data = None
            if args.action == 'add':
                if not args.uid or args.uid < 1 or not args.gid or args.gid < 1:
                    parser.error('dedicated unprivileged UID/GID required')
                password = sys.stdin.buffer.read(1025)
                if not 1 <= len(password) <= 1024 or any(x in password for x in (b'\n', b'\r', b'\0')):
                    parser.error('invalid password')
                data = (password + b'\n') * 2
                home = root / 'homes' / args.name
                home.mkdir()  # Never reassign a retained home to another login.
                os.chown(home, args.uid, args.gid)
                cmd += ['-u', str(args.uid), '-g', str(args.gid), '-d', str(home)]
            Path('users.next').write_bytes(Path('users').read_bytes())
            try:
                subprocess.run(cmd, input=data, check=True)
                subprocess.run(['pure-pw', 'mkdb', 'db.next', '-f', 'users.next'], check=True)
                Path('users.next').replace('users')
                Path('db.next').replace('users.pdb')
            except Exception:
                if args.action == 'add':
                    home.rmdir()
                raise


if __name__ == '__main__':
    main()
