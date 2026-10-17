#!/usr/bin/python3
"""Install/remove shared component registrations. Called only by root installers."""
import argparse
import contextlib
import datetime
import fcntl
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import privileged_runtime as runtime

BASE = runtime.BASE
HOME = Path('/home')
PLUGIN_DATA = Path('/data/plugin')
BACKUPS = Path('/data/.minas-privileged-backups')
SUDOERS = Path('/etc/sudoers.d')
CRON = Path('/etc/cron.d')
LEGACY = [Path('/data/plugin/.taskcenter-system'), Path('/data/.taskcenter-system')]
CORE_FILES = ('minas-helper', 'component_admin.py', 'common/privileged_runtime.py', 'common/component_admin.py', 'common/user_state_io.py', 'common/telemetry_cache.py')
PRIVATE_FILES = {
 'dockermanager': ('docker-manager-helper',),
 'taskcenter': ('task-center-helper','task_schedule.py','task_maintenance.py'),
 'sshrecovery': ('ssh-recovery-helper','restore-ssh.sh'),
 'mihomo': ('api.py','mihomo-docker-proxy','docker_proxy_status.py'),
 'nascenter': ('api.py','nas-center-helper','process_metrics.py'),
}
FLAT_FILES = {'dockermanager':('docker-manager-helper',),'taskcenter':('task-center-helper','task_schedule.py','task_maintenance.py'),'sshrecovery':('ssh-recovery-helper','ssh-recovery-boot.sh')}

MIGRATION_MARK = 'MIGRATED_TO_COMMON'


def atomic(path, data, mode=0o600):
    if isinstance(data, dict):
        data = json.dumps(data, ensure_ascii=False, indent=2).encode()
    if isinstance(data, str): data = data.encode()
    if path.is_symlink(): raise ValueError('拒绝覆盖符号链接：%s' % path)
    fd, tmp = tempfile.mkstemp(prefix='.' + path.name + '.', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'wb') as f:
            f.write(data); os.fchmod(f.fileno(), mode); os.fchown(f.fileno(), 0, 0)
            f.flush(); os.fsync(f.fileno())
        os.replace(tmp, str(path))
    finally:
        if os.path.exists(tmp): os.unlink(tmp)


def version(value):
    if not re.fullmatch(r'\d+\.\d+\.\d+', value): raise ValueError('无效组件版本')
    return tuple(map(int, value.split('.')))


def validate_tree(directory):
    for path in [directory] + list(directory.rglob('*')):
        s = path.lstat()
        if s.st_uid != 0 or s.st_mode & 0o022 or not (stat.S_ISREG(s.st_mode) or stat.S_ISDIR(s.st_mode)):
            raise ValueError('调度数据包含链接、不安全权限或非 root 文件：%s' % path)


def check_idle():
    # The component exclusive lock already excludes current shared workers.
    for directory in [BASE] + LEGACY:
        users = directory / 'users'
        if not users.is_dir(): continue
        for file in users.glob('u*/state.json'):
            state = json.loads(file.read_text())
            for run in state.get('runs', []):
                if run.get('state') == 'running':
                    pid = run.get('pid')
                    if pid and Path('/proc/%s' % int(pid)).exists():
                        raise ValueError('存在执行中的定时任务，稍后再更新')
                    # Do not silently classify a just-reserved worker as dead.
                    import time
                    if time.time() - run.get('started', 0) < 90:
                        raise ValueError('存在刚提交的定时任务，稍后再更新')
    for file in [Path('/run/dockermanager-upgrade-status.json'), Path('/run/dockermanager-bulk-status.json')]:
        if not file.is_file(): continue
        data = json.loads(file.read_text())
        if data.get('state') == 'running' and data.get('pid') and Path('/proc/%s' % int(data['pid'])).exists():
            raise ValueError('Docker 正在升级或批量操作，稍后再安装')


