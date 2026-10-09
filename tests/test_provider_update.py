"""Isolated CGI regression tests. Needs POSIX sh, jq and Python 3."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SOURCE = Path(os.environ.get('CGI_TEST_SOURCE', str(Path(__file__).resolve().parents[1] / 'payload/ui/mihomo.cgi')))
MOCK_CURL = '''#!/usr/bin/env python3
import json, os, pathlib, sys
p = pathlib.Path(os.environ['PROVIDER_TEST_DIR'])
args = sys.argv[1:]
method = args[args.index('-X') + 1]
with (p / 'calls').open('a') as f:
    f.write(method + '\\n')
if method == 'GET':
    if (p / 'get-fails').exists(): sys.exit(22)
    print((p / 'provider.json').read_text())
else:
    sys.exit(22 if (p / 'put-fails').exists() else 0)
'''


@unittest.skipUnless(shutil.which('jq'), 'jq is required')
class ProviderUpdateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='mihomo-provider-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'etc/providers').mkdir(parents=True)
        (self.root / 'etc/api.secret').write_text('test-only')
        (self.root / 'etc/ports.env').write_text('CONTROLLER_PORT=9090\n')
        mock = self.root / 'curl'
        mock.write_text(MOCK_CURL)
        mock.chmod(0o755)
        self.cgi = self.root / 'mihomo.cgi'
        source = SOURCE.read_text()
        self.assertIn('PLUGIN_HOME="/home/$plugin_user/plugin/mihomo"', source)
        self.cgi.write_text(source.replace('PLUGIN_HOME="/home/$plugin_user/plugin/mihomo"', 'PLUGIN_HOME="' + str(self.root) + '"', 1))

    def call(self, name='APP-MANUAL', vehicle='File', nodes=None, file_text='{"proxies":[]}', failure=None):
        (self.root / 'provider.json').write_text(json.dumps({'vehicleType':vehicle,'proxies':nodes or []}))
        if file_text is not None:
            filename = 'app-subscription.yaml' if name == 'APP-SUBSCRIPTION' else 'app-manual.yaml'
            (self.root / 'etc/providers' / filename).write_text(file_text)
        if failure:
            (self.root / failure).touch()
        body = json.dumps({'provider':name}).encode()
        env = dict(os.environ, PATH=str(self.root) + ':' + os.environ['PATH'],
                   PROVIDER_TEST_DIR=str(self.root), QUERY_STRING='action=update_provider',
                   REQUEST_METHOD='POST', CONTENT_LENGTH=str(len(body)))
        result = subprocess.run(['/bin/sh', str(self.cgi)], input=body, capture_output=True, env=env, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        response = json.loads(result.stdout.split(b'\r\n\r\n', 1)[1])
        calls = (self.root / 'calls').read_text().splitlines()
        return response, calls

    def test_empty_manual_is_skipped(self):
        result, calls = self.call()
        self.assertTrue(result['ok'] and result['skipped'])
        self.assertEqual(calls, ['GET'])

    def test_empty_managed_subscription_is_skipped(self):
        result, calls = self.call(name='APP-SUBSCRIPTION')
        self.assertTrue(result['skipped'])
        self.assertEqual(calls, ['GET'])

    def test_builtin_provider_is_skipped(self):
        result, calls = self.call(name='PROXY', vehicle='Compatible', nodes=[{'name':'DIRECT'}])
        self.assertTrue(result['skipped'])
        self.assertEqual(calls, ['GET'])

    def test_populated_manual_updates(self):
        result, calls = self.call(nodes=[{'name':'test'}], file_text='{"proxies":[{"name":"test"}]}')
        self.assertTrue(result['ok'])
        self.assertNotIn('skipped', result)
        self.assertEqual(calls, ['GET','PUT'])

    def test_empty_http_provider_is_retried(self):
        result, calls = self.call(name='remote', vehicle='HTTP')
        self.assertTrue(result['ok'])
        self.assertEqual(calls, ['GET','PUT'])

    def test_nonempty_file_with_stale_runtime_is_retried(self):
        result, calls = self.call(file_text='{"proxies":[{"name":"test"}]}')
        self.assertEqual(calls, ['GET','PUT'])

    def test_corrupt_file_failure_is_not_hidden(self):
        result, calls = self.call(file_text='invalid', failure='put-fails')
        self.assertFalse(result['ok'])
        self.assertEqual(calls, ['GET','PUT'])

    def test_missing_file_failure_is_not_hidden(self):
        result, calls = self.call(file_text=None, failure='put-fails')
        self.assertFalse(result['ok'])
        self.assertEqual(calls, ['GET','PUT'])

    def test_unavailable_controller_is_an_error(self):
        result, calls = self.call(failure='get-fails')
        self.assertFalse(result['ok'])
        self.assertEqual(calls, ['GET'])

    def test_http_failure_is_not_hidden(self):
        result, calls = self.call(name='remote', vehicle='HTTP', failure='put-fails')
        self.assertFalse(result['ok'])
        self.assertEqual(calls, ['GET','PUT'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
