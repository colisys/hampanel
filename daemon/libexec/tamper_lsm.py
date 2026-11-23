"""One-shot loader; the kernel, not this process, owns enforcement."""
import ctypes as C
import errno
import fcntl
import json
import os
from pathlib import Path
import stat
import struct
import sys


STATE = Path('/var/lib/hampanel-tamper-lsm')
PIN = Path('/sys/fs/bpf/hampanel_tamper_v1')
OBJ = Path(__file__).with_name('tamper.bpf.o')
HOOKS = ('hp_write', 'hp_open', 'hp_trunc', 'hp_ftrunc', 'hp_unlink', 'hp_rename', 'hp_mmap', 'hp_mprotect')
LIMIT = 64
SCOPE = {'backend': 'bpf_lsm', 'scope': 'ext_regular_inode_including_hardlinks',
         'guards': ['write_open', 'vfs_write_permission', 'truncate', 'ftruncate', 'rename_source_and_destination', 'unlink', 'new_shared_writable_mapping', 'shared_mprotect_write'],
                  'capacity': LIMIT, 'reboot_recovery': 'on_daemon_start_if_identity_matches',
         'excludes': ['preexisting_writable_mappings', 'already_in_flight_operations', 'filesystem_ioctls', 'raw_device_io', 'privileged_policy_changes']}


class Unsupported(Exception): pass
class Conflict(Exception): pass


def private_dir(path):
    path.mkdir(mode=0o700, exist_ok=True)
    s = path.lstat()
    if not stat.S_ISDIR(s.st_mode) or s.st_uid != 0 or s.st_mode & 0o077:
        raise PermissionError('unsafe private directory')


def valid_path(path):
    if not isinstance(path, str) or not path.startswith('/') or any(x in ('', '.', '..') for x in path[1:].split('/')) or len(os.fsencode(path)) > 4095 or '\0' in path:
        raise ValueError('canonical absolute path required')
    if any(Path(path).is_relative_to(p) for p in (STATE, PIN, OBJ.parent)):
        raise ValueError('reserved path')


def identity(path):
    valid_path(path)
    flags = os.O_PATH | os.O_NOFOLLOW
    fd = os.open('/', flags | os.O_DIRECTORY)
    try:
        parts = path[1:].split('/')
        reserved = [p.stat() for p in (STATE, OBJ.parent)]
        for n, part in enumerate(parts):
            nxt = os.open(part, flags | (os.O_DIRECTORY if n+1 < len(parts) else 0), dir_fd=fd)
            os.close(fd)
            fd = nxt
            if any(os.path.samestat(os.fstat(fd), r) for r in reserved): raise ValueError('reserved directory alias')
        s = os.fstat(fd)
        if not stat.S_ISREG(s.st_mode): raise ValueError('regular file required')
        libc = C.CDLL(None, use_errno=True)
        fs = (C.c_long * 32)()
        if libc.fstatfs(fd, fs) or fs[0] != 0xef53: raise Unsupported('ext filesystem required')
        # Export file handle includes generation: do not restore on inode-number reuse.
        handle = C.create_string_buffer(136)
        struct.pack_into('=I', handle, 0, 128)
        if libc.name_to_handle_at(fd, b'', handle, C.byref(C.c_int()), 0x1000):
            raise Unsupported('stable file handle required')
        size, kind = struct.unpack_from('=Ii', handle)
        if not 0 < size <= 128: raise Unsupported('invalid file handle')
        dev = (os.major(s.st_dev) << 20) | os.minor(s.st_dev)
        return fd, [dev, s.st_ino, kind, handle.raw[8:8+size].hex()]
    except BaseException:
        os.close(fd)
        raise


