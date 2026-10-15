"""Targeted 1.7.25 -> 1.7.26 deployment; never invokes user update jobs/restarts."""
from contextlib import ExitStack
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import time

CHANGED = ('ui/app.js', 'ui/index.html', 'ui/style.css', 'ui/mihomo.cgi',
           'files/update_tasks.py', 'files/update-common.sh', 'files/subscription.sh',
           'files/config-tools.sh', 'files/geodata.sh', 'files/rule-provider.sh', 'files/mihomo.sh')


def sha(data):
    return hashlib.sha256(data).hexdigest()


def digest(src):
    return sha(''.join(sha(p.read_bytes()) + '\n' for p in sorted(src.rglob('*'))
                       if p.is_file() and not p.is_symlink()).encode())


def atomic(target, data, metadata, mode=0o644):
    fd, name = tempfile.mkstemp(prefix='.update-tasks-', dir=target.parent)
    try:
        with os.fdopen(fd, 'wb') as out:
            out.write(data); out.flush(); os.fsync(out.fileno())
            os.fchmod(out.fileno(), stat.S_IMODE(metadata.st_mode) if metadata else mode)
            os.fchown(out.fileno(), metadata.st_uid, metadata.st_gid)
        os.replace(name, target)
    finally:
        if os.path.exists(name): os.unlink(name)


def deploy(user, payload):
    assert os.geteuid() == 0 and re.fullmatch(r'u[0-9]+', user)
    home = Path('/home') / user / 'plugin/mihomo'
    src = (home / 'src').resolve(strict=True)
    assert src.name == 'mihomo' and src.parent.name == 'pluginsrc' and src.parents[2].name == user
    assert str(src).startswith('/nas/pool') and os.path.ismount(src.parents[3])
    registry = Path('/data/plugin') / (user + '.list')
    info_path = home / 'INFO'
    def protected():
        result = {str(p.relative_to(home)):sha(p.read_bytes()) for p in (home / 'etc').rglob('*')
                  if p.is_file() and p.name != 'cache.db'}
        for p in (home / 'var/mihomo.pid', home / 'var/core/mihomo'):
            if p.is_file():result[str(p.relative_to(home))] = sha(p.read_bytes())
        result['dockerPid'] = subprocess.check_output(['systemctl','show','docker.service','-p','MainPID','--value']).strip().decode()
        return result
    runtime_lock = home / 'var/update-operation.lock'
    runtime_fd = os.open(runtime_lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        assert stat.S_ISREG(os.fstat(runtime_fd).st_mode)
        owner = (home / 'var').stat()
        os.fchown(runtime_fd, owner.st_uid, owner.st_gid)
        os.fchmod(runtime_fd, 0o600)
    finally:
        os.close(runtime_fd)
    with ExitStack() as stack:
        for path in (Path('/data/plugin/.local-plugin-installer.lock'), Path('/data/plugin/.' + user + '.plugins.lock'), home / 'var/update-operation.lock'):
            handle = stack.enter_context(path.open('a'))
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        for process in Path('/proc').glob('[0-9]*/cmdline'):
            try: args = process.read_bytes()
            except OSError: continue
            assert not any((str(src / 'files' / name)).encode() in args for name in (
                'subscription.sh', 'geodata.sh', 'rule-provider.sh', 'core-update.sh', 'node.sh', 'network-access.sh')), 'An existing configuration operation is running'
        info = json.loads(info_path.read_bytes())
        assert info['version'] == '1.7.25', 'Unexpected version; re-audit before deploying'
        assert info['abstract'] == digest(src), 'Existing source integrity check failed'
        original_registry = json.loads(registry.read_bytes())['mihomo']
        before = protected()
        originals = {target:(target.read_bytes(), target.stat()) if target.exists() else (None, None)
                     for target in [src / rel for rel in CHANGED] + [info_path]}
        owner = src.stat()
        def register(entry):
            current = json.loads(registry.read_bytes()); current['mihomo'] = entry
            atomic(registry, (json.dumps(current, ensure_ascii=False, indent=2) + '\n').encode(), registry.stat())
        try:
            for relative in CHANGED:
                target = src / relative
                assert not target.is_symlink(), 'Unexpected source symlink'
                metadata = originals[target][1]
                if metadata is None:
                    # New helpers inherit source ownership, not its directory mode.
                    fd, name = tempfile.mkstemp(prefix='.update-tasks-', dir=target.parent)
                    try:
                        with os.fdopen(fd, 'wb') as out:
                            out.write((payload / relative).read_bytes().replace(b'\r\n', b'\n'))
                            out.flush(); os.fsync(out.fileno()); os.fchmod(out.fileno(), 0o644)
                            os.fchown(out.fileno(), owner.st_uid, owner.st_gid)
                        os.replace(name, target)
                    finally:
                        if os.path.exists(name):os.unlink(name)
                else:
                    atomic(target, (payload / relative).read_bytes().replace(b'\r\n', b'\n'), metadata)
            updated = dict(info, version='1.7.26', timestamp=int(time.time()), abstract=digest(src),
                           changelog='后台更新进度与并发保护；节点/策略热加载；Geo 摘要一致跳过下载和重启')
            updated['size'] = sum(p.stat().st_blocks * 512 for p in src.rglob('*') if p.is_file() and not p.is_symlink())
            atomic(info_path, (json.dumps(updated, ensure_ascii=False, indent=2) + '\n').encode(), originals[info_path][1])
            entry = dict(original_registry, info={k:v for k,v in updated.items() if k != 'abstract'}, changetime=updated['timestamp'])
            register(entry)
            env = dict(os.environ, PLUG_USER=user, PLUG_NAME='mihomo', PLUG_HOME_DIR=str(home), PLUG_SRC_DIR=str(src),
                       PLUG_TMP_DIR=str((home / 'tmp').resolve()), PLUG_STATUS='unverified')
            subprocess.run(['/usr/bin/plugin.sh','verify'], env=env, capture_output=True, check=True, timeout=60)
            assert info_path.exists() and json.loads(info_path.read_bytes())['abstract'] == digest(src)
            assert protected() == before, 'Configuration, core or service PID changed during deployment'
            current = json.loads(registry.read_bytes())['mihomo']
            for key in ('enabled', 'enable', 'status', 'state'):
                assert current.get(key) == original_registry.get(key), 'Plugin enable state changed'
            print(json.dumps({'version':'1.7.26','sourceVerified':True,'configurationAndCorePreserved':True,
                              'dockerAndMihomoPidsUnchanged':True,'enableStatePreserved':True}))
        except BaseException:
            for path, (data, metadata) in originals.items():
                if data is None:path.unlink(missing_ok=True)
                else:atomic(path, data, metadata)
            register(original_registry)
            raise


if __name__ == '__main__':
    deploy(sys.argv[1], Path(sys.argv[2]))
