#!/usr/bin/env python3
"""Per-user detached update jobs. Runtime files never belong in plugin src."""
import fcntl
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

HERE = Path(__file__).resolve().parent
HOME = Path(os.environ.get('PLUG_HOME_DIR', '/home/' + HERE.parts[3] + '/plugin/mihomo'))
VAR = HOME / 'var'
from plugin_paths import runtime_directory
RUNTIME = runtime_directory(HOME)
TASKS = RUNTIME / 'update-tasks'
LOCK = RUNTIME / 'update-operation.lock'
ACTIONS = {'subscription_update', 'subscription_import', 'geodata_update', 'geodata_apply_policy',
           'rule_provider_import', 'update_provider', 'update_rule_provider'}
TITLES = {'subscription_update': '更新订阅', 'subscription_import': '导入订阅',
          'geodata_update': '更新 Geo 数据', 'geodata_apply_policy': '应用 Geo 策略',
          'rule_provider_import': '导入规则提供者', 'update_provider': '更新节点提供者',
          'update_rule_provider': '更新规则提供者'}


def redact(message):
    text = re.sub(r'[A-Za-z][A-Za-z0-9+.-]*://[^\s<>"\']+', '[地址已隐藏]', str(message))
    return re.sub(r'(?i)((?:password|secret|token|authorization)\s*[:=]\s*)[^\s,}]+',
                  r'\1[已隐藏]', text)[:700]


def atomic(path, value):
    fd, name = tempfile.mkstemp(prefix='.task-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            json.dump(value, stream, ensure_ascii=False)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def task_path(ident):
    if not isinstance(ident, str) or not re.fullmatch('[a-f0-9]{32}', ident):
        raise RuntimeError('无效的后台任务编号')
    return TASKS / (ident + '.json')


def change(ident, **fields):
    path = task_path(ident)
    job = json.loads(path.read_text())
    job.update(fields, updatedAt=time.time())
    atomic(path, job)
    return job


def progress(stage, percent, message):
    ident = os.environ.get('MIHOMO_TASK_ID')
    if ident:
        change(ident, stage=stage, percent=max(0, min(99, int(percent))), message=redact(message))


def controller(method, path, body=None):
    # Fixed local controller only; never use HTTP_PROXY or expose its secret in argv.
    if not re.fullmatch(r'/(?:version|configs(?:\?force=true)?|providers/(?:proxies|rules)(?:/[^/?#]+)?)', path):
        raise RuntimeError('不支持的内核控制接口')
    ports = (HOME / 'etc/ports.env').read_text()
    match = re.search(r'^CONTROLLER_PORT=([0-9]+)$', ports, re.M)
    port = int(match.group(1)) if match else 9090
    if not 1 <= port <= 65535:
        raise RuntimeError('内核控制端口无效')
    secret = (HOME / 'etc/api.secret').read_text().strip()
    req = urllib.request.Request('http://127.0.0.1:%d%s' % (port, path), method=method,
                                 headers={'Authorization': 'Bearer ' + secret, 'Content-Type': 'application/json'},
                                 data=None if body is None else json.dumps(body).encode())
    try:
        with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req, timeout=45) as response:
            raw = response.read(4 * 1024 * 1024)
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        message = ''
        try:
            payload = json.loads(error.read(4096))
            message = ': ' + redact(payload.get('message') or payload.get('error') or '')
        except (ValueError, AttributeError):
            pass
        raise RuntimeError('内核接口 HTTP %d%s' % (error.code, message)) from None
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        raise RuntimeError('内核接口连接失败或超时：' + redact(getattr(error, 'reason', error))) from None


def hot_apply(kind):
    pid_file = RUNTIME / 'mihomo.pid'
    try:
        pid = int(pid_file.read_text().strip())
        command = Path('/proc/%d/cmdline' % pid).read_bytes().split(b'\0')[0].decode()
        binaries = {str(HOME / 'var/core/mihomo'), str(HOME / 'src/files/mihomo'), str(HERE / 'mihomo')}
        if command not in binaries:
            raise RuntimeError('PID 文件不属于当前用户的 Mihomo，未执行热加载')
    except (FileNotFoundError, ProcessLookupError):
        return {'ok': True, 'activation': 'saved', 'message': '核心未运行，已保存供下次启动使用'}
    progress('activating', 88, '正在热加载节点' if kind == 'subscription' else '正在热加载配置与规则')
    if kind == 'subscription':
        controller('PUT', '/providers/proxies/APP-SUBSCRIPTION')
    elif kind == 'config':
        controller('PUT', '/configs?force=true', {'path': str(HOME / 'etc/config.yaml')})
    else:
        raise RuntimeError('不支持的热加载类型')
    return {'ok': True, 'activation': 'hot', 'restarted': False}


