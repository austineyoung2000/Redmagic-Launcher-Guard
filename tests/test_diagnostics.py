import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

class Diagnostics(unittest.TestCase):
    def run_action(self, export_available=True):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            module = base / 'module'
            state = base / 'state'
            download = base / 'Download'
            module.mkdir()
            state.mkdir()
            if export_available:
                download.mkdir()
            for name in ['action.sh', 'guard-lib.sh', 'module.prop']:
                (module / name).write_text((ROOT / 'module' / name).read_text())
            (state / 'incident.txt').write_text('BEFORE ACTION: stock Home was foreground\n')
            (state / 'latest.txt').write_text('PRESERVED PRE-RECOVERY EVIDENCE\n')
            (state / 'events.log').write_text('recovery attempt 1\npost-recovery routing: stale\n')
            (state / 'status.txt').write_text('State: failed recovery\nAttempts: 1\n')
            mocks = r'''
getprop() { echo test; }
read_role() { echo org.example.launcher; }
eligible() { GATE_REASON=eligible; return 0; }
target_available() { TARGET_REASON=available; return 0; }
read_routing() { echo 'RAW ROUTING RETAINED'; }
dumpsys() { echo "READ: $*" >> "$STATE/commands"; echo 'topResumedActivity=ActivityRecord{123 u0 org.kernelsu/.ActionActivity t7}'; }
pidof() { return 1; }
'''
            with (module / 'guard-lib.sh').open('a') as f:
                f.write(mocks)
            action = (module / 'action.sh').read_text()
            action = action.replace('PATH=/system/bin:/system/xbin', 'PATH=/usr/bin:/bin')
            action = action.replace('STATE=/data/adb/redmagic_launcher_guard', f'STATE={state}')
            action = action.replace('DOWNLOAD_REPORT=/sdcard/Download/redmagic-launcher-guard-report.txt', f'DOWNLOAD_REPORT={download}/redmagic-launcher-guard-report.txt')
            (module / 'action.sh').write_text(action)
            result = subprocess.run(['sh', str(module / 'action.sh')], capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            private = (state / 'manual-latest.txt').read_text()
            self.assertIn('=== END OF SUPPORT REPORT ===', private)
            self.assertIn('BEFORE ACTION: stock Home was foreground', private)
            self.assertIn('org.kernelsu/.ActionActivity', private)
            self.assertIn('PRESERVED PRE-RECOVERY EVIDENCE', private)
            self.assertIn('post-recovery routing: stale', private)
            self.assertIn('RAW ROUTING RETAINED', private)
            self.assertEqual((state / 'incident.txt').read_text(), 'BEFORE ACTION: stock Home was foreground\n')
            self.assertEqual((state / 'latest.txt').read_text(), 'PRESERVED PRE-RECOVERY EVIDENCE\n')
            self.assertEqual((state / 'manual-latest.txt').stat().st_mode & 0o777, 0o600)
            self.assertNotIn('force-stop', (state / 'commands').read_text())
            if export_available:
                public = download / 'redmagic-launcher-guard-report.txt'
                self.assertEqual(public.read_text(), private)
                self.assertIn('REPORT SAVED:', result.stdout)
            else:
                self.assertIn('Could not export to Download', result.stdout)
                self.assertNotIn('REPORT SAVED:', result.stdout)

    def test_action_exports_evidence_without_changing_launcher_or_previous_capture(self):
        self.run_action()

    def test_unavailable_shared_storage_preserves_private_report(self):
        self.run_action(export_available=False)

    def test_automatic_incident_rate_limit_and_retention(self):
        with tempfile.TemporaryDirectory() as temp:
            script = r'''
. "$1"
STATE=$2
NOW=1000
uptime_seconds() { echo "$NOW"; }
read_role() { echo org.example.launcher; }
dumpsys() { echo 'topResumedActivity=stock Home'; }
log_event() { echo "$*" >> "$STATE/events.log"; }
remember_incident 'initial stale' 'FIRST ROUTING'
NOW=1005
remember_incident 'repeat poll' 'SHOULD NOT OVERWRITE'
NOW=1600
remember_incident 'later stale' 'SECOND ROUTING'
'''
            result = subprocess.run(['sh', '-c', script, 'test', str(ROOT / 'module/guard-lib.sh'), temp], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            latest = (Path(temp) / 'incident.txt').read_text()
            previous = (Path(temp) / 'incident.previous.txt').read_text()
            self.assertIn('SECOND ROUTING', latest)
            self.assertIn('FIRST ROUTING', previous)
            self.assertNotIn('SHOULD NOT OVERWRITE', latest + previous)
            self.assertEqual((Path(temp) / 'events.log').read_text().count('snapshot retained'), 2)

if __name__ == '__main__':
    unittest.main()
