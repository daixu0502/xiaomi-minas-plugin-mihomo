"""Shared, root-owned API/runtime. No network listener and no arbitrary-command API."""
import contextlib
import fcntl
import json
import os
from pathlib import Path
import pwd
import re
import stat
import subprocess
import time

VERSION = '1.1.1'
LAYOUT_VERSION = 2
API_VERSION = 1
BASE = Path('/data/.minas-privileged')
DOCKER = '/data/docker/docker'
MODULES = {'dockermanager', 'taskcenter', 'sshrecovery', 'mihomo', 'nascenter'}
DISTRIBUTORS = MODULES


class DockerBusyError(ValueError):
    """The transaction was never acquired; no Docker command has run."""


def secure_directory(path, create=False, mode=0o755):
    path = Path(path)
    if create and not path.exists():
        secure_directory(path.parent)
        path.mkdir(mode=mode)
    for current in (path,) + tuple(path.parents):
        s = current.lstat()
        if not stat.S_ISDIR(s.st_mode) or s.st_uid != 0 or s.st_mode & 0o022:
            raise ValueError('权限组件目录必须由 root 拥有且普通用户不可写：%s' % current)
    if create:
        # mkdir's mode is filtered by the installer's umask. The public entry
        # directory needs traversal for CGI preflight; state/backups use 0700.
        path.chmod(mode)
    return path


@contextlib.contextmanager
def lock(name, exclusive=False, wait=0):
    secure_directory(BASE)
    if name not in {'component.lock', 'docker.lock'}:
        raise ValueError('无效锁')
    fd = os.open(str(BASE / name), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        s = os.fstat(fd)
        if not stat.S_ISREG(s.st_mode) or s.st_uid != 0 or s.st_mode & 0o022:
            raise ValueError('权限组件锁文件不安全')
        deadline = time.monotonic() + wait
        while True:
            try:
                fcntl.flock(fd, (fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH) | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    if name == 'docker.lock':
                        raise DockerBusyError('Docker 正被另一个插件操作，请稍后重试')
                    raise ValueError('权限组件正在使用或更新，请稍后重试')
                time.sleep(.05)
        yield fd
    finally:
        # Do not LOCK_UN: async Docker workers inherit this file description.
        # Closing only this process's fd leaves their transaction protected.
        os.close(fd)


def component_use():
    # A worker may start just as an installer checks its reserved run. Give the
    # installer time to reject the update rather than losing that queued worker.
    return lock('component.lock', wait=10)


def docker_transaction(wait=0):
    return lock('docker.lock', exclusive=True, wait=wait)


def docker_command(args, timeout=300):
    # Never inherit DOCKER_HOST, DOCKER_CONTEXT or a caller's Docker credentials.
    env = {'PATH': '/data/docker:/usr/sbin:/usr/bin:/sbin:/bin',
           'LC_ALL': 'C.UTF-8', 'HOME': pwd.getpwuid(0).pw_dir, 'DOCKER_HOST': 'unix:///var/run/docker.sock'}
    return subprocess.run([DOCKER] + list(args), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          encoding='utf-8', errors='replace', env=env, timeout=timeout, check=False)


def account(user):
    if not re.fullmatch(r'u[0-9]+', user or ''):
        raise ValueError('无效 NAS 用户')
    pwd.getpwnam(user)
    return user


def registry():
    file = BASE / 'registry.json'
    s = file.lstat()
    if not stat.S_ISREG(s.st_mode) or s.st_uid != 0 or s.st_mode & 0o077:
        raise ValueError('权限登记文件不安全')
    data = json.loads(file.read_text())
    if data.get('apiVersion') != API_VERSION:
        raise ValueError('不兼容的权限组件 API 版本')
    return data


def authorize(user, plugin):
    account(user)
    if plugin not in MODULES or plugin not in registry().get('users', {}).get(user, []):
        raise ValueError('该用户未授权使用此权限模块')
    return user


def task_docker(user, task):
    """Narrow scheduler interface; cannot request arbitrary Docker flags/mounts."""
    # Scheduled workers may start together. Queue only before executing anything;
    # never retry a partially completed Docker command. Waiting and inspection
    # share the task's existing total timeout rather than extending it.
    timeout = task['timeout']
    deadline = time.monotonic() + timeout
    def remaining(limit=None):
        seconds = deadline - time.monotonic()
        if seconds <= 0:
            raise subprocess.TimeoutExpired('Docker 任务', timeout)
        return min(seconds, limit) if limit is not None else seconds
    try:
        with docker_transaction(wait=timeout):
            return _task_docker_locked(user, task, remaining)
    except DockerBusyError as error:
        raise DockerBusyError('等待 Docker 操作队列超时（%s 秒）；本次未执行 Docker 命令，请检查其他插件是否有长时间操作。' % timeout) from error


def _task_docker_locked(user, task, remaining):
    params, kind = task['params'], task['kind']
    if kind == 'docker_image':
        inspected = docker_command(['image', 'inspect', params['image']], timeout=remaining(15))
        if inspected.returncode:
            raise ValueError('本地镜像不存在，请先在 Docker 插件拉取镜像')
        existing = docker_command(['container', 'inspect', params['name']], timeout=remaining(15))
        if existing.returncode == 0:
            details = json.loads(existing.stdout)[0]
            labels = details.get('Config', {}).get('Labels') or {}
            if labels.get('xiaomi.taskcenter.user') != user or labels.get('xiaomi.taskcenter.task') != task['id'] or details['Config']['Image'] != params['image']:
                raise ValueError('同名容器不属于此任务/镜像，请换一个名称')
            args = ['start', params['name']]
        else:
            args = ['run', '-d', '--name', params['name'], '--label', 'xiaomi.taskcenter.user=' + user,
                    '--label', 'xiaomi.taskcenter.task=' + task['id'], '--network', 'bridge', '--restart', 'no', params['image']]
    elif kind in {'docker_start', 'docker_stop', 'docker_restart'}:
        args = [kind.replace('docker_', ''), params['container']]
    else:
        raise ValueError('不支持的任务 Docker 操作')
    return docker_command(args, timeout=remaining())
