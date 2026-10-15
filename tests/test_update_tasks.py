"""Detached jobs, file rollback and hot loading with local fixtures; no NAS access."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

FILES = Path(__file__).resolve().parents[1] / 'payload/files'
MOCK_CURL = r'''#!/usr/bin/env python3
import hashlib,json,os,pathlib,sys,time
home=pathlib.Path(os.environ['PLUG_HOME_DIR']);args=sys.argv[1:]
time.sleep(float((home/'delay').read_text()) if (home/'delay').exists() else 0)
code=int((home/'curl-code').read_text()) if (home/'curl-code').exists() else 0
if code:print('403' if code==22 else '000',end='');sys.exit(code)
target=pathlib.Path(args[args.index('--output')+1]);url=args[-1]
with (home/'curl-calls').open('a') as out:out.write(url+'\n')
if '/releases/latest' in url:
 data={'assets':[{'name':n,'browser_download_url':'https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/'+n,'digest':'sha256:'+hashlib.sha256((home/n).read_bytes()).hexdigest()} for n in ('geoip.dat','geosite.dat')]}
 target.write_text(json.dumps(data))
elif url.endswith('/geoip.dat'):target.write_bytes((home/'geoip.dat').read_bytes())
elif url.endswith('/geosite.dat'):target.write_bytes((home/'geosite.dat').read_bytes())
else:target.write_bytes((home/'download').read_bytes())
print('200',end='')
'''


@unittest.skipUnless(shutil.which('jq'), 'requires jq')
class UpdateTasksTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='mihomo-jobs-')
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        for sub in ('src/files', 'src/ui', 'etc/providers', 'var', 'scripts', 'mock-bin'):
            (self.home / sub).mkdir(parents=True)
        for name in ('update_tasks.py', 'update-common.sh', 'subscription.sh', 'config-tools.sh', 'geodata.sh', 'rule-provider.sh', 'rule_provider_editor.py'):
            (self.home / 'src/files' / name).write_bytes((FILES / name).read_bytes().replace(b'\r\n', b'\n'))
        core = self.home / 'src/files/mihomo'
        core.write_text('#!/bin/sh\n[ ! -e "$PLUG_HOME_DIR/reject-config" ]\n'); core.chmod(0o755)
        control = self.home / 'scripts/control'
        control.write_text('#!/bin/sh\nprintf "%s\\n" "$1" >> "$PLUG_HOME_DIR/control-calls"\nexit 0\n'); control.chmod(0o755)
        curl = self.home / 'mock-bin/curl'; curl.write_text(MOCK_CURL); curl.chmod(0o755)
        self.env = dict(os.environ, PLUG_HOME_DIR=str(self.home), PYTHONDONTWRITEBYTECODE='1',
                        PATH=str(self.home / 'mock-bin') + ':' + os.environ['PATH'])
        self.env.pop('MIHOMO_TASK_ID', None); self.env.pop('MIHOMO_TASK_LOCKED', None)
        self.old = 'proxies:\n  - name: old\n    type: socks5\n    server: 127.0.0.1\n    port: 9\n'
        (self.home / 'etc/providers/app-subscription.yaml').write_text(self.old)
        (self.home / 'etc/providers/app-manual.yaml').write_text('{"proxies":[]}')
        (self.home / 'etc/subscription.url').write_text('https://example.invalid/subscribe?token=fixture-secret\n')
        (self.home / 'etc/config.yaml').write_text('mixed-port: 0\nmode: rule\nproxy-groups:\n  - name: PROXY\n    type: select\n    proxies: [DIRECT]\nrules:\n  - MATCH,PROXY\n')
        (self.home / 'etc/api.secret').write_text('test-only')
        (self.home / 'download').write_text(self.old.replace('name: old', 'name: new'))
        for name in ('geoip.dat', 'geosite.dat'):
            (self.home / name).write_bytes((name.encode() * 300))
            (self.home / ('etc/GeoIP.dat' if name == 'geoip.dat' else 'etc/GeoSite.dat')).write_bytes(b'old')
        self.calls = []; self.http_failure = False
        owner = self
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_PUT(self):
                owner.calls.append(self.path)
                self.rfile.read(int(self.headers.get('Content-Length', 0)))
                self.send_response(500 if owner.http_failure else 204); self.end_headers()
                if owner.http_failure:self.wfile.write(b'{"message":"fixture failure"}')
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close); self.addCleanup(server.shutdown)
        (self.home / 'etc/ports.env').write_text('CONTROLLER_PORT=%d\nMIXED_PORT=7890\n' % server.server_port)
        # A local inert Python process models ownership/PID checks; never a real proxy.
        self.core = subprocess.Popen([str(core), '-c', 'import time;time.sleep(120)'], executable=sys.executable)
        self.addCleanup(self.stop_core)
        (self.home / 'var/mihomo.pid').write_text(str(self.core.pid))

    def stop_core(self):
        self.core.terminate(); self.core.wait(timeout=5)

    def cli(self, *args, payload=None):
        result = subprocess.run([sys.executable, '-B', str(self.home / 'src/files/update_tasks.py'), *args],
                                input=json.dumps(payload or {}).encode(), capture_output=True, env=self.env, timeout=5)
        return json.loads(result.stdout)

    def launch(self, action='subscription_update', payload=None):
        packet = self.cli('start', action, payload=payload)
        self.assertTrue(packet.get('accepted'), packet)
        return packet['task']['id']

    def wait(self, ident):
        for _ in range(180):
            packet = self.cli('status', payload={'id': ident})
            task = packet.get('task')
            self.assertIsNotNone(task, packet)
            if task['status'] in ('succeeded', 'failed'):
                return task
            time.sleep(.05)
        self.fail('worker did not finish')

    def run_job(self, action='subscription_update', payload=None):
        return self.wait(self.launch(action, payload))

    def test_detached_ack_and_cross_action_exclusion(self):
        (self.home / 'delay').write_text('0.8')
        start = time.monotonic(); ident = self.launch()
        self.assertLess(time.monotonic() - start, .7)
        conflict = self.cli('start', 'geodata_apply_policy', payload={'policy':'direct'})
        self.assertFalse(conflict['ok']); self.assertIn('正在执行', conflict['error'])
        self.assertEqual(self.wait(ident)['status'], 'succeeded')

    def test_subscription_hot_updates_without_restart_or_source_changes(self):
        before = {p:hashlib.sha256(p.read_bytes()).hexdigest() for p in (self.home / 'src').rglob('*') if p.is_file()}
        task = self.run_job()
        self.assertEqual(task['status'], 'succeeded', task)
        self.assertFalse(task['result']['restarted'])
        self.assertEqual(self.calls, ['/providers/proxies/APP-SUBSCRIPTION'])
        self.assertIsNone(self.core.poll())
        self.assertFalse((self.home / 'control-calls').exists())
        self.assertEqual(before, {p:hashlib.sha256(p.read_bytes()).hexdigest() for p in before})
        self.assertFalse(list((self.home / 'src').rglob('__pycache__')))
        self.assertFalse(list((self.home / 'var/update-tasks').glob('*.request')))

    def test_unchanged_subscription_does_not_reload(self):
        (self.home / 'download').write_text(self.old)
        task = self.run_job(); self.assertTrue(task['result']['unchanged'])
        self.assertEqual(self.calls, [])

    def test_http_error_is_precise_and_redacted(self):
        (self.home / 'curl-code').write_text('22')
        task = self.run_job()
        self.assertEqual(task['status'], 'failed'); self.assertIn('HTTP 403', task['error'])
        self.assertNotIn('fixture-secret', json.dumps(task))
        self.assertEqual((self.home / 'etc/providers/app-subscription.yaml').read_text(), self.old)

    def test_timeout_error_is_precise(self):
        (self.home / 'curl-code').write_text('28')
        self.assertIn('超时', self.run_job()['error'])

    def test_non_yaml_response_preserves_old_nodes(self):
        (self.home / 'download').write_text('<html>not a subscription</html>')
        self.assertIn('Clash YAML', self.run_job()['error'])
        self.assertEqual((self.home / 'etc/providers/app-subscription.yaml').read_text(), self.old)

    def test_validation_failure_does_not_publish_candidate(self):
        (self.home / 'reject-config').touch()
        self.assertEqual(self.run_job()['status'], 'failed')
        self.assertEqual(self.calls, [])
        self.assertEqual((self.home / 'etc/providers/app-subscription.yaml').read_text(), self.old)

    def test_hot_reload_failure_restores_old_provider_without_restart(self):
        self.http_failure = True
        task = self.run_job()
        self.assertIn('HTTP 500', task['error'])
        self.assertEqual((self.home / 'etc/providers/app-subscription.yaml').read_text(), self.old)
        self.assertFalse((self.home / 'control-calls').exists())

    def test_geo_policy_is_hot_loaded(self):
        task = self.run_job('geodata_apply_policy', {'policy':'direct'})
        self.assertEqual(task['status'], 'succeeded', task)
        self.assertEqual(self.calls, ['/configs?force=true'])
        self.assertFalse(task['result']['restarted']); self.assertIsNone(self.core.poll())
        self.assertFalse((self.home / 'control-calls').exists())

    def test_geo_policy_failure_rolls_back_config(self):
        before = (self.home / 'etc/config.yaml').read_bytes(); self.http_failure = True
        task = self.run_job('geodata_apply_policy', {'policy':'direct'})
        self.assertEqual(task['status'], 'failed')
        self.assertEqual((self.home / 'etc/config.yaml').read_bytes(), before)
        self.assertFalse((self.home / 'control-calls').exists())

    def test_identical_geo_files_do_not_restart(self):
        shutil.copyfile(self.home / 'geoip.dat', self.home / 'etc/GeoIP.dat')
        shutil.copyfile(self.home / 'geosite.dat', self.home / 'etc/GeoSite.dat')
        task = self.run_job('geodata_update')
        self.assertEqual(task['status'], 'succeeded', task)
        self.assertTrue(task['result']['unchanged']); self.assertFalse(task['result']['restarted'])
        self.assertFalse((self.home / 'control-calls').exists())
        self.assertEqual(len((self.home / 'curl-calls').read_text().splitlines()), 1, 'matching official digests skip both large downloads')

    def test_changed_geo_files_only_restart_after_validation(self):
        task = self.run_job('geodata_update')
        self.assertEqual(task['status'], 'succeeded', task)
        self.assertTrue(task['result']['restarted'])
        self.assertEqual((self.home / 'control-calls').read_text().splitlines(), ['status','restart'])

    def test_geo_validation_failure_restores_both_databases(self):
        (self.home / 'reject-config').touch()
        task = self.run_job('geodata_update')
        self.assertEqual(task['status'], 'failed')
        self.assertEqual((self.home / 'etc/GeoIP.dat').read_bytes(), b'old')
        self.assertEqual((self.home / 'etc/GeoSite.dat').read_bytes(), b'old')

    def test_unknown_actions_and_invalid_ids_are_rejected(self):
        self.assertFalse(self.cli('start', 'shell_exec')['ok'])
        self.assertFalse(self.cli('status', payload={'id':'../../etc/passwd'})['ok'])

    def test_first_import_uses_candidate_validation_and_hot_config(self):
        task = self.run_job('subscription_import', {'url':'https://example.invalid/new-subscription'})
        self.assertEqual(task['status'], 'succeeded', task)
        self.assertEqual(self.calls, ['/configs?force=true'])
        self.assertEqual((self.home / 'etc/subscription.url').read_text().strip(), 'https://example.invalid/new-subscription')
        self.assertFalse((self.home / 'control-calls').exists())

    def test_failed_import_keeps_old_url_and_config(self):
        before = (self.home / 'etc/config.yaml').read_bytes()
        self.http_failure = True
        task = self.run_job('subscription_import', {'url':'https://example.invalid/new-subscription'})
        self.assertEqual(task['status'], 'failed')
        self.assertEqual((self.home / 'etc/config.yaml').read_bytes(), before)
        self.assertIn('fixture-secret', (self.home / 'etc/subscription.url').read_text())

    def test_status_of_abandoned_job_cleans_request_material(self):
        tasks = self.home / 'var/update-tasks'; tasks.mkdir()
        ident = 'f' * 32
        (tasks / (ident + '.json')).write_text(json.dumps({'id':ident,'status':'running','createdAt':time.time()}))
        (tasks / (ident + '.request')).write_text('private fixture request')
        packet = self.cli('status', payload={'id':ident})
        self.assertEqual(packet['task']['status'], 'failed')
        self.assertFalse((tasks / (ident + '.request')).exists())


if __name__ == '__main__':
    unittest.main()
