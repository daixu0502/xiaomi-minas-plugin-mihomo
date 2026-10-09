"""Targeted 1.7.20 -> 1.7.21 NAS update. No service restarts/configuration changes."""
import fcntl
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from contextlib import ExitStack
from pathlib import Path

BASELINES = {
    'ui/app.js': '0d91b8bcbdde60a318da57bd34b2badea8b995a35a134046f401859c8546e182',
    'ui/index.html': 'd6ee8d1c35fde1641289d971d4f90231074b44a1958956e5a2e618729365fe35',
    'ui/style.css': '8723fbd90a171460e3378e01b2ee6a7a005385281f4bb9c4ff47da66fa12d8b9',
    'system/mihomo-docker-proxy': 'e9d21c917ebd3e2affde5a6d58dc9762ca0aca26b290054d082d14c38a04a3cd',
}
DEFAULT_NO_PROXY = b'NO_PROXY_VALUE=localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16'


def digest(data): return hashlib.sha256(data).hexdigest()
def normalized(path): return path.read_bytes().replace(b'\r\n', b'\n')


def main(user, payload):
    assert os.geteuid() == 0 and re.fullmatch(r'u[0-9]+', user)
    assert os.path.ismount('/nas/pool0')
    home = Path('/home') / user / 'plugin/mihomo'
    src = (home / 'src').resolve(strict=True)
    assert src == Path('/nas/pool0') / user / 'plugin/pluginsrc/mihomo'
    helper_dir = Path('/data/plugin/.mihomo-system')
    assert helper_dir.resolve() == helper_dir and helper_dir.stat().st_uid == 0
    registry = Path('/data/plugin') / (user + '.list')
    info_path = home / 'INFO'
    info = json.loads(info_path.read_bytes())
    assert info['version'] == '1.7.20'
    proxy_config = Path('/etc/systemd/system/docker.service.d/90-mihomo-proxy.conf')
    proxy_before = proxy_config.read_bytes() if proxy_config.exists() else None
    def pids():
        return (subprocess.check_output(['systemctl','show','docker.service','-p','MainPID','--value']), (home/'var/mihomo.pid').read_bytes())
    before_pids = pids()
    changes, originals = {}, {}
    def atomic(target, data, metadata=None, mode=0o644):
        fd, tmp = tempfile.mkstemp(prefix='.proxy-state-', dir=target.parent)
        try:
            with os.fdopen(fd, 'wb') as out:
                out.write(data); out.flush(); os.fsync(out.fileno())
                os.fchmod(out.fileno(), metadata.st_mode & 0o777 if metadata else mode)
                os.fchown(out.fileno(), metadata.st_uid if metadata else 0, metadata.st_gid if metadata else 0)
            os.replace(tmp, target)
        finally:
            if os.path.exists(tmp): os.unlink(tmp)
    with ExitStack() as stack:
        for name in ('/data/plugin/.local-plugin-installer.lock', '/data/plugin/.'+user+'.plugins.lock'):
            lock=stack.enter_context(open(name,'a')); fcntl.flock(lock,fcntl.LOCK_EX)
        for relative, expected in BASELINES.items():
            target = helper_dir / Path(relative).name if relative.startswith('system/') else src / relative
            assert not target.is_symlink()
            old, new = normalized(target), normalized(payload/relative)
            if relative.startswith('system/'):
                setting = re.search(rb'^NO_PROXY_VALUE=[a-zA-Z0-9,:./*_\-]+$', old, re.M)
                assert setting, 'Unexpected helper NO_PROXY format'
                old = old.replace(setting[0], DEFAULT_NO_PROXY)
                new = new.replace(DEFAULT_NO_PROXY, setting[0])
            assert digest(old) == expected, 'Unexpected existing content: '+relative
            changes[target] = new
        status_file = helper_dir / 'docker_proxy_status.py'
        assert not status_file.exists(), 'Status module already exists; inspect before replacing'
        changes[status_file] = normalized(payload/'system/docker_proxy_status.py')
        for target in list(changes)+[info_path]:
            originals[target] = (target.read_bytes(),target.stat()) if target.exists() else (None,None)
        original_entry = json.loads(registry.read_bytes())['mihomo']
        def register(entry):
            current = json.loads(registry.read_bytes()); current['mihomo'] = entry
            atomic(registry, (json.dumps(current,ensure_ascii=False,indent=2)+'\n').encode(), registry.stat())
        try:
            # Install the root-owned status module before switching the helper.
            atomic(status_file, changes[status_file])
            for target, data in changes.items():
                if target != status_file: atomic(target,data,originals[target][1])
            updated=dict(info,version='1.7.21',timestamp=int(time.time()),changelog='Docker 代理区分配置、进程生效和连通性，支持确认后重新应用')
            files=sorted(p for p in src.rglob('*') if p.is_file() and not p.is_symlink())
            updated['abstract']=digest(''.join(digest(p.read_bytes())+'\n' for p in files).encode())
            updated['size']=sum(p.stat().st_blocks*512 for p in files)
            atomic(info_path,(json.dumps(updated,ensure_ascii=False,indent=2)+'\n').encode(),originals[info_path][1])
            entry=dict(original_entry,info={k:v for k,v in updated.items() if k!='abstract'},changetime=updated['timestamp'])
            register(entry)
            env=dict(os.environ,PLUG_USER=user,PLUG_NAME='mihomo',PLUG_HOME_DIR=str(home),PLUG_SRC_DIR=str(src),PLUG_TMP_DIR=str((home/'tmp').resolve()),PLUG_STATUS='unverified')
            subprocess.run(['/usr/bin/plugin.sh','verify'],env=env,check=True,capture_output=True,timeout=30)
            assert before_pids==pids(), 'A service restarted during update'
            assert proxy_before==(proxy_config.read_bytes() if proxy_config.exists() else None), 'Proxy configuration changed'
            print('PASS deployed 1.7.21; source verified; Docker/Mihomo PIDs and proxy configuration unchanged; no persistent backups')
        except BaseException:
            for target,(data,metadata) in originals.items():
                if data is None: target.unlink(missing_ok=True)
                else: atomic(target,data,metadata)
            register(original_entry)
            raise


if __name__ == '__main__': main(sys.argv[1], Path(sys.argv[2]))
