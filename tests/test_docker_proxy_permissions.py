"""Real CGI fixture: exact shared module command, never a real sudo/service call."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]

@unittest.skipUnless(shutil.which('jq') and Path('/bin/sh').exists(),'POSIX shell and jq required')
class ProxyPermissionTests(unittest.TestCase):
    def call(self,method='GET',body='',port=7890,action='docker_proxy_status'):
        with tempfile.TemporaryDirectory() as scratch:
            root=Path(scratch);mock=root/'bin';mock.mkdir()
            helper=root/'helper';helper.write_text('#!/bin/sh\nexit 99\n');helper.chmod(0o755)
            sudo=mock/'sudo'
            sudo.write_text('''#!/usr/bin/python3
import json,os,pathlib,sys
root=pathlib.Path(os.environ['TEST_PROXY_ROOT'])
assert sys.argv[1:]==['-n',str(root/'helper'),'mihomo']
(root/'request.json').write_text(sys.stdin.read())
print(json.dumps({'ok':True,'state':'pending_apply'}))
''');sudo.chmod(0o755)
            (root/'ports.env').write_text('MIXED_PORT='+str(port)+'\n')
            cgi=(ROOT/'payload/ui/mihomo.cgi').read_text().replace('DOCKER_PROXY_HELPER="/data/.minas-privileged/minas-helper"','DOCKER_PROXY_HELPER='+shlex.quote(str(helper)))
            cgi=cgi.replace('PORTS_FILE="$ETC_DIR/ports.env"','PORTS_FILE='+shlex.quote(str(root/'ports.env')))
            entry=root/'mihomo.cgi';entry.write_text(cgi)
            env=dict(os.environ,TEST_PROXY_ROOT=str(root),PATH=str(mock)+':'+os.environ['PATH'],QUERY_STRING='action='+action,REQUEST_METHOD=method,CONTENT_LENGTH=str(len(body.encode())))
            result=subprocess.run(['/bin/sh',str(entry)],env=env,input=body,capture_output=True,text=True,timeout=10)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertTrue(json.loads(result.stdout.split('\n\n',1)[1])['ok'],result.stdout)
            return json.loads((root/'request.json').read_text())
    def test_status_and_force(self):
        self.assertEqual(self.call()['force'],False)
        self.assertEqual(self.call('POST','{"force":true}')['force'],True)
    def test_no_port_override_from_cgi(self):
        for port in (7890,17890):
            self.assertNotIn('port',self.call(port=port))
    def test_mutating_action_uses_same_narrow_entry(self):
        for action in ('docker_proxy_enable','docker_proxy_disable'):
            self.assertEqual(self.call('POST','{}',action=action)['action'],action)
    def test_installer_uses_common_registration(self):
        source=(ROOT/'manage.sh').read_text()
        self.assertIn('common/component_admin.py" install',source)
        self.assertNotIn('docker_sudoers_tmp=',source)

if __name__=='__main__':unittest.main()