def load_state():
    try: fd = os.open(STATE/'manifest', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError: return {}
    with os.fdopen(fd, 'rb') as f:
        s = os.fstat(fd)
        if not stat.S_ISREG(s.st_mode) or s.st_nlink != 1 or s.st_uid or s.st_mode & 0o077 or s.st_size > 2**21:
            raise PermissionError('unsafe manifest')
        doc = json.loads(f.read(2**21+1))
    if doc.get('version') != 1: raise ValueError('unknown manifest version')
    rows = doc['entries']
    if not isinstance(rows, dict) or len(rows) > LIMIT: raise ValueError('invalid manifest')
    for path, row in rows.items():
        valid_path(path)
        if not isinstance(row, list) or len(row) != 4 or any(type(x) != int or not 0 <= x < 2**64 for x in row[:3]) or not 0 < len(bytes.fromhex(row[3])) <= 128: raise ValueError('invalid identity')
    return rows


def commit(rows):
    # A fixed staging name bounds debris even on repeated timeout/SIGKILL.
    tmp = STATE/'next'
    tmp.unlink(missing_ok=True)
    with tmp.open('x') as f:
        json.dump({'version': 1, 'entries': rows}, f)
        f.flush(); os.fsync(f.fileno())
    tmp.replace(STATE/'manifest')
    fd = os.open(STATE, os.O_DIRECTORY)
    try: os.fsync(fd)
    finally: os.close(fd)


class Kernel:
    def __init__(self):
        try: lib = C.CDLL('libbpf.so.1', use_errno=True)
        except OSError as e: raise Unsupported('libbpf.so.1 required') from e
        p, i, s = C.c_void_p, C.c_int, C.c_char_p
        def bind(name, result, *args):
            f = getattr(lib, name); f.restype = result; f.argtypes = args
            return f
        get = bind('bpf_obj_get', i, s)
        open_obj = bind('bpf_object__open_file', p, s, p)
        load = bind('bpf_object__load', i, p)
        find_map = bind('bpf_object__find_map_by_name', p, p, s)
        reuse = bind('bpf_map__reuse_fd', i, p, i)
        pin_map = bind('bpf_map__pin', i, p, s)
        find_prog = bind('bpf_object__find_program_by_name', p, p, s)
        attach = bind('bpf_program__attach_lsm', p, p)
        pin_link = bind('bpf_link__pin', i, p, s)
        self.update = bind('bpf_map_update_elem', i, i, p, p, C.c_uint64)
        self.delete = bind('bpf_map_delete_elem', i, i, p)
        self.next = bind('bpf_map_get_next_key', i, i, p, p)
        try: active = Path('/sys/kernel/security/lsm').read_text().strip().split(',')
        except OSError as e: raise Unsupported('securityfs required') from e
        if 'bpf' not in active: raise Unsupported('BPF LSM is not active')
        fs = (C.c_long * 32)()
        if C.CDLL(None).statfs(os.fsencode(PIN.parent), fs) or fs[0] != 0xcafe4a11: raise Unsupported('mounted bpffs required')
        private_dir(PIN)
        mp = os.fsencode(PIN/'guards')
        self.fd = get(mp)
        missing = [n for n in HOOKS if not (PIN/n).exists()]
        if self.fd < 0 and len(missing) != len(HOOKS): raise Conflict('map pin missing under live links')
        if missing:
            obj = open_obj(os.fsencode(OBJ), None)
            if not obj: raise Unsupported('BPF object unavailable')
            m = find_map(obj, b'guards')
            if not m or (self.fd >= 0 and reuse(m, self.fd)): raise Conflict('incompatible map')
            if load(obj): raise Unsupported('kernel rejected required LSM hooks')
            if self.fd < 0:
                if pin_map(m, mp): raise OSError('cannot pin guard map')
                self.fd = get(mp)
            for name in missing:
                prog = find_prog(obj, name.encode())
                link = attach(prog) if prog else None
                if not link or pin_link(link, os.fsencode(PIN/name)): raise Unsupported('cannot attach '+name)
        if self.fd < 0: raise OSError('cannot open guard map')
        # Stable UAPI prefixes from linux/bpf.h. Never interpret keys from an
        # unchecked pin (the kernel copies map.key_size bytes into our buffer).
        info = bind('bpf_obj_get_info_by_fd', i, i, p, p)
        by_id = bind('bpf_prog_get_fd_by_id', i, C.c_uint32)
        def inspect(fd, buf):
            size = C.c_uint32(len(buf))
            if fd < 0 or info(fd, buf, C.byref(size)): raise Conflict('unreadable pin')
            return buf.raw
        mi = inspect(self.fd, C.create_string_buffer(40))
        typ, mid, ks, vs, limit = struct.unpack_from('=5I', mi)
        if (typ, ks, vs, limit) != (1, 16, 1, LIMIT) or mi[24:40].rstrip(b'\0') != b'guards': raise Conflict('unexpected map schema')
        for name in HOOKS:
            linkfd = get(os.fsencode(PIN/name))
            li = inspect(linkfd, C.create_string_buffer(32)); os.close(linkfd)
            typ, _, pid, _, attachment = struct.unpack_from('=5I', li)
            if typ != 2 or attachment != 27: raise Conflict('not a MAC LSM link')
            progfd = by_id(pid); buf = C.create_string_buffer(80); map_id = C.c_uint32()
            struct.pack_into('=IQ', buf, 52, 1, C.addressof(map_id))
            pi = inspect(progfd, buf); os.close(progfd)
            if struct.unpack_from('=I', pi, 52)[0] != 1 or map_id.value != mid or pi[64:80].rstrip(b'\0') != name.encode(): raise Conflict('link does not enforce guard map')

    def keys(self):
        result = set(); prev = None
        while True:
            key = C.create_string_buffer(16)
            if self.next(self.fd, prev, key):
                if C.get_errno() != errno.ENOENT: raise OSError('map iteration failed')
                return result
            if key.raw in result or len(result) >= LIMIT: raise Conflict('invalid map contents')
            result.add(key.raw); prev = key


def run(op, path):
    os.umask(0o077)
    if os.geteuid() or C.sizeof(C.c_void_p) != 8 or sys.byteorder != 'little': raise Unsupported('64-bit little-endian root loader required')
    if op == 'restore' and not STATE.exists(): return {}
    private_dir(STATE)
    lock = os.open(STATE, os.O_DIRECTORY | os.O_NOFOLLOW)
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    try: rows = load_state()
    except (ValueError, TypeError, KeyError, AttributeError) as e: raise Conflict('invalid persistent manifest') from e
    if op == 'restore' and not rows and not PIN.exists(): return {}
    if op in ('add', 'remove'): valid_path(path)
    kernel = Kernel()
    if op == 'add':
        fd, row = identity(path)  # hold through map install and post-check
        if path in rows and rows[path] != row: raise Conflict('identity changed')
        if path not in rows and (len(rows) >= LIMIT or row in rows.values()): raise Conflict('capacity or duplicate inode')
        rows[path] = row; commit(rows)
    elif op == 'remove':
        if path not in rows: raise FileNotFoundError('unknown policy')
        del rows[path]; commit(rows)
    elif op not in ('restore', 'status'): raise ValueError('unknown operation')
    # Manifest is desired state. Replay interrupted transactions idempotently.
    live = kernel.keys(); wanted = set(); entries = []
    desired = {struct.pack('=QQ', *row[:2]) for row in rows.values()}
    for orphan in live - desired:
        if kernel.delete(kernel.fd, orphan): raise OSError('map delete failed')
    live &= desired
    for target, expected in rows.items():
        key = struct.pack('=QQ', *expected[:2]); match = False
        try:
            held, actual = identity(target)
            match = actual == expected
        except (OSError, ValueError, Unsupported): pass
        if match:
            if key not in live and kernel.update(kernel.fd, key, b'\x01', 0): raise OSError('map update failed')
            wanted.add(key)
            try:
                check, actual = identity(target); os.close(check); match = actual == expected
            except (OSError, ValueError, Unsupported): match = False
        elif key in live:
            # Path may have disappeared via ancestor rename. Keep the live inode protected.
            wanted.add(key)
        entries.append({'path': target, 'identity_matches': match, 'inode_guarded': key in wanted})
    for key in live - wanted:
        if kernel.delete(kernel.fd, key): raise OSError('map delete failed')
    if op == 'add' and not next(e['identity_matches'] for e in entries if e['path'] == path): raise Conflict('target moved during activation')
    return dict(SCOPE, entries=entries, degraded=any(not e['identity_matches'] for e in entries))


if __name__ == '__main__':
    try: print(json.dumps(run(*sys.argv[1:]), ensure_ascii=True))
    except Exception as e:
        print(str(e), file=sys.stderr)
        sys.exit(10 if isinstance(e, Unsupported) else 11 if isinstance(e, ValueError) else 12 if isinstance(e, FileNotFoundError) else 13 if isinstance(e, (Conflict, BlockingIOError)) else 14)
