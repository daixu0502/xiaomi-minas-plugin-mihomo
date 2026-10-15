"""Check firmware CGI execution by pathname, UI symlink, and inherited fd.

Run on Linux with --installed-user USER to audit the installed NAS plugins.
Only GET requests are issued; no runtime configuration or services are changed.
"""
import argparse
import os
from pathlib import Path
import subprocess
import shutil
import tempfile
import unittest

PLUGINS = (
    ('docker-manager-plugin', 'dockermanager', 'dockermanager.cgi'),
    ('mihomo-plugin', 'mihomo', 'mihomo.cgi'),
    ('task-center-plugin', 'taskcenter', 'taskcenter.cgi'),
    ('nas-center-plugin', 'nascenter', 'nascenter.cgi'),
    ('ssh-recovery-plugin', 'sshrecovery', 'sshrecovery.cgi'),
    ('quickshare-plugin', 'quickshare', 'quickshare.cgi'),
    ('download-center-plugin', 'downloadcenter', 'downloadcenter.cgi'),
    ('app-nav-plugin', 'appnav', 'appnav.cgi'),
)
ROOT = Path(__file__).resolve().parents[1]
INSTALLED_USER = None


class DescriptorTests(unittest.TestCase):
    def test_static_assets_match_the_source_for_each_execution_method(self):
        tested = 0
        with tempfile.TemporaryDirectory(prefix='cgi-descriptor-') as scratch:
            for folder, name, cgi in PLUGINS:
                ui = (Path('/home') / INSTALLED_USER / 'plugin' / name / 'src/ui'
                      if INSTALLED_USER else ROOT / folder / 'payload/ui')
                if not INSTALLED_USER and not ui.is_dir():ui = ROOT / 'payload/ui'
                if not ui.is_dir():
                    continue
                entry = ui / cgi
                if not entry.is_file():continue
                if not INSTALLED_USER:
                    # Git checkouts may store CGI as 0644; installation makes
                    # them executable. Model that layout without editing source.
                    staged = Path(scratch) / ('source-' + folder)
                    shutil.copytree(ui, staged)
                    for script in staged.glob('*.cgi'):script.chmod(0o755)
                    ui = staged
                    entry = ui / cgi
                tested += 1
                interpreter = '/usr/bin/python3' if entry.read_bytes().startswith(b'#!/usr/bin/env python3') else '/bin/sh'
                alias = Path(scratch) / name
                alias.symlink_to(ui.resolve(), target_is_directory=True)
                for asset in ('index.html', 'app.js', 'client-bridge.js', 'style.css', 'palette.css'):
                    expected = (ui / asset).read_bytes()
                    for method in ('path', 'symlink', 'fd'):
                        with self.subTest(plugin=name, asset=asset, method=method):
                            env = dict(os.environ, REQUEST_METHOD='GET', QUERY_STRING='',
                                       REQUEST_URI='/plugin/123/' + name + '/' + asset)
                            fd = os.open(entry, os.O_RDONLY)
                            try:
                                target = ('/dev/fd/' + str(fd) if method == 'fd' else
                                          str(alias / cgi) if method == 'symlink' else str(entry.resolve()))
                                result = subprocess.run([interpreter, target], env=env, cwd=scratch,
                                                        pass_fds=(fd,), capture_output=True, timeout=20)
                            finally:
                                os.close(fd)
                            self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))
                            self.assertIn(b'\r\n\r\n', result.stdout)
                            self.assertEqual(result.stdout.split(b'\r\n\r\n', 1)[1], expected)
            self.assertGreaterEqual(tested, 1)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--installed-user')
    args, remaining = parser.parse_known_args()
    INSTALLED_USER = args.installed_user
    unittest.main(argv=[__file__] + remaining)