def start(action, payload):
    if action not in ACTIONS or not isinstance(payload, dict):
        raise RuntimeError('不支持的后台更新操作')
    TASKS.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd = os.open(LOCK, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('已有更新或配置应用任务正在执行，请等待完成') from None
        # A free lock proves no old worker is alive. Retire requests left by a
        # reboot/crash before accepting another job, including sensitive URLs.
        for old in TASKS.glob('*.json'):
            if old.name == 'current.json':
                continue
            value = json.loads(old.read_text())
            if value.get('status') in ('queued', 'running'):
                change(value['id'], status='failed', stage='failed', error='上次后台任务异常中断，请重试', finishedAt=time.time())
                for suffix in ('.request', '.output', '.errors'):
                    (TASKS / (value['id'] + suffix)).unlink(missing_ok=True)
        ident = uuid.uuid4().hex
        now = time.time()
        title = TITLES[action]
        if action in ('update_provider', 'update_rule_provider') and isinstance(payload.get('provider'), str):
            title += ' · ' + redact(payload['provider'])[:80]
        job = {'id': ident, 'action': action, 'title': title, 'status': 'queued', 'stage': 'queued',
               'percent': 0, 'message': '任务已提交，正在准备', 'createdAt': now, 'updatedAt': now}
        atomic(task_path(ident), job)
        request = TASKS / (ident + '.request')
        atomic(request, payload)
        try:
            env = dict(os.environ, PLUG_HOME_DIR=str(HOME), PYTHONDONTWRITEBYTECODE='1')
            subprocess.Popen([sys.executable, '-B', str(Path(__file__).resolve()), 'worker', ident, str(fd)],
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             close_fds=True, pass_fds=(fd,), start_new_session=True, env=env, cwd=str(VAR))
        except BaseException:
            request.unlink(missing_ok=True)
            change(ident, status='failed', stage='failed', error='无法启动后台更新进程')
            raise
        atomic(TASKS / 'current.json', {'id': ident})
        # Bounded history; never remove active jobs or their request files.
        history = sorted((p for p in TASKS.glob('*.json') if p.name != 'current.json'), key=lambda p: p.stat().st_mtime)
        for path in history[:-12]:
            if json.loads(path.read_text()).get('status') not in ('queued', 'running'):
                path.unlink(missing_ok=True)
        return {'ok': True, 'accepted': True, 'task': job}
    finally:
        # Do NOT LOCK_UN: the child owns this same open file description now.
        os.close(fd)


def status(ident=None):
    if not ident:
        try:
            ident = json.loads((TASKS / 'current.json').read_text())['id']
        except FileNotFoundError:
            return {'ok': True, 'task': None}
    job = json.loads(task_path(ident).read_text())
    if job['status'] in ('queued', 'running'):
        fd = os.open(LOCK, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                pass
            else:
                job = change(ident, status='failed', stage='failed', error='上次后台任务异常中断，请重试', finishedAt=time.time())
                for suffix in ('.request', '.output', '.errors'):
                    (TASKS / (ident + suffix)).unlink(missing_ok=True)
        finally:
            os.close(fd)
    job['elapsedSeconds'] = round((job.get('finishedAt') or time.time()) - job['createdAt'], 1)
    return {'ok': True, 'task': job}


def worker(ident, fd):
    if os.fstat(fd).st_ino != LOCK.stat().st_ino or os.fstat(fd).st_dev != LOCK.stat().st_dev:
        raise RuntimeError('后台任务锁不匹配')
    request = TASKS / (ident + '.request')
    output = TASKS / (ident + '.output')
    errors = TASKS / (ident + '.errors')
    try:
        os.environ['MIHOMO_TASK_ID'] = ident
        payload = json.loads(request.read_text())
        request.unlink()
        job = change(ident, status='running', stage='preparing', percent=2, pid=os.getpid(), message='正在准备更新')
        action = job['action']
        env = dict(os.environ, PLUG_HOME_DIR=str(HOME), MIHOMO_TASK_ID=ident, MIHOMO_TASK_LOCKED='1',
                   PYTHONDONTWRITEBYTECODE='1')
        if action in ('update_provider', 'update_rule_provider'):
            name = payload.get('provider')
            if not isinstance(name, str) or not name or len(name) > 512:
                raise RuntimeError('缺少或无效的提供者名称')
            kind = 'proxies' if action == 'update_provider' else 'rules'
            path = '/providers/' + kind + '/' + urllib.parse.quote(name, safe='')
            progress('activating', 30, '正在更新提供者，请等待内核返回')
            provider = controller('GET', path) if action == 'update_provider' else {'vehicleType':'HTTP'}
            if not isinstance(provider, dict) or not isinstance(provider.get('vehicleType'), str):
                raise RuntimeError('内核返回了无效的提供者状态')
            skipped = provider.get('vehicleType') == 'Compatible'
            if action == 'update_provider' and name in ('APP-MANUAL', 'APP-SUBSCRIPTION') and provider.get('vehicleType') == 'File' and not provider.get('proxies'):
                file = HOME / 'etc/providers' / ('app-manual.yaml' if name == 'APP-MANUAL' else 'app-subscription.yaml')
                try:
                    text = file.read_text()
                    try:
                        parsed = json.loads(text)
                        skipped = isinstance(parsed, dict) and parsed.get('proxies') == []
                    except ValueError:
                        skipped = bool(re.fullmatch(r'\s*proxies:\s*\[\s*\]\s*', text))
                except FileNotFoundError:
                    skipped = False
            if not skipped:
                controller('PUT', path)
            result = {'ok': True, 'provider': name, 'skipped': skipped, 'restarted': False}
        else:
            mapping = {'subscription_update': ('subscription.sh', ['update'], ''),
                       'subscription_import': ('subscription.sh', ['import'], payload.get('url', '')),
                       'geodata_update': ('geodata.sh', ['update'], ''),
                       'geodata_apply_policy': ('geodata.sh', ['apply', payload.get('policy', '')], ''),
                       'rule_provider_import': ('rule-provider.sh', ['import'], json.dumps(payload))}
            script, arguments, body = mapping[action]
            with output.open('wb') as out, errors.open('wb') as err:
                child = subprocess.Popen(['/bin/sh', str(HERE / script), *arguments], stdin=subprocess.PIPE,
                                         stdout=out, stderr=err, env=env, close_fds=True, start_new_session=True)
                try:
                    child.communicate(str(body).encode(), timeout=1200)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGTERM)
                    try:
                        child.wait(timeout=8)
                    except subprocess.TimeoutExpired:
                        os.killpg(child.pid, signal.SIGKILL)
                        child.wait()
                    raise RuntimeError('后台更新超过 20 分钟，已终止；请检查网络后重试') from None
            if child.returncode:
                raise RuntimeError('更新程序异常退出：' + redact(errors.read_text(errors='replace')[-600:]))
            try:
                result = json.loads(output.read_text())
            except ValueError:
                raise RuntimeError('更新程序未返回有效 JSON，请查看当前任务阶段') from None
            if not isinstance(result, dict) or result.get('ok') is not True:
                raise RuntimeError(result.get('error', '更新失败') if isinstance(result, dict) else '更新返回格式异常')
        change(ident, status='succeeded', stage='done', percent=100, message='已完成', result=result, finishedAt=time.time())
    except BaseException as error:
        change(ident, status='failed', stage='failed', error=redact(error), message='更新失败，已保留错误详情', finishedAt=time.time())
    finally:
        for path in (request, output, errors):
            path.unlink(missing_ok=True)
        os.close(fd)


def main():
    os.umask(0o077)
    action = sys.argv[1]
    if action == 'worker':
        worker(sys.argv[2], int(sys.argv[3]))
        return
    if action == 'progress':
        progress(*sys.argv[2:5])
        return
    if action == 'hot':
        result = hot_apply(sys.argv[2])
    elif action == 'controller':
        result = controller(sys.argv[2], sys.argv[3])
    else:
        payload = json.loads(sys.stdin.buffer.read(65537) or b'{}')
        if not isinstance(payload, dict):
            raise RuntimeError('任务参数必须是 JSON 对象')
        result = start(sys.argv[2], payload) if action == 'start' else status(payload.get('id'))
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(json.dumps({'ok': False, 'error': redact(error)}, ensure_ascii=False))
        sys.exit(1)
