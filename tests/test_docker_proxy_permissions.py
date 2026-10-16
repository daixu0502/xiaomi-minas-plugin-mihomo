"""Exercise real CGI argument construction against the installer's exact policy.

All commands are local fixtures; no sudo, Docker or production services run.
"""
import json
import importlib.util
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = '/data/plugin/.mihomo-system/mihomo-docker-proxy'


def installer_policy(user, port):
    source = (ROOT / 'manage.sh').read_text()
    start = source.index("printf '%s ALL=(root) NOPASSWD:")
    end = source.index('\nchown root:root "$docker_sudoers_tmp"', start)
    with tempfile.TemporaryDirectory() as scratch:
        target = Path(scratch) / 'policy'
        env = dict(os.environ, PLUGIN_USER=user, DOCKER_HELPER=HELPER,
                   MIXED_PORT=str(port), docker_sudoers_tmp=str(target))
        subprocess.run(['/bin/sh', '-c', source[start:end]], env=env, check=True)
        return target.read_text()


@unittest.skipUnless(shutil.which('jq') and Path('/bin/sh').exists(), 'POSIX shell and jq required')
class ProxyPermissionTests(unittest.TestCase):
    def call(self, method='GET', body='', port=7890):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            mock = root / 'bin'
            mock.mkdir()
            policy = installer_policy('u123', port)
            (root / 'policy').write_text(policy.replace(HELPER, str(root / 'helper')))
            (root / 'helper').write_text('#!/bin/sh\nprintf \'{"ok":true,"state":"pending_apply"}\\n\'\n')
            (root / 'helper').chmod(0o755)
            (mock / 'sudo').write_text('''#!/usr/bin/python3
import json,os,pathlib,shlex,sys
root=pathlib.Path(os.environ['TEST_PROXY_ROOT'])
args=sys.argv[1:]
assert args.pop(0)=='-n'
(root/'args.json').write_text(json.dumps(args))
allowed=[shlex.split(item.strip()) for item in (root/'policy').read_text().split('NOPASSWD:',1)[1].split(',')]
if args not in allowed:
    print('sudo: password required',file=sys.stderr)
    sys.exit(1)
os.execv(args[0],args)
''')
            (mock / 'sudo').chmod(0o755)
            for name in ('docker', 'systemctl'):
                (mock / name).write_text('#!/bin/sh\necho unexpected-service-command >&2\nexit 99\n')
                (mock / name).chmod(0o755)
            (root / 'ports.env').write_text('MIXED_PORT=' + str(port) + '\n')
            cgi = (ROOT / 'payload/ui/mihomo.cgi').read_text()
            cgi = cgi.replace('DOCKER_PROXY_HELPER="' + HELPER + '"',
                              'DOCKER_PROXY_HELPER=' + shlex.quote(str(root / 'helper')))
            cgi = cgi.replace('PORTS_FILE="$ETC_DIR/ports.env"',
                              'PORTS_FILE=' + shlex.quote(str(root / 'ports.env')))
            (root / 'mihomo.cgi').write_text(cgi)
            env = dict(os.environ, TEST_PROXY_ROOT=str(root), PATH=str(mock)+':'+os.environ['PATH'],
                       QUERY_STRING='action=docker_proxy_status', REQUEST_METHOD=method,
                       CONTENT_LENGTH=str(len(body.encode())))
            result = subprocess.run(['/bin/sh', str(root / 'mihomo.cgi')], env=env,
                                    input=body, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            response = json.loads(result.stdout.split('\n\n', 1)[1])
            self.assertTrue(response['ok'], response)
            self.assertEqual(response['state'], 'pending_apply')
            self.assertNotIn('unexpected-service-command', result.stderr)
            return json.loads((root / 'args.json').read_text())[1:]

    def test_get_has_no_empty_argument(self):
        self.assertEqual(self.call(), ['status', '7890'])

    def test_manual_refresh_is_explicitly_allowed(self):
        self.assertEqual(self.call('POST', '{"force":true}'), ['status', '7890', 'fresh'])

    def test_post_without_force_has_no_empty_argument(self):
        self.assertEqual(self.call('POST', '{"force":false}'), ['status', '7890'])

    def test_nondefault_port(self):
        self.assertEqual(self.call(port=17890), ['status', '17890'])
        self.assertEqual(self.call('POST', '{"force":true}', 17890), ['status', '17890', 'fresh'])

    def test_exact_policy_does_not_broaden_mutating_actions(self):
        policy = installer_policy('u123', 17890)
        commands = [shlex.split(item.strip()) for item in policy.split('NOPASSWD:', 1)[1].split(',')]
        self.assertEqual(commands, [[HELPER, 'status', '17890'], [HELPER, 'status', '17890', 'fresh'],
                                    [HELPER, 'enable', '17890'], [HELPER, 'disable', '17890']])
        self.assertNotIn('*', policy)

    def test_deployment_policy_matches_installer(self):
        spec = importlib.util.spec_from_file_location('proxy_deployment', ROOT / 'tests/deploy_proxy_permissions.py')
        deployment = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(deployment)
        self.assertEqual(deployment.policy('u123', 17890), installer_policy('u123', 17890))


if __name__ == '__main__':
    unittest.main()
