#!/usr/bin/env python3
"""Private clamd instance; JSON on stdout. Never controls distribution services."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys


def run(*args, timeout=60):
    return subprocess.run(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, text=True, errors='replace', timeout=timeout)


def manage(root, action, database, threads, path):
    if not root.is_absolute() or any(ord(c) < 32 for c in str(root)):
        raise ValueError('invalid private directory')
    root.mkdir(mode=0o700, exist_ok=True)
    if root.is_symlink() or root.stat().st_uid != os.geteuid() or root.stat().st_mode & 0o077:
        raise ValueError('private directory must be owned by daemon and mode 0700')
    conf = root / 'clamd.conf'
    sock = root / 's'
    if len(os.fsencode(sock)) >= 104:
        raise ValueError('socket path too long')
    with (root / 'lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX if action == 'initialize' else fcntl.LOCK_SH)
        client = ['clamdscan', '--config-file', str(conf)]
        def alive():
            return conf.exists() and run(*client, '--ping=1', timeout=5).returncode == 0
        if action == 'status':
            return dict(initialized=conf.exists(), active=alive())
        if action == 'initialize':
            if not database.is_absolute() or not database.is_dir() or any(ord(c) < 32 for c in str(database)) or not 1 <= threads <= 16:
                raise ValueError('invalid database directory or threads (1..16)')
            config = f'DatabaseDirectory {database}\nLocalSocket {sock}\nLocalSocketMode 0600\nPidFile {root}/pid\nMaxThreads {threads}\nFollowDirectorySymlinks no\nFollowFileSymlinks no\n'
            if os.geteuid() == 0:
                raise ValueError('run helper as a dedicated unprivileged account')
            if alive():
                if conf.read_text() != config:
                    raise ValueError('instance active with different configuration')
                return dict(ok=True, output='Already running')
            previous = conf.read_bytes() if conf.exists() else None
            conf.write_text(config)
            try:
                result = run('clamd', '--config-file', str(conf), timeout=180)
                if result.returncode:
                    raise ValueError(result.stdout.strip() or 'clamd startup failed')
                ready = run(*client, '--ping=10', timeout=15)
                if ready.returncode:
                    raise ValueError('started but readiness unconfirmed')
            except (OSError, ValueError, subprocess.SubprocessError):
                if previous is None:
                    conf.unlink(missing_ok=True)
                else:
                    conf.write_bytes(previous)
                raise
            return dict(ok=True, output='Private clamd ready')
        if not path or not Path(path).is_absolute() or not (Path(path).is_file() or Path(path).is_dir()):
            raise ValueError('expected absolute file or directory')
        if not alive():
            raise ValueError('private clamd unavailable')
        if Path(path).is_dir():
            client.append('--multiscan')
        result = run(*client, '--infected', '--', path, timeout=300)
        return dict(verdict={0: 'clean', 1: 'infected'}.get(result.returncode, 'error'),
                    exit_code=result.returncode, output=result.stdout[-65536:])


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('root', type=Path)
    parser.add_argument('action', choices=['initialize', 'status', 'scan'])
    parser.add_argument('--database', type=Path, default=Path('/var/lib/clamav'))
    parser.add_argument('--threads', type=int, default=2)
    parser.add_argument('--path')
    try:
        print(json.dumps(manage(**vars(parser.parse_args()))))
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        print(json.dumps(dict(error=str(exc))))
        sys.exit(2)
