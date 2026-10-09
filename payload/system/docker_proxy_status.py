"""Read-only Docker proxy diagnostics. Never restart services or expose credentials."""
import json
import socket
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import urlsplit

DROPIN = Path('/etc/systemd/system/docker.service.d/90-mihomo-proxy.conf')


def run(args, timeout=2):
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout, check=True).stdout


def service():
    raw = run(['systemctl', 'show', 'docker.service', '-p', 'LoadState', '-p', 'ActiveState', '-p', 'MainPID'])
    return dict(line.split('=', 1) for line in raw.splitlines() if '=' in line)


def runtime_proxy():
    # Values reported by the live daemon also honor daemon.json proxy overrides.
    fmt = '{{json .HTTPProxy}}\n{{json .HTTPSProxy}}\n{{json .NoProxy}}'
    values = run(['/data/docker/docker', '-H', 'unix:///var/run/docker.sock', 'info', '--format', fmt]).splitlines()
    if len(values) != 3:
        raise ValueError('unexpected daemon response')
    return [json.loads(value) or '' for value in values]


def matches(value, port):
    try:
        url = urlsplit(value)
        return (url.scheme == 'http' and url.hostname == '127.0.0.1' and url.port == port
                and not url.username and not url.password and url.path in ('', '/')
                and not url.query and not url.fragment)
    except ValueError:
        return False


def bypasses_registry(value):
    for entry in value.lower().split(','):
        entry = entry.strip()
        if entry == '*':
            return True
        host = entry.split(':', 1)[0].lstrip('*.')
        if host and any(domain == host or domain.endswith('.' + host)
                        for domain in ('registry-1.docker.io', 'auth.docker.io')):
            return True
    return False


def listening(port):
    try:
        with socket.create_connection(('127.0.0.1', port), timeout=.5):
            return True
    except OSError:
        return False


def probe(proxy):
    try:
        response = run(['curl', '-q', '-sS', '--proxy', proxy, '--noproxy', '',
                        '--connect-timeout', '2', '--max-time', '5',
                        '--dump-header', '-', '--output', '/dev/null',
                        '--write-out', '\nSTATUS:%{http_code}',
                        'https://registry-1.docker.io/v2/'], timeout=6)
        status = response.rsplit('STATUS:', 1)[-1].strip()
        if status in ('200', '401') and 'docker-distribution-api-version: registry/2.0' in response.lower():
            return True, 'ok'
        return False, 'http_error'
    except FileNotFoundError:
        return None, 'probe_unavailable'
    except (subprocess.SubprocessError, OSError):
        return False, 'upstream_failed'


def status(port):
    proxy = 'http://127.0.0.1:' + str(port)
    try:
        config = DROPIN.read_text()
        present = True
    except FileNotFoundError:
        config, present = '', False
    assignments = {line.strip() for line in config.splitlines()}
    configured = all('Environment="' + key + '=' + proxy + '"' in assignments for key in ('HTTP_PROXY', 'HTTPS_PROXY'))
    result = dict(ok=True, available=False, enabled=configured, configured=configured,
                  configuredElsewhere=present and not configured, dockerActive=False,
                  runtimeKnown=False, effective=False, runtimeUsesProxy=False, registryBypassed=False,
                  mihomoListening=False, proxyReachable=None, probeStatus='not_checked', proxy=proxy,
                  state='unavailable', checkedAt=int(time.time()))
    try:
        current = service()
        result['available'] = current.get('LoadState') == 'loaded'
        result['dockerActive'] = current.get('ActiveState') == 'active'
        if result['dockerActive']:
            http, https, no_proxy = runtime_proxy()
            http_matches, https_matches = matches(http, port), matches(https, port)
            uses = http_matches or https_matches
            bypass = bypasses_registry(no_proxy)
            # Refuse to present a sample from a daemon that restarted during inspection.
            if current.get('MainPID') != service().get('MainPID'):
                raise ValueError('daemon changed')
            result.update(runtimeKnown=True, runtimeUsesProxy=uses, registryBypassed=bypass,
                          effective=http_matches and https_matches and not bypass)
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    result['mihomoListening'] = listening(port)
    if configured or result['runtimeUsesProxy']:
        if result['mihomoListening']:
            result['proxyReachable'], result['probeStatus'] = probe(proxy)
        else:
            result.update(proxyReachable=False, probeStatus='not_listening')
    if not result['available']:
        state = 'unavailable'
    elif not result['dockerActive']:
        state = 'docker_stopped'
    elif not result['runtimeKnown']:
        state = 'unknown'
    elif result['runtimeUsesProxy'] and not configured:
        state = 'pending_disable'
    elif not configured:
        state = 'disabled'
    elif not result['effective']:
        state = 'bypassed' if result['runtimeUsesProxy'] and result['registryBypassed'] else 'pending_apply'
    elif result['proxyReachable'] is False:
        state = 'unreachable' if result['probeStatus'] == 'not_listening' else 'upstream_failed'
    elif result['proxyReachable'] is None:
        state = 'probe_unknown'
    else:
        state = 'effective'
    result['state'] = state
    return result


if __name__ == '__main__':
    port = int(sys.argv[1])
    if not 1024 <= port <= 65535:
        print(json.dumps(dict(ok=False, error='代理端口无效')))
    else:
        print(json.dumps(status(port), ensure_ascii=False))
