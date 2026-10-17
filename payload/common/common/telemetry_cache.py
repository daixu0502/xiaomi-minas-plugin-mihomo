"""Disposable root-only telemetry cache in tmpfs; never an authorization source."""
import fcntl
import json
import math
import os
from pathlib import Path
import re
import stat
import tempfile
import time

ROOT = Path('/run/minas-telemetry-cache')


def directory():
    if os.geteuid() != 0:
        raise PermissionError('root-only telemetry cache')
    ROOT.mkdir(mode=0o700, exist_ok=True)
    metadata = ROOT.lstat()
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != 0 or metadata.st_mode & 0o077:
        raise PermissionError('unsafe telemetry cache directory')
    return ROOT


def filename(key):
    if not re.fullmatch(r'[a-zA-Z0-9_.-]{1,120}', key):
        raise ValueError('invalid telemetry cache key')
    return directory() / (key + '.json')


def read(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, 'rb') as stream:
            metadata = os.fstat(stream.fileno())
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != 0 or metadata.st_mode & 0o077 or metadata.st_size > 1048576:
                return None
            result = json.load(stream)
        return result if (isinstance(result, dict) and 'value' in result and
                          type(result.get('at')) in (int,float) and math.isfinite(result['at'])) else None
    except (OSError, ValueError):
        return None


def cached(key, ttl, loader, force=False):
    try:
        path = filename(key)
    except OSError:
        return loader()
    previous = read(path)
    if not force and previous and 0 <= time.monotonic() - previous.get('at', -1e20) < ttl:
        return previous['value']
    fd = os.open(path.with_suffix('.lock'), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        metadata = os.fstat(fd)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != 0 or metadata.st_mode & 0o077:
            raise PermissionError('unsafe telemetry cache lock')
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            # Another reader refreshes this display-only value. Never wait on it.
            if not force and previous and 0 <= time.monotonic() - previous.get('at', -1e20) < max(ttl * 3, 120):
                return previous['value']
            return loader()
        previous = read(path)
        if not force and previous and 0 <= time.monotonic() - previous.get('at', -1e20) < ttl:
            return previous['value']
        value = loader()  # Exceptions never overwrite a successful sample.
        temp_fd, temp = tempfile.mkstemp(prefix='.telemetry-', dir=path.parent)
        try:
            with os.fdopen(temp_fd, 'w') as stream:
                json.dump({'at': time.monotonic(), 'value': value}, stream)
            os.replace(temp, path)
        finally:
            if os.path.exists(temp): os.unlink(temp)
        return value
    finally:
        os.close(fd)


def invalidate(key):
    try:
        filename(key).unlink(missing_ok=True)
    except OSError:
        pass
