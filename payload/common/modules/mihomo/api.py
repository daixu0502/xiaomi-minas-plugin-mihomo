"""Narrow registered-user Docker proxy API; never accepts arbitrary ports/commands."""
import json
import os
from pathlib import Path
import subprocess
import privileged_runtime as runtime

ACTIONS = {'docker_proxy_status':'status', 'docker_proxy_enable':'enable', 'docker_proxy_disable':'disable'}

def api(user, request):
    runtime.authorize(user, 'mihomo')
    action = ACTIONS.get(request.get('action'))
    if action is None:
        raise ValueError('未知 Docker 代理操作')
    port = runtime.registry().get('settings', {}).get(user, {}).get('mihomo', {}).get('proxyPort')
    if type(port) is not int or not 1024 <= port <= 65535:
        raise ValueError('Docker 代理端口尚未由安装器登记，请重新安装插件')
    if 'port' in request and (type(request['port']) is not int or request['port'] != port):
        raise ValueError('不能操作其他插件端口')
    force = request.get('force', False)
    if type(force) is not bool:
        raise ValueError('无效检测参数')
    args = ['/bin/sh', str(Path(__file__).with_name('mihomo-docker-proxy')), action, str(port)]
    if action == 'status' and force:
        args.append('fresh')
    def invoke():
        env = {'PATH':'/data/docker:/usr/sbin:/usr/bin:/sbin:/bin', 'LC_ALL':'C.UTF-8', 'PYTHONDONTWRITEBYTECODE':'1', 'MINAS_CACHE_USER':user}
        result = subprocess.run(args, input='', capture_output=True, text=True, env=env, timeout=110)
        if result.returncode:
            raise ValueError('Docker 代理助手执行失败')
        value = json.loads(result.stdout)
        if not isinstance(value, dict):
            raise ValueError('Docker 代理助手返回无效数据')
        return value
    if action == 'status':
        return invoke()
    with runtime.docker_transaction():
        return invoke()
