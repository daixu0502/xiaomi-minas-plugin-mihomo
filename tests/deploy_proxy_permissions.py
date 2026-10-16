"""Targeted 1.7.28 -> 1.7.29 update; no Docker or Mihomo service operations.

Run as root from an extracted, verified release. Rollback copies stay in memory.
"""
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

OLD_HASHES = {
    'ui/mihomo.cgi': '254366f97da28df512e4bff083bb445a5cc2dc7a286bd258ae89f8ef77bc836a',
    'ui/index.html': '2e4515aef80236fbd1a1711693f2073ec148880d074c47ba498e6175018b6b13',
}
HELPER = '/data/plugin/.mihomo-system/mihomo-docker-proxy'


def policy(user, port, fresh=True):
    commands = [f'{HELPER} status {port}']
    if fresh:
        commands.append(f'{HELPER} status {port} fresh')
    commands.extend(f'{HELPER} {action} {port}' for action in ('enable', 'disable'))
    return user + ' ALL=(root) NOPASSWD: ' + ', '.join(commands) + '\n'


def sha(data):
    return hashlib.sha256(data).hexdigest()


def digest(src):
    files = sorted((p for p in src.rglob('*') if p.is_file() and not p.is_symlink()), key=lambda p: os.fsencode(str(p)))
    return sha(''.join(sha(p.read_bytes()) + '\n' for p in files).encode())


