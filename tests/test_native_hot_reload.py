"""Opt-in native-core integration, isolated loopback controller and fixture nodes."""
import json
import os
from pathlib import Path
import socket
import subprocess
import time
import unittest
import urllib.request

import test_update_tasks as fixtures


@unittest.skipUnless(os.environ.get('MIHOMO_TEST_BINARY'), 'set MIHOMO_TEST_BINARY for isolated native-core integration')
class NativeHotReloadTests(unittest.TestCase):
    def test_real_provider_and_config_reload_keep_pid(self):
        fixture = fixtures.UpdateTasksTests()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        fixture.stop_core()
        core = fixture.home / 'src/files/mihomo'
        core.unlink(); core.symlink_to(Path(os.environ['MIHOMO_TEST_BINARY']).resolve(strict=True))
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0)); port = probe.getsockname()[1]
        (fixture.home / 'etc/ports.env').write_text('MIXED_PORT=0\nCONTROLLER_PORT=%d\n' % port)
        (fixture.home / 'etc/config.yaml').write_text('''mixed-port: 0
allow-lan: false
bind-address: 127.0.0.1
mode: rule
log-level: silent
ipv6: false
proxy-providers:
  APP-SUBSCRIPTION:
    type: file
    path: ./providers/app-subscription.yaml
    health-check:
      enable: false
proxy-groups:
  - name: PROXY
    type: select
    proxies: [DIRECT]
    use: [APP-SUBSCRIPTION]
rules:
  - MATCH,DIRECT
''')
        with (fixture.home / 'var/native-core.log').open('ab') as output:
            fixture.core = subprocess.Popen([str(core), '-d', str(fixture.home / 'etc'), '-f', str(fixture.home / 'etc/config.yaml'),
                                             '-ext-ctl', '127.0.0.1:%d' % port, '-secret', 'test-only'],
                                            stdout=output, stderr=output, env=fixture.env)
        def get(path):
            request = urllib.request.Request('http://127.0.0.1:%d%s' % (port, path), headers={'Authorization':'Bearer test-only'})
            with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request, timeout=2) as response:
                return json.load(response)
        for _ in range(80):
            try:
                get('/version'); break
            except OSError:
                self.assertIsNone(fixture.core.poll(), 'isolated core exited')
                time.sleep(.1)
        else:
            self.fail('isolated core did not become ready')
        (fixture.home / 'var/mihomo.pid').write_text(str(fixture.core.pid))
        pid = fixture.core.pid
        task = fixture.run_job()
        self.assertEqual(task['status'], 'succeeded', task)
        self.assertEqual(get('/providers/proxies/APP-SUBSCRIPTION')['proxies'][0]['name'], 'new')
        self.assertIsNone(fixture.core.poll()); self.assertEqual(fixture.core.pid, pid)
        task = fixture.run_job('geodata_apply_policy', {'policy':'direct'})
        self.assertEqual(task['status'], 'succeeded', task)
        self.assertIsNone(fixture.core.poll()); self.assertEqual(fixture.core.pid, pid)
        self.assertFalse((fixture.home / 'control-calls').exists())
        fixture.stop_core()
        (fixture.home / 'var/mihomo.pid').unlink()
        task = fixture.run_job('subscription_import', {'url':'https://example.invalid/first-import'})
        self.assertEqual(task['status'], 'succeeded', task)
        self.assertTrue(task['result']['imported'])
        self.assertFalse((fixture.home / 'control-calls').exists(), 'stopped core remains stopped after first import')


if __name__ == '__main__':
    unittest.main()
