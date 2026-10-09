import importlib.util
import subprocess
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

path = Path(__file__).resolve().parents[1] / 'payload/system/docker_proxy_status.py'
spec = importlib.util.spec_from_file_location('proxy_status', path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
URL = 'http://127.0.0.1:7890'
CONFIG = '\n'.join('Environment="'+key+'='+URL+'"' for key in ('HTTP_PROXY', 'HTTPS_PROXY'))
SERVICE = dict(LoadState='loaded', ActiveState='active', MainPID='123')


class StatusTests(unittest.TestCase):
    def status(self, config=CONFIG, runtime=(URL, URL, 'localhost,127.0.0.1,10.0.0.0/8'),
               active=True, listening=True, probe=(True, 'ok'), changed=False, unavailable=False):
        source = Mock()
        if config is None: source.read_text.side_effect = FileNotFoundError()
        else: source.read_text.return_value = config
        service = dict(SERVICE, ActiveState='active' if active else 'inactive',
                       LoadState='not-found' if unavailable else 'loaded')
        with patch.object(module, 'DROPIN', source), patch.object(module, 'service', side_effect=[service, dict(service, MainPID='456' if changed else '123')]), \
             patch.object(module, 'runtime_proxy', side_effect=runtime if isinstance(runtime, Exception) else None, return_value=runtime), \
             patch.object(module, 'listening', return_value=listening), patch.object(module, 'probe', return_value=probe) as check:
            result = module.status(7890)
        self.assertEqual(result['enabled'], result['configured'])
        return result, check.call_count

    def test_effective(self):
        result, count = self.status()
        self.assertEqual(result['state'], 'effective')
        self.assertTrue(result['effective']); self.assertEqual(count, 1)

    def test_saved_but_not_loaded(self):
        result, _ = self.status(runtime=('', '', ''))
        self.assertEqual(result['state'], 'pending_apply')
        self.assertTrue(result['configured']); self.assertFalse(result['effective'])

    def test_wrong_runtime_port(self):
        self.assertEqual(self.status(runtime=('http://127.0.0.1:7891',)*2+('',))[0]['state'], 'pending_apply')

    def test_partial_runtime_proxy(self):
        result, _ = self.status(runtime=('', URL, ''))
        self.assertTrue(result['runtimeUsesProxy']); self.assertFalse(result['effective'])
        self.assertEqual(result['state'], 'pending_apply')
        self.assertEqual(self.status(config=None, runtime=('', URL, ''))[0]['state'], 'pending_disable')

    def test_commented_configuration(self):
        result, _ = self.status(config='\n'.join('# '+line for line in CONFIG.splitlines()))
        self.assertFalse(result['configured'])

    def test_no_listener(self):
        result, count = self.status(listening=False)
        self.assertEqual(result['state'], 'unreachable'); self.assertEqual(count, 0)
        self.assertTrue(result['effective']); self.assertFalse(result['proxyReachable'])

    def test_upstream_failure(self):
        self.assertEqual(self.status(probe=(False,'upstream_failed'))[0]['state'], 'upstream_failed')

    def test_unknown(self):
        result, _ = self.status(runtime=subprocess.TimeoutExpired('docker', 2))
        self.assertEqual(result['state'], 'unknown'); self.assertFalse(result['runtimeKnown'])

    def test_restart_during_inspection(self):
        self.assertEqual(self.status(changed=True)[0]['state'], 'unknown')

    def test_stopped(self):
        self.assertEqual(self.status(active=False)[0]['state'], 'docker_stopped')

    def test_unavailable(self):
        self.assertEqual(self.status(active=False, unavailable=True)[0]['state'], 'unavailable')

    def test_disabled(self):
        result, count = self.status(config=None, runtime=('', '', ''))
        self.assertEqual(result['state'], 'disabled'); self.assertEqual(count, 0)

    def test_removal_not_applied(self):
        self.assertEqual(self.status(config=None)[0]['state'], 'pending_disable')

    def test_other_user(self):
        result, _ = self.status(config=CONFIG.replace('7890', '7891'), runtime=('', '', ''))
        self.assertTrue(result['configuredElsewhere']); self.assertEqual(result['state'], 'disabled')

    def test_bypass(self):
        for entry in ('*', '.docker.io', 'registry-1.docker.io', '*.docker.io', 'auth.docker.io:443'):
            self.assertEqual(self.status(runtime=(URL, URL, entry))[0]['state'], 'bypassed')
        self.assertFalse(module.bypasses_registry('evil-docker.io,localhost,10.0.0.0/8'))

    def test_unsupported_probe(self):
        self.assertEqual(self.status(probe=(None,'probe_unavailable'))[0]['state'], 'probe_unknown')

    def test_no_credentials_in_output(self):
        result, _ = self.status(runtime=('http://private:secret@host:80',)*2+('',))
        self.assertNotIn('secret', str(result)); self.assertFalse(result['effective'])

    def test_probe_success_requires_registry_header(self):
        for code in ('200', '401'):
            with patch.object(module, 'run', return_value='Docker-Distribution-Api-Version: registry/2.0\nSTATUS:'+code) as run:
                self.assertEqual(module.probe(URL), (True, 'ok'))
                args = run.call_args[0][0]
                self.assertEqual(args[args.index('--proxy')+1], URL)
                self.assertEqual(args[args.index('--noproxy')+1], '')
        with patch.object(module, 'run', return_value='STATUS:401'):
            self.assertEqual(module.probe(URL), (False,'http_error'))

    def test_probe_failures(self):
        with patch.object(module, 'run', side_effect=FileNotFoundError()):
            self.assertEqual(module.probe(URL), (None, 'probe_unavailable'))
        with patch.object(module, 'run', side_effect=subprocess.TimeoutExpired('curl', 4)):
            self.assertEqual(module.probe(URL), (False, 'upstream_failed'))

    def test_runtime_format(self):
        with patch.object(module, 'run', return_value='"'+URL+'"\n"'+URL+'"\n"localhost"\n'):
            self.assertEqual(module.runtime_proxy(), [URL, URL, 'localhost'])
        with patch.object(module, 'run', return_value='malformed'):
            with self.assertRaises(ValueError): module.runtime_proxy()


if __name__ == '__main__': unittest.main()
