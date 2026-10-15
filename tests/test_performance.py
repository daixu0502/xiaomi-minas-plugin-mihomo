import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

file=Path(__file__).resolve().parents[1]/'payload/system/docker_proxy_status.py'
spec=importlib.util.spec_from_file_location('probe_perf',file);helper=importlib.util.module_from_spec(spec);spec.loader.exec_module(helper)


class PerformanceTests(unittest.TestCase):
    @unittest.skipUnless(os.geteuid()==0,'root-owned probe cache')
    def test_probe_cache_force_and_expiry(self):
        with tempfile.TemporaryDirectory() as tmp,patch.object(helper,'PROBE_CACHE',Path(tmp)),patch.object(helper,'probe',return_value=(True,'ok')) as probe:
            helper.cached_probe('http://127.0.0.1:12345');helper.cached_probe('http://127.0.0.1:12345')
            self.assertEqual(probe.call_count,1)
            helper.cached_probe('http://127.0.0.1:12345',True);self.assertEqual(probe.call_count,2)
            with patch.object(helper.time,'monotonic',return_value=1e12):helper.cached_probe('http://127.0.0.1:12345')
            self.assertEqual(probe.call_count,3)


if __name__=='__main__':unittest.main()
