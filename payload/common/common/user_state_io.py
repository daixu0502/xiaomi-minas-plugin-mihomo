"""Read/write disposable plugin state as the NAS user, never as root.

Only fixed plugin names and basenames are accepted. Configuration that drives
privileged actions, execution code, authorization and secrets must not use this
store: its owner can edit it. No network or sudo entry point is provided here.
"""
import contextlib
import json
import os
from pathlib import Path
import pwd
import re
import select
import subprocess
import sys

HOME_ROOT = Path('/home')
PLUGINS = {'dockermanager', 'nascenter'}
MAX_BYTES = 4 * 1024 * 1024

_PROGRAM = r'''
import fcntl,json,os,stat,sys,tempfile
from pathlib import Path
home,operation,name=sys.argv[1:]
home=Path(home)
for node in (home.parent,home):
    if node.is_symlink() or not node.is_dir():raise ValueError('plugin directory unavailable')
directory=home/'var'
if directory.is_symlink():raise ValueError('state directory is a symlink')
directory.mkdir(mode=0o700,exist_ok=True)
if not directory.is_dir():raise ValueError('state directory unavailable')
target=directory/name
if target.is_symlink():raise ValueError('state file is a symlink')
if operation=='lock':
    fd=os.open(target,os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600)
    if not stat.S_ISREG(os.fstat(fd).st_mode):raise ValueError('invalid lock')
    try:fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
    except BlockingIOError:print('busy',flush=True);sys.exit(2)
    print('locked',flush=True)
    sys.stdin.buffer.read()
elif operation=='read':
    try:
        fd=os.open(target,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
        with os.fdopen(fd,'rb') as stream:
            metadata=os.fstat(stream.fileno())
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_size>4194304:raise ValueError('invalid state file')
            data=json.load(stream)
        print(json.dumps(data if isinstance(data,dict) else None))
    except (FileNotFoundError,ValueError):print('null')
elif operation=='write':
    raw=sys.stdin.buffer.read(4194305)
    if len(raw)>4194304 or not isinstance(json.loads(raw),dict):raise ValueError('invalid state')
    fd,temp=tempfile.mkstemp(prefix='.state-',dir=directory)
    try:
        with os.fdopen(fd,'wb') as stream:
            stream.write(raw);stream.flush();os.fsync(stream.fileno())
        os.replace(temp,target)
    finally:
        if os.path.exists(temp):os.unlink(temp)
    print('null')
else:raise ValueError('unknown operation')
'''


def _arguments(user, plugin, name, operation):
    if not re.fullmatch(r'u[0-9]+', user or '') or plugin not in PLUGINS:
        raise ValueError('无效插件状态身份')
    if not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9_.-]{0,95}', name):
        raise ValueError('无效状态文件名')
    account = pwd.getpwnam(user)
    if account.pw_uid==0:raise ValueError('插件运行状态必须属于普通 NAS 用户')
    def demote():
        if os.geteuid() == 0:
            os.initgroups(account.pw_name, account.pw_gid)
            os.setgid(account.pw_gid)
            os.setuid(account.pw_uid)
        elif os.geteuid() != account.pw_uid:
            raise PermissionError('禁止访问其他用户的插件状态')
    return dict(args=[sys.executable, '-I', '-c', _PROGRAM,
                      str(HOME_ROOT / user / 'plugin' / plugin), operation, name],
                cwd='/', env={'PATH':'/usr/bin:/bin','LC_ALL':'C'},
                preexec_fn=demote, close_fds=True)


def read_state(user, plugin, name):
    result = subprocess.run(**_arguments(user, plugin, name, 'read'),
                            capture_output=True, timeout=8)
    if result.returncode:
        raise ValueError('无法读取插件运行状态')
    return json.loads(result.stdout)


def write_state(user, plugin, name, value):
    if not isinstance(value, dict):raise ValueError('插件状态必须是对象')
    data = json.dumps(value, ensure_ascii=False).encode()
    if len(data)>MAX_BYTES:raise ValueError('插件状态过大')
    result = subprocess.run(**_arguments(user, plugin, name, 'write'),
                            input=data, capture_output=True, timeout=8)
    if result.returncode:raise ValueError('无法保存插件运行状态')


@contextlib.contextmanager
def state_lock(user, plugin, name):
    process = subprocess.Popen(**_arguments(user, plugin, name, 'lock'),
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL)
    try:
        ready = select.select([process.stdout], [], [], 8)[0]
        locked = bool(ready and process.stdout.readline().strip()==b'locked')
        yield locked
    finally:
        process.stdin.close()
        try:process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill();process.wait(timeout=3)
        process.stdout.close()
