#!/usr/bin/python3
"""Stable root installer entry; implementation is grouped under common/."""
import sys
from pathlib import Path
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent/'common'))
from component_admin import main
if __name__ == '__main__':
    try: main()
    except Exception as error:
        print('公共权限组件安装/卸载失败：%s' % error, file=sys.stderr)
        sys.exit(1)