@contextlib.contextmanager
def migration(user, backup):
    target = BASE / 'users' / user
    source = next((d / 'users' / user for d in reversed(LEGACY)
                   if (d / 'users' / user / 'state.json').is_file()
                   and not (d / 'users' / user / MIGRATION_MARK).exists()
                   and not (d / 'users' / user / 'MIGRATED_TO_V02').exists()), None)
    if target.exists() or source is None:
        yield
        return
    validate_tree(source)
    fd = os.open(str(source / 'lock'), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    old = None
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        old = (source / 'state.json').read_bytes()
        state = json.loads(old)
        if any(r.get('state') == 'running' for r in state.get('runs', [])):
            raise ValueError('旧版任务记录仍处于执行中，请先确认任务结束')
        shutil.copytree(str(source), str(backup / 'legacy-state'))
        atomic(backup / 'legacy-source.json', {'path': str(source)})
        runtime.secure_directory(BASE / 'users', create=True, mode=0o700)
        # Target name becomes visible only after old scheduler has been disabled.
        staging = Path(tempfile.mkdtemp(prefix='.' + user + '-', dir=str(BASE / 'users')))
        staging.rmdir()
        shutil.copytree(str(source), str(staging))
        state['scheduler'] = False
        atomic(source / 'state.json', state)
        os.replace(str(staging), str(target))
        try:
            yield
            atomic(source / MIGRATION_MARK, str(target) + '\n')
        except BaseException:
            atomic(source / 'state.json', old)
            if target.exists(): shutil.rmtree(str(target))
            raise
    finally:
        os.close(fd)


def install_sudo(user, plugin):
    rule = '%s ALL=(root) NOPASSWD: %s/minas-helper %s\n' % (user, BASE, plugin)
    fd, temp = tempfile.mkstemp(prefix='.minas-sudo-', dir=str(SUDOERS))
    os.close(fd); temp = Path(temp)
    try:
        atomic(temp, rule, 0o440)
        subprocess.run(['/usr/sbin/visudo', '-cf', str(temp)], check=True, stdout=subprocess.DEVNULL)
        os.replace(str(temp), str(SUDOERS / (plugin + '-' + user)))
    finally:
        if temp.exists(): temp.unlink()


def migrate_docker_status(data, backup):
    """Preserve old display state; exclusive component lock excludes workers."""
    import user_state_io
    users=[u for u,grants in data['users'].items() if 'dockermanager' in grants]
    files=[]
    for old,name in ((Path('/run/dockermanager-upgrade-status.json'),'docker-upgrade-status.json'),
                     (Path('/run/dockermanager-bulk-status.json'),'docker-bulk-status.json')):
        if not old.exists():continue
        st=old.lstat()
        if not stat.S_ISREG(st.st_mode) or st.st_uid!=0 or st.st_mode&0o022:
            raise ValueError('旧 Docker 状态文件权限异常')
        raw=old.read_bytes();value=json.loads(raw)
        if not isinstance(value,dict):raise ValueError('旧 Docker 状态无效')
        saved=backup/'legacy-docker-status';saved.mkdir(mode=0o700,exist_ok=True)
        atomic(saved/old.name,raw)
        for user in users:
            if user_state_io.read_state(user,'dockermanager',name) is None:
                user_state_io.write_state(user,'dockermanager',name,value)
        files.append(old)
    for old in files:old.unlink()


def update_cron(data):
    plugins = {p for grants in data['users'].values() for p in grants}
    file = CRON / 'minas-privileged'
    if plugins:
        text = 'SHELL=/bin/sh\nPATH=/usr/sbin:/usr/bin:/sbin:/bin:/data/docker\nMAILTO=""\n'
        if 'taskcenter' in plugins:
            text += '* * * * * root %s/minas-helper taskcenter tick >/dev/null 2>&1\n' % BASE
        if 'sshrecovery' in plugins:
            text += '* * * * * root %s/minas-helper sshrecovery prune >/dev/null 2>&1\n' % BASE
        if 'dockermanager' in plugins:
            text += '@reboot root %s/minas-helper boot >/dev/null 2>&1\n' % BASE
        atomic(file, text, 0o644)
    elif file.exists(): file.unlink()
    # Retain legacy cron only when an unmigrated account still needs it.
    remaining = any(not (f.parent / MIGRATION_MARK).exists() and not (f.parent / 'MIGRATED_TO_V02').exists()
                    for d in LEGACY for f in (d / 'users').glob('u*/state.json'))
    old = CRON / 'taskcenter'
    if not remaining and old.is_file() and 'task-center-helper' in old.read_text(): old.unlink()


def bundle(payload, plugin):
    import hashlib
    source = payload / 'common'
    manifest = json.loads((source/'manifest.json').read_bytes())
    if manifest['version'] != runtime.VERSION or manifest['apiVersion'] != runtime.API_VERSION or manifest['plugin'] != plugin:
        raise ValueError('安装包公共组件版本或插件身份不一致')
    expected = set(CORE_FILES) | {'modules/'+plugin+'/'+name for name in PRIVATE_FILES.get(plugin, ())}
    if set(manifest['files']) != expected:
        raise ValueError('安装包必须只包含共有代码和当前插件私有代码')
    result = {}
    for name, checksum in manifest['files'].items():
        path = source/name
        if path.is_symlink() or not path.is_file() or path.resolve() != path:
            raise ValueError('安装包组件路径异常')
        data = path.read_bytes()
        if hashlib.sha256(data).hexdigest() != checksum:
            raise ValueError('安装包组件摘要不匹配')
        result[name] = data
    return result


def install_code(relative, value):
    target = BASE/relative
    for directory in reversed(tuple(target.parent.relative_to(BASE).parents)):
        if str(directory) != '.': runtime.secure_directory(BASE/directory, create=True)
    runtime.secure_directory(target.parent, create=True)
    executable = target.name in ('minas-helper','component_admin.py','docker-manager-helper','task-center-helper','ssh-recovery-helper','nas-center-helper','mihomo-docker-proxy') or target.suffix == '.sh'
    atomic(target, value, 0o755 if executable else 0o644)


def retire_legacy(plugin, user):
    # A module update owns only its own former flat files.
    for name in FLAT_FILES.get(plugin, ()):
        path = BASE/name
        if path.exists():
            if path.is_symlink() or not path.is_file() or path.stat().st_uid != 0:
                raise ValueError('旧权限模块文件异常')
            path.unlink()
    if plugin not in ('mihomo','nascenter'): return
    if plugin == 'mihomo':
        old_rule = SUDOERS/('mihomo-docker-proxy-'+user)
        if old_rule.is_file() and '/data/plugin/.mihomo-system/' in old_rule.read_text(): old_rule.unlink()
        names = ('mihomo-docker-proxy','docker_proxy_status.py')
    else: names = ('nas-center-helper','process_metrics.py','telemetry_cache.py','user_state_io.py')
    legacy = PLUGIN_DATA/('.'+plugin+'-system')
    # Other accounts may still have old CGI/control entry points.
    for rule in SUDOERS.iterdir():
        if rule.is_file() and str(legacy) in rule.read_text(errors='replace'): return
    for home in HOME.glob('u*/plugin/'+plugin):
        for relative in ('ui/'+plugin+'.cgi', 'scripts/control'):
            path = (home/'src'/relative) if relative.startswith('ui/') else home/relative
            if path.is_file() and str(legacy) in path.read_text(errors='replace'): return
    if legacy.is_dir():
        runtime.secure_directory(legacy)
        for name in names:
            file = legacy/name
            if file.is_file() and not file.is_symlink() and file.stat().st_uid == 0: file.unlink()
        try: legacy.rmdir()
        except OSError: pass


def install(payload, plugin, user, plugin_version, backup):
    values = bundle(payload, plugin)
    old = runtime.registry() if (BASE/'registry.json').exists() else {'apiVersion':1,'version':'0.0.0','users':{},'modules':{}}
    if old.get('apiVersion') != runtime.API_VERSION:
        raise ValueError('公共权限组件 API 不兼容，拒绝升级')
    if version(old.get('modules',{}).get(plugin,'0.0.0')) > version(plugin_version):
        raise ValueError('已安装更新的插件权限模块，拒绝降级')
    data = json.loads(json.dumps(old))
    if version(old['version']) < version(runtime.VERSION):
        for name in CORE_FILES: install_code(name, values[name])
        data.update(version=runtime.VERSION, layoutVersion=runtime.LAYOUT_VERSION)
        # These are shared files, not any other plugin's private implementation.
        for name in ('privileged_runtime.py','user_state_io.py'):
            file = BASE/name
            if file.is_file() and not file.is_symlink(): file.unlink()
    elif version(old['version']) == version(runtime.VERSION):
        import hashlib
        for name in CORE_FILES:
            path = BASE/name
            if not path.is_file() or path.is_symlink() or hashlib.sha256(path.read_bytes()).digest() != hashlib.sha256(values[name]).digest():
                raise ValueError('同版本共有组件内容不一致，拒绝静默覆盖')
    for name in PRIVATE_FILES.get(plugin, ()):
        install_code('modules/'+plugin+'/'+name, values['modules/'+plugin+'/'+name])
    # Distributors without privileged operations receive no sudo grant/module.
    data.setdefault('packages',{})[plugin] = plugin_version
    if plugin in runtime.MODULES:
        data['users'].setdefault(user, [])
        if plugin not in data['users'][user]: data['users'][user].append(plugin)
        data.setdefault('modules',{})[plugin] = plugin_version
    if plugin == 'mihomo':
        import re
        text = (HOME/user/'plugin/mihomo/etc/ports.env').read_text()
        match = re.search(r'^MIXED_PORT=([0-9]+)$',text,re.M)
        if not match or not 1024 <= int(match[1]) <= 65535: raise ValueError('Mihomo 端口未配置')
        data.setdefault('settings',{}).setdefault(user,{})['mihomo'] = {'proxyPort':int(match[1])}
    if plugin == 'sshrecovery':
        for name in ('sshrecovery','sshrecovery/keys','sshrecovery/host','sshrecovery/tmp'):
            runtime.secure_directory(BASE/name, create=True, mode=0o700)
        worker = Path('/data/ssh-autostart-fix/recover-ssh.py')
        old_helper = BASE/'ssh-recovery-helper'
        if worker.is_file():
            # Preserve standalone emergency recovery when the flat asset retires.
            previous = worker.read_bytes()
            # Change only the retired asset lookup, preserving standalone fixes.
            updated = previous.replace(b"BASE/'ssh-recovery-boot.sh'", b"Path('/data/ssh-autostart-fix/restore-ssh.sh')")
            if updated != previous:
                compile(updated, str(worker), 'exec')
                atomic(backup/'standalone-ssh-worker', previous, 0o600)
                atomic(worker, updated, worker.stat().st_mode & 0o777)
    atomic(BASE/'registry.json', data)
    with migration(user, backup) if plugin == 'taskcenter' else contextlib.nullcontext():
        if plugin == 'taskcenter':
            sys.path.insert(0,str(BASE/'modules/taskcenter'))
            loader=importlib.machinery.SourceFileLoader('install_tasks',str(BASE/'modules/taskcenter/task-center-helper'))
            spec=importlib.util.spec_from_loader(loader.name,loader);module=importlib.util.module_from_spec(spec);loader.exec_module(module)
            if not (BASE/'users'/user/'state.json').is_file() or 'taskcenter' not in old.get('users',{}).get(user,[]):
                module.initialize(user)
            state=json.loads((BASE/'users'/user/'state.json').read_text())
            for task in state['tasks']: module.validate_task(task)
        if plugin in runtime.MODULES: install_sudo(user,plugin)
    obsolete = CRON/('dockermanager-'+user)
    if plugin == 'dockermanager' and obsolete.exists(): obsolete.unlink()
    update_cron(data)
    if plugin == 'dockermanager': migrate_docker_status(data,backup)
    retire_legacy(plugin,user)
    return data


def remove(plugin, user, backup):
    data = runtime.registry()
    if plugin == 'sshrecovery':
        key = BASE / 'sshrecovery/keys' / (user + '.pub')
        if key.exists(): key.unlink()
    grants = data['users'].get(user, [])
    if plugin == 'taskcenter':
        target = BASE / 'users' / user
        if target.exists():
            validate_tree(target)
            shutil.copytree(str(target), str(backup / 'removed-state'))
            # Exact validated single-user state, never the user's files or containers.
            shutil.rmtree(str(target))
    if plugin in grants: grants.remove(plugin)
    if not grants: data['users'].pop(user, None)
    if plugin == 'sshrecovery' and not any('sshrecovery' in g for g in data['users'].values()):
        state = BASE / 'sshrecovery'
        if state.exists():
            validate_tree(state)
            shutil.rmtree(str(state))
    if plugin == 'mihomo':
        data.get('settings',{}).get(user,{}).pop('mihomo',None)
    if not any(plugin in grants for grants in data['users'].values()):
        data.get('modules',{}).pop(plugin,None)
        module = BASE/'modules'/plugin
        if module.is_dir():
            validate_tree(module);shutil.rmtree(module)
    atomic(BASE / 'registry.json', data)
    rule = SUDOERS / (plugin + '-' + user)
    if rule.exists(): rule.unlink()
    update_cron(data)
    # Keep stable shared entry points for other distributors and future installs.
    return data


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['install', 'remove'])
    parser.add_argument('--plugin', choices=sorted(runtime.DISTRIBUTORS), required=True)
    parser.add_argument('--user', required=True)
    parser.add_argument('--payload', type=Path)
    parser.add_argument('--plugin-version', default='0.0.0')
    args = parser.parse_args()
    if os.geteuid() != 0 or os.environ.get('SUDO_USER') not in (None, 'root'):
        raise ValueError('组件管理仅允许 root 安装器调用')
    runtime.account(args.user)
    runtime.secure_directory(BASE, create=True)

    with runtime.lock('component.lock', exclusive=True, wait=15):
        check_idle()
        if args.action == 'remove':
            runtime.secure_directory(BACKUPS,create=True,mode=0o700)
            backup=Path(tempfile.mkdtemp(prefix='removed-'+args.plugin+'-',dir=str(BACKUPS)))
        else: backup = Path(tempfile.mkdtemp(prefix='minas-component-'))
        saved = backup / 'component'
        shutil.copytree(str(BASE), str(saved), ignore=shutil.ignore_patterns('*.lock','backups'))
        legacy = PLUGIN_DATA/('.'+args.plugin+'-system')
        if legacy.is_dir():
            validate_tree(legacy);shutil.copytree(legacy,backup/'legacy-helper')
        old_mihomo_rule=SUDOERS/('mihomo-docker-proxy-'+args.user)
        if args.plugin=='mihomo' and old_mihomo_rule.is_file():shutil.copy2(old_mihomo_rule,backup/'legacy-mihomo-sudoers')
        rule = SUDOERS / (args.plugin + '-' + args.user)
        if rule.exists(): shutil.copy2(str(rule), str(backup / 'sudoers'))
        for file in CRON.glob('*'):
            if file.is_file() and file.name in {'minas-privileged', 'taskcenter', 'dockermanager-' + args.user}:
                shutil.copy2(str(file), str(backup / ('cron-' + file.name)))
        try:
            data = install(args.payload, args.plugin, args.user, args.plugin_version, backup) if args.action == 'install' else remove(args.plugin, args.user, backup)
        except BaseException:
            # Restore grouped code and protected state, preserving live lock inodes.
            for name in ('common','modules','users','sshrecovery'):
                current=BASE/name; previous=saved/name
                if current.exists():
                    validate_tree(current);shutil.rmtree(current)
                if previous.exists():shutil.copytree(previous,current)
            for file in BASE.iterdir():
                if file.is_file() and file.name not in {'component.lock','docker.lock'} and not (saved/file.name).exists(): file.unlink()
            for file in saved.iterdir():
                if file.is_file():atomic(BASE/file.name,file.read_bytes(),file.stat().st_mode&0o777)
            if (backup/'legacy-helper').exists():
                if legacy.exists():validate_tree(legacy);shutil.rmtree(legacy)
                shutil.copytree(backup/'legacy-helper',legacy)
            if (backup/'legacy-mihomo-sudoers').exists():atomic(old_mihomo_rule,(backup/'legacy-mihomo-sudoers').read_bytes(),0o440)
            if (backup/'standalone-ssh-worker').exists():
                atomic(Path('/data/ssh-autostart-fix/recover-ssh.py'),(backup/'standalone-ssh-worker').read_bytes(),0o700)
            if (backup / 'legacy-source.json').exists():
                legacy = Path(json.loads((backup / 'legacy-source.json').read_text())['path'])
                if legacy not in [p / 'users' / args.user for p in LEGACY]:
                    raise ValueError('无效恢复路径')
                atomic(legacy / 'state.json', (backup / 'legacy-state/state.json').read_bytes())
                if (legacy / MIGRATION_MARK).exists(): (legacy / MIGRATION_MARK).unlink()
            if (backup / 'sudoers').exists(): atomic(rule, (backup / 'sudoers').read_bytes(), 0o440)
            elif rule.exists(): rule.unlink()
            for name in ['minas-privileged', 'taskcenter', 'dockermanager-' + args.user]:
                saved_cron = backup / ('cron-' + name)
                if saved_cron.exists(): atomic(CRON / name, saved_cron.read_bytes(), 0o644)
                elif (CRON / name).exists(): (CRON / name).unlink()
            raise
        finally:
            if args.action == 'install': shutil.rmtree(backup)
    subprocess.run(['/usr/bin/systemctl', 'reload', 'crond.service'], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(json.dumps({'ok': True, 'helperVersion': data['version'], 'backup': str(backup) if args.action == 'remove' else None, 'registeredUsers': len(data['users'])}, ensure_ascii=False))


if __name__ == '__main__':
    try: main()
    except Exception as error:
        print('公共权限组件安装/卸载失败：%s' % error, file=sys.stderr)
        sys.exit(1)
