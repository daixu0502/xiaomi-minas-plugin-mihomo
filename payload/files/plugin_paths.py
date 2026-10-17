"""Disposable user runtime in firmware plugintmp; never credentials or code."""
import os
from pathlib import Path
import re
import stat
import tempfile
import shutil

DISPOSABLE = {
    'mihomo': {'mihomo.pid', 'mihomo.log', 'mihomo.log.1', 'update-tasks',
        'update-operation.lock','geodata-update.lock','core-update.lock','network-access.lock',
        'manual-node.lock','rule-provider.lock'},
    'quickshare': {'server.pid', 'server.log', 'server.log.1'},
    'downloadcenter': {'service.pid', 'service.log', 'service.log.1', 'aria2.log', 'aria2.conf',
        'qbittorrent.log', 'qbittorrent.log.1', 'qb-session.json', 'qb-applied.json',
        'tracker-status.json', 'tracker-apply.json', 'job.json', 'core-update.json',
        'core-update.log', 'qb-update.json', 'qb-update.log','control.log','dht.dat','dht6.dat',
        'api.lock','lifecycle.lock','core-update.lock','tracker-update.lock','supervisor.lock'},
}


def runtime_directory(home):
    home = Path(home)
    target = home / 'tmp'
    if str(home).startswith('/home/'):
        match = re.fullmatch(r'/home/(u[0-9]+)/plugin/([a-z]+)', str(home))
        if not match or not target.is_symlink():
            raise RuntimeError('官方插件缓存链接不可用')
        resolved = target.resolve(strict=True)
        expected = re.fullmatch(r'/nas/(pool[^/]+)/' + match[1] + r'/plugin/plugintmp/' + match[2], str(resolved))
        if not expected or not os.path.ismount('/nas/' + expected[1]):
            raise RuntimeError('存储池未挂载，禁止创建插件缓存')
    else:
        # Isolated local tests, never a fallback path on a real NAS.
        target.mkdir(mode=0o700, exist_ok=True)
    info = target.stat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid():
        raise PermissionError('插件缓存目录所属用户不正确')
    runtime = target / 'runtime'
    if runtime.is_symlink():
        raise PermissionError('运行目录不能是符号链接')
    runtime.mkdir(mode=0o700, exist_ok=True)
    info = runtime.stat()
    if info.st_uid != os.geteuid() or info.st_mode & 0o077:
        raise PermissionError('运行目录权限不正确')
    return runtime


def migrate(home):
    """Installer-only; service and update workers must already be stopped."""
    home = Path(home)
    runtime = runtime_directory(home)
    source = home / 'var'
    names = DISPOSABLE.get(home.name, set())
    for path in source.iterdir():
        if path.name not in names and not (home.name == 'downloadcenter' and path.name.startswith('runtime-') and path.suffix == '.json'):
            continue
        destination = runtime / path.name
        if path.is_symlink() or destination.exists():
            raise RuntimeError('旧缓存有链接或新旧缓存同时存在，未覆盖：' + path.name)
        # Paths can live on different filesystems. Copy completely before unlink.
        shutil.move(str(path), str(destination))


def publish(source, target):
    """Keep final replacement atomic even when staging is on another disk."""
    source, target = Path(source), Path(target)
    if source.is_symlink() or target.is_symlink():
        raise PermissionError('拒绝替换符号链接')
    fd, temporary = tempfile.mkstemp(prefix='.' + target.name + '.', dir=target.parent)
    try:
        with os.fdopen(fd, 'wb') as output, source.open('rb') as stream:
            shutil.copyfileobj(stream, output)
            os.fchmod(output.fileno(), stat.S_IMODE(source.stat().st_mode))
            output.flush(); os.fsync(output.fileno())
        os.replace(temporary, target)
        source.unlink()
    finally:
        if os.path.exists(temporary):os.unlink(temporary)


if __name__ == '__main__':
    import sys
    if sys.argv[1] == '--publish':publish(sys.argv[2], sys.argv[3])
    elif sys.argv[1] == '--migrate':migrate(sys.argv[2])
    else:print(runtime_directory(sys.argv[1]))
