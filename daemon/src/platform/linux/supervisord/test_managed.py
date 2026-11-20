import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class ManagedTest(unittest.TestCase):
    def test_instance(self):
        helper = Path(__file__).with_name('managed.py').resolve()
        with tempfile.TemporaryDirectory(prefix='') as tmp:
            root = Path(tmp)
            (root / 'programs').mkdir()
            (root / 'programs/test.ini').write_text('''[program:fixture]
command=/bin/sh -c "echo ready; echo diagnostic >&2; exec sleep 60"
autostart=false
''')

            def call(*args):
                return json.loads(subprocess.check_output([sys.executable, helper, tmp, *args]))

            try:
                self.assertEqual(call('list'), [])
                self.assertEqual(call('launch')['statename'], 'RUNNING')
                name = 'fixture:fixture'
                self.assertTrue(call('start', name))
                pid = call('list')[0]['pid']
                os.kill(pid, 0)
                self.assertIn('ready', call('logs', name))
                self.assertIn('diagnostic', call('logs', name, 'stderr'))
                self.assertTrue(call('restart', name))
                self.assertNotEqual(pid, call('list')[0]['pid'])
                self.assertTrue(call('stop', name))
                self.assertEqual(call('list')[0]['state'], 'STOPPED')
                def edit(action, *argv):
                    return call(action, '--', 'worker', 'stdout', json.dumps(argv))
                command = [sys.executable, helper, tmp, 'create', '--', 'worker', 'stdout',
                           json.dumps(['/bin/sleep', '60'])]
                peers = [subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                         for _ in range(2)]
                replies = [p.communicate(timeout=15) for p in peers]
                self.assertEqual(sorted(p.returncode for p in peers), [0, 1])
                self.assertIn(b'already exists', b''.join(err for _, err in replies))
                for target in ('fixture', '../worker'):
                    with self.assertRaises(subprocess.CalledProcessError):
                        call('delete', '--', target)
                config = root / 'programs/panel-worker.ini'
                self.assertEqual(config.stat().st_mode & 0o777, 0o600)
                for argv in [('/bin/sh', '-c', 'id'), ('/bin/echo', '%(here)s'), ('/bin/echo', 'a;id')]:
                    with self.assertRaises(subprocess.CalledProcessError):
                        edit('update', *argv)
                self.assertTrue(edit('update', '/bin/echo', 'updated'))
                import time
                for _ in range(20):
                    if 'updated' in call('logs', 'worker:worker'):
                        break
                    time.sleep(.1)
                self.assertIn('updated', call('logs', 'worker:worker'))
                self.assertTrue(edit('delete'))
                self.assertFalse(config.exists())
                self.assertEqual([p['name'] for p in call('list')], [name])
            finally:
                if (root / 's').exists():
                    subprocess.run(['supervisorctl', '-c', str(root/'supervisord.conf'), 'shutdown'], cwd=root, check=True)


if __name__ == '__main__':
    unittest.main()
