"""Disposable user-owned telemetry in official plugintmp; never authorization."""
import math
import re
import time

from user_state_io import read_state, write_state, state_lock
import hashlib
import subprocess

USER = None


def configure(user):
    global USER
    if not re.fullmatch(r'u[0-9]+', user or ''):raise ValueError('invalid cache user')
    USER = user


def cached(key, ttl, loader, force=False):
    # API-v1 callers installed before per-user caches do not call configure().
    # They must keep working when another plugin upgrades only the shared code.
    # No guessed user or root-owned fallback cache: just sample live telemetry.
    if USER is None:
        return loader()
    name = cache_name(key)
    def previous():
        try:
            value = read_state(USER, 'nascenter', name + '.json')
            if (isinstance(value,dict) and 'value' in value and type(value.get('at')) in (int,float)
                    and math.isfinite(value['at']) and 0 <= time.time()-value['at'] < ttl):
                return value
        except (OSError,ValueError,subprocess.SubprocessError):pass
    if not force:
        old = previous()
        if old is not None:return old['value']
    with state_lock(USER,'nascenter',name+'.lock') as locked:
        if locked and not force:
            old = previous()
            if old is not None:return old['value']
        value = loader()
        if locked:
            try:write_state(USER,'nascenter',name+'.json',{'at':time.time(),'value':value})
            except (OSError,ValueError,subprocess.SubprocessError):pass
        return value


def cache_name(key):
    if not re.fullmatch(r'[a-zA-Z0-9_.-]{1,120}',key):raise ValueError('invalid telemetry key')
    return 'telemetry-'+hashlib.sha256(key.encode()).hexdigest()[:32]


def invalidate(key):
    try:
        write_state(USER,'nascenter',cache_name(key)+'.json',{'at':0})
    except (OSError,ValueError,subprocess.SubprocessError):
        pass
