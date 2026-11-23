"""Privileged integration test. Run only inside the disposable initramfs guest."""
import errno
import fcntl
import mmap
import ctypes as C
import json
import os
from pathlib import Path
import subprocess
import sys


def main():
    assert Path('/proc/cmdline').read_text().split().count('hampanel_tamper_guest=1') == 1
    base = Path('/testdisk'); p = base/'protected'; alias = base/'alias'; q = base/'other'
    assert os.path.ismount(base)
    def api(op, path='', code=0):
        r = subprocess.run([sys.executable, '-I', '/usr/libexec/hampanel/tamper_lsm.py', op, str(path)], capture_output=True, timeout=10)
        assert r.returncode == code, (op, r.stderr, r.stdout)
        return json.loads(r.stdout) if not code else None
    def denied(fn):
        try: fn()
        except OSError as e:
            assert e.errno == errno.EPERM, e
        else: raise AssertionError('expected kernel denial')
    if p.exists():
        # Second boot: unchanged inode must be rearmed, swapped inode must not.
        assert not Path('/sys/fs/bpf/hampanel_tamper_v1').exists()
        q.rename(base/'old'); q.write_bytes(b'replacement')
        report = api('restore'); assert report['degraded']
        denied(p.unlink); q.write_bytes(b'still writable'); api('add', q, 13)
        api('remove', q); api('remove', p); p.unlink(); assert not api('status')['entries']
        print('TAMPER_VM_PASS', flush=True)
        return
    if 'bpf' not in Path('/sys/kernel/security/lsm').read_text().strip().split(','):
        api('status', code=10); print('TAMPER_UNSUPPORTED_PASS'); return
    p.write_bytes(b'payload'); q.touch(); alias.hardlink_to(p)
    link = base/'symlink'; link.symlink_to(p)
    api('add', link, 11); api('add', base, 11)
    fd = os.open(p, os.O_RDWR)
    libc = C.CDLL(None, use_errno=True); libc.mmap.restype = C.c_void_p
    addr = libc.mmap(None, 7, mmap.PROT_READ, mmap.MAP_SHARED, fd, 0)
    assert addr != C.c_void_p(-1).value
    assert api('add', p)['entries'][0]['inode_guarded']
    denied(lambda: mmap.mmap(fd, 7, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE))
    assert libc.mprotect(C.c_void_p(addr), 7, mmap.PROT_READ | mmap.PROT_WRITE) == -1 and C.get_errno() == errno.EPERM
    with mmap.mmap(fd, 7, mmap.MAP_PRIVATE, mmap.PROT_READ | mmap.PROT_WRITE) as private: private[0] = 0
    api('restore'); api('add', alias, 13)
    denied(lambda: os.write(fd, b'x')); denied(lambda: os.ftruncate(fd, 0))
    denied(lambda: os.truncate(p, 0)); denied(lambda: alias.write_bytes(b'x'))
    denied(lambda: p.rename(base/'new')); denied(lambda: q.rename(p)); denied(alias.unlink)
    assert p.read_bytes() == b'payload'
    manifest = Path('/var/lib/hampanel-tamper-lsm/manifest'); assert manifest.stat().st_mode & 0o777 == 0o600
    lock = os.open(manifest.parent, os.O_DIRECTORY); fcntl.flock(lock, fcntl.LOCK_EX)
    api('status', code=13); os.close(lock)
    backup = manifest.with_name('backup'); manifest.rename(backup); manifest.symlink_to(backup)
    api('status', code=14); denied(p.unlink); manifest.unlink(); backup.rename(manifest)
    pins = Path('/sys/fs/bpf/hampanel_tamper_v1'); (pins/'hp_open').rename(pins/'saved'); (pins/'hp_write').rename(pins/'hp_open')
    api('status', code=13); (pins/'hp_open').unlink(); (pins/'saved').rename(pins/'hp_open')
    (pins/'hp_open').unlink()
    assert not api('restore')['degraded']; denied(lambda: os.open(p, os.O_RDWR))
    api('add', q); os.close(fd); os.sync()
    print('TAMPER_FIRST_BOOT_PASS', flush=True)


if __name__ == '__main__': main()