def atomic(path, data, metadata):
    assert not path.is_symlink(), 'Unexpected target link'
    fd, name = tempfile.mkstemp(prefix='.proxy-permissions-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
            os.fchmod(output.fileno(), stat.S_IMODE(metadata.st_mode))
            os.fchown(output.fileno(), metadata.st_uid, metadata.st_gid)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def deploy(user, payload):
    assert os.geteuid() == 0 and re.fullmatch(r'u[0-9]+', user)
    home = Path('/home') / user / 'plugin/mihomo'
    src = (home / 'src').resolve(strict=True)
    assert src == Path('/nas/pool0') / user / 'plugin/pluginsrc/mihomo' and os.path.ismount('/nas/pool0')
    info_path = home / 'INFO'
    registry_path = Path('/data/plugin') / (user + '.list')
    sudoers = Path('/etc/sudoers.d') / ('mihomo-docker-proxy-' + user)

    def protected():
        result = {}
        for p in (home / 'etc').rglob('*'):
            if p.is_file() and p.name != 'cache.db':
                result[str(p)] = sha(p.read_bytes())
        for p in (home / 'var/core').glob('*'):
            if p.is_file():
                result[str(p)] = sha(p.read_bytes())
        for p in (home / 'var/mihomo.pid', home / 'var/enabled',
                  Path('/etc/systemd/system/docker.service.d/90-mihomo-proxy.conf')):
            result[str(p)] = sha(p.read_bytes()) if p.exists() else None
        result['docker'] = subprocess.check_output(['systemctl', 'show', 'docker.service', '-p', 'MainPID', '-p', 'ActiveState'])
        return result

    with ExitStack() as locks:
        for path in (Path('/data/plugin/.local-plugin-installer.lock'), Path('/data/plugin/.' + user + '.plugins.lock'),
                     home / 'var/update-operation.lock'):
            fd = os.open(path, os.O_RDWR | os.O_NOFOLLOW)
            handle = locks.enter_context(os.fdopen(fd, 'a'))
            assert stat.S_ISREG(os.fstat(fd).st_mode)
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        info = json.loads(info_path.read_bytes())
        assert info['version'] == '1.7.28' and info['abstract'] == digest(src), 'Old version/integrity mismatch'
        for relative, expected in OLD_HASHES.items():
            assert sha((src / relative).read_bytes()) == expected, 'Source differs: ' + relative
        port = re.search(r'^MIXED_PORT=([0-9]+)$', (home / 'etc/ports.env').read_text(), re.M)[1]
        assert 1024 <= int(port) <= 65535
        assert not sudoers.is_symlink() and sudoers.stat().st_uid == 0 and stat.S_IMODE(sudoers.stat().st_mode) == 0o440
        assert sudoers.read_text() == policy(user, port, fresh=False), 'Existing policy differs'
        candidate = policy(user, port).encode()
        fd, temporary = tempfile.mkstemp(prefix='.mihomo-policy-', dir=sudoers.parent)
        try:
            with os.fdopen(fd, 'wb') as output:
                output.write(candidate)
                os.fchmod(output.fileno(), 0o440)
            subprocess.run(['visudo', '-cf', temporary], check=True, capture_output=True, timeout=10)
        finally:
            os.unlink(temporary)
        changes = {src / relative: (payload / relative).read_bytes().replace(b'\r\n', b'\n') for relative in OLD_HASHES}
        changes[sudoers] = candidate
        originals = {p: (p.read_bytes(), p.stat()) for p in list(changes) + [info_path, registry_path]}
        registry = json.loads(originals[registry_path][0])
        before = protected()
        try:
            for path, data in changes.items():
                atomic(path, data, originals[path][1])
            updated = dict(info, version='1.7.29', timestamp=int(time.time()), abstract=digest(src),
                           changelog='修复 Docker 代理自动查询及手动刷新权限参数，不重启服务')
            updated['size'] = sum(p.stat().st_blocks * 512 for p in src.rglob('*') if p.is_file() and not p.is_symlink())
            atomic(info_path, (json.dumps(updated, ensure_ascii=False, indent=2) + '\n').encode(), originals[info_path][1])
            registry['mihomo']['info'] = {k: v for k, v in updated.items() if k != 'abstract'}
            registry['mihomo']['changetime'] = updated['timestamp']
            atomic(registry_path, (json.dumps(registry, ensure_ascii=False, indent=2) + '\n').encode(), originals[registry_path][1])
            env = dict(os.environ, PLUG_USER=user, PLUG_NAME='mihomo', PLUG_HOME_DIR=str(home), PLUG_SRC_DIR=str(src),
                       PLUG_TMP_DIR=str((home / 'tmp').resolve()), PLUG_STATUS='unverified', PYTHONDONTWRITEBYTECODE='1')
            subprocess.run(['/usr/bin/plugin.sh', 'verify'], env=env, check=True, capture_output=True, timeout=60)
            assert json.loads(info_path.read_bytes())['abstract'] == digest(src)
            results = []
            for method, body in [('GET', b''), ('POST', b'{"force":true}')]:
                query_env = ['QUERY_STRING=action=docker_proxy_status', 'REQUEST_METHOD=' + method,
                             'CONTENT_LENGTH=' + str(len(body))]
                response = subprocess.run(['runuser', '-u', user, '--', 'env'] + query_env + [str(src / 'ui/mihomo.cgi')],
                                          input=body, check=True, capture_output=True, timeout=25)
                data = json.loads(response.stdout.replace(b'\r\n', b'\n').split(b'\n\n', 1)[1])
                assert data['ok'] is True and data['runtimeKnown'] is True, 'Status query failed'
                results.append({'method': method, 'state': data['state'], 'configured': data['configured'],
                                'effective': data['effective'], 'proxyReachable': data['proxyReachable']})
            assert protected() == before, 'Configuration, core or service state changed'
            current = json.loads(registry_path.read_bytes())['mihomo']
            original = json.loads(originals[registry_path][0])['mihomo']
            for key in ('enabled', 'enable', 'status', 'state'):
                assert current.get(key) == original.get(key), 'Enable state changed'
            print(json.dumps({'version': '1.7.29', 'sourceVerified': True, 'noServiceRestarts': True,
                              'configurationAndCorePreserved': True, 'persistentBackups': False,
                              'queries': results}, ensure_ascii=False))
        except BaseException:
            for path, (data, metadata) in reversed(list(originals.items())):
                atomic(path, data, metadata)
            raise


if __name__ == '__main__':
    deploy(sys.argv[1], Path(sys.argv[2]))
