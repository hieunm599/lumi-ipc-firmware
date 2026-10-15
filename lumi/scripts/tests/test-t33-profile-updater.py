#!/usr/bin/env python3
"""Updater obtains board identity with ipcinfo absent and rejects mismatched SoC."""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[2] / 'overlay/usr/sbin/sysupgrade'

class ProfileUpdater(unittest.TestCase):
    def run_fixture(self, soc):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root/'camera-profile.json').write_text('{}')
            (root/'os-release').write_text('BUILD_PLATFORM='+soc+'_lite\n')
            (root/'cmdline').write_text('root=/dev/mtdblock2')
            cli = root/'lumi-config'
            cli.write_text('#!/bin/sh\ncase "$3" in vendor) echo ingenic;; soc) echo t33;; flash) echo nor;; *) exit 1;; esac\n')
            cli.chmod(0o755)
            function = re.search(r'^get_system_info\(\) \{.*?^\}', SOURCE.read_text(), re.M|re.S).group()
            for path,replacement in [('/lumi/camera-profile.json',root/'camera-profile.json'),('/lumi/bin/lumi-config',cli),('/etc/os-release',root/'os-release'),('/proc/cmdline',root/'cmdline')]:
                function = function.replace(path,str(replacement))
            script = '''die() { echo "$*" >&2; exit 9; }
fw_printenv() { return 1; }
resolve_model_alias() { :; }
get_device() { echo /dev/mtd1; }
get_kernel_version() { echo fixture; }
get_system_version() { echo fixture; }
ipcinfo() { echo 'ipcinfo must not be called' >&2; exit 88; }
''' + function + '\nget_system_info\n[ "$vendor:$model:$flash_type:$root_on_flash" = "ingenic:t33:nor:1" ]\n'
            return subprocess.run(['bash','-c',script],text=True,capture_output=True)

    def test_profile_without_ipcinfo(self):
        result=self.run_fixture('t33'); self.assertEqual(result.returncode,0,result.stderr)
    def test_mismatched_build_rejected(self):
        result=self.run_fixture('rv1106'); self.assertEqual(result.returncode,9)
        self.assertIn('SoC mismatch',result.stderr)

if __name__ == '__main__': unittest.main()
