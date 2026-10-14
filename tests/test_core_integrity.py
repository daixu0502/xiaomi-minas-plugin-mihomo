"""Exercise real updater success/rollback without network or production state."""
import gzip
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'payload'


def abstract(src):
    return hashlib.sha256(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'\n'
                                  for p in sorted(src.rglob('*')) if p.is_file()).encode()).hexdigest()


@unittest.skipUnless(shutil.which('jq'), 'POSIX shell and jq required')
class CoreIntegrity(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.src = self.home/'src'
        for name in ('src/files', 'scripts', 'etc', 'var', 'mock'):
            (self.home/name).mkdir(parents=True)
        self.write(self.src/'files/core-update.sh', (SOURCE/'files/core-update.sh').read_text())
        self.write(self.src/'files/mihomo', '#!/bin/sh\necho "Mihomo v1.0.0"\n')
        self.write(self.home/'scripts/control', '''#!/bin/sh
case "$1" in
status) test -f "$PLUG_HOME_DIR/var/running";;
stop) rm -f "$PLUG_HOME_DIR/var/running";;
start) if test -f "$PLUG_HOME_DIR/var/fail-once"; then rm "$PLUG_HOME_DIR/var/fail-once"; exit 1; fi; touch "$PLUG_HOME_DIR/var/running";;
esac
''')
        # Random comment padding keeps the archive above the production minimum.
        binary = b'#!/bin/sh\ncase "$1" in -v) echo "Mihomo v1.0.1";; -t) :;; esac\nexit 0\n'
        binary += b'#' + os.urandom(1800000).hex().encode() + b'\n'
        archive = gzip.compress(binary)
        (self.home/'asset.gz').write_bytes(archive)
        asset='mihomo-linux-arm64-v1.0.1.gz'
        (self.home/'release.json').write_text(json.dumps({'tag_name':'v1.0.1','assets':[{
            'name':asset,'browser_download_url':'https://github.com/MetaCubeX/mihomo/releases/download/v1.0.1/'+asset,
            'digest':'sha256:'+hashlib.sha256(archive).hexdigest()}]}))
        self.write(self.home/'mock/curl', '''#!/bin/sh
while test "$#" -gt 0; do case "$1" in --output) out=$2; shift 2;; *) url=$1; shift;; esac; done
case "$url" in *releases/latest) cp "$TEST_HOME/release.json" "$out";; *) cp "$TEST_HOME/asset.gz" "$out";; esac
''')
        self.write(self.home/'mock/file', '#!/bin/sh\necho "ELF 64-bit ARM aarch64"\n')
        self.env=dict(os.environ, PLUG_HOME_DIR=str(self.home), TEST_HOME=str(self.home),
                      PATH=str(self.home/'mock')+':'+os.environ['PATH'])
        (self.home/'etc/config.yaml').write_text('mode: rule\n')

    def write(self, path, text):
        path.write_text(text);path.chmod(0o755)

    def call(self):
        before=abstract(self.src)
        result=subprocess.run(['sh',str(self.src/'files/core-update.sh'),'update'],env=self.env,capture_output=True,text=True,timeout=20)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(abstract(self.src),before)
        return json.loads(result.stdout)

    def test_disabled_update_and_repeat_leave_source_unchanged(self):
        self.assertTrue(self.call()['updated'])
        runtime=self.home/'var/core/mihomo'
        self.assertTrue(runtime.is_file())
        self.assertFalse(self.call()['updated'])
        self.assertFalse((self.home/'var/running').exists())

    def test_start_failure_rolls_back_outside_source(self):
        (self.home/'var/running').touch();(self.home/'var/fail-once').touch()
        self.assertFalse(self.call()['ok'])
        self.assertEqual((self.home/'var/core/mihomo').read_bytes(),(self.src/'files/mihomo').read_bytes())
        self.assertTrue((self.home/'var/running').exists())

    def test_running_update_leaves_source_unchanged(self):
        (self.home/'var/running').touch()
        self.assertTrue(self.call()['updated'])
        self.assertTrue((self.home/'var/running').exists())

    def test_symlink_runtime_directory_cannot_change_source(self):
        (self.home/'var/core').symlink_to(self.src/'files',target_is_directory=True)
        # Force an update rather than using the bundled fallback version.
        self.assertFalse(self.call()['ok'])

    def test_installer_migrates_legacy_core_without_changing_bundled_source(self):
        installer=(SOURCE.parent/'manage.sh').read_text()
        block=installer[installer.index('core_version_of() {'):installer.index('chmod 0755 "$stage_src/files/mihomo"')]
        stage=self.home/'stage';(stage/'files').mkdir(parents=True)
        self.write(stage/'files/mihomo','#!/bin/sh\necho "Mihomo v0.9.0"\n')
        bundled=(stage/'files/mihomo').read_bytes()
        env=dict(self.env,stage_src=str(stage),SRC_DIR=str(self.src),VAR_DIR=str(self.home/'var'))
        result=subprocess.run(['sh','-c', 'fail(){ exit 1; };'+block],env=env,capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual((stage/'files/mihomo').read_bytes(),bundled)
        self.assertEqual((self.home/'var/core/mihomo').read_bytes(),(self.src/'files/mihomo').read_bytes())


class PathCoverage(unittest.TestCase):
    def test_all_core_consumers_prefer_runtime(self):
        names=('mihomo.sh','core-update.sh','geodata.sh','network-access.sh','node.sh','rule-provider.sh','subscription.sh')
        for name in names:
            text=(SOURCE/'files'/name).read_text()
            self.assertIn('BIN="$VAR_DIR/core/mihomo"',text,name)
        self.assertIn('BIN="$VAR_DIR/core/mihomo"',(SOURCE/'ui/mihomo.cgi').read_text())
        installer=(SOURCE.parent/'manage.sh').read_text()
        self.assertNotIn('cp "$existing_core" "$stage_src/files/mihomo"',installer)
        self.assertIn('mv -f "$VAR_DIR/core/.mihomo.migrate.$$" "$VAR_DIR/core/mihomo"',installer)


if __name__=='__main__':
    unittest.main()
