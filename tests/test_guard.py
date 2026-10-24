import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LIB = ROOT / 'module/guard-lib.sh'
STOCK = 'com.zte.mifavor.launcher/com.android.launcher3.uioverrides.QuickstepLauncher'
RECENTS = 'com.zte.mifavor.launcher/com.android.quickstep.RecentsActivity'

def routing(home, overview=RECENTS, same='false', default='false', disabled='false'):
    return f'''OverviewComponentObserver:
  isDefaultHome={default}
  isHomeDisabled={disabled}
  homeAndOverviewSame={same}
  overviewIntent=Intent {{ cmp={overview} }}
  homeIntent=Intent {{ cmp={home} }}
'''

def parse(function, data):
    return subprocess.run(['sh', '-c', '. "$1"; ' + function, 'test', str(LIB)], input=data, text=True, capture_output=True)

class Parsers(unittest.TestCase):
    def test_observed_healthy_and_stale(self):
        self.assertEqual(parse('routing_state', routing('com.teslacoilsw.launcher/.NovaLauncher')).stdout.strip(), 'healthy')
        self.assertEqual(parse('routing_state', routing(STOCK, STOCK, 'true')).stdout.strip(), 'stale')

    def test_launcher_independent(self):
        for component in ['app.lawnchair/.LawnchairLauncher', 'org.example.launcher/org.example.HomeActivity', 'com.example.launcher/.Home$Main']:
            dump = routing(component)
            self.assertEqual(parse('routing_state', dump).stdout.strip(), 'healthy')
            self.assertEqual(parse('home_component', dump).stdout.strip(), component)

    def test_unknown_never_authorizes(self):
        for dump in ['', 'Failed transaction (2147483646)', routing(STOCK, STOCK, 'true', 'true'), routing(STOCK, STOCK, 'true', disabled='true'), routing('android/.ResolverActivity', STOCK)]:
            self.assertEqual(parse('routing_state', dump).stdout.strip(), 'unknown')

    def test_role_xml_and_ambiguity(self):
        for newline in ['', '\n', '\r\n']:
            xml = newline.join(['<roles>', '<role name="android.app.role.BROWSER"><holder name="com.other" /></role>', '<role name="android.app.role.HOME" fallbackEnabled="true">', '<holder name="org.example.launcher" />', '</role>', '</roles>'])
            self.assertEqual(parse('role_holder', xml).stdout.strip(), 'org.example.launcher')
        for xml in ['', '<roles/>', '<role name="android.app.role.HOME"><holder name="a"/><holder name="b"/></role>']:
            self.assertEqual(parse('role_holder', xml).stdout.strip(), '')

    def test_focus_recents_is_not_home(self):
        self.assertEqual(parse('stock_home_foreground', 'topResumedActivity=ActivityRecord{123 u0 ' + STOCK + ' t2}').returncode, 0)
        for component in [RECENTS, 'com.example/.Home', '']:
            self.assertNotEqual(parse('stock_home_foreground', 'topResumedActivity=ActivityRecord{123 u0 ' + component + ' t2}').returncode, 0)

    def test_keyguard_unknown_or_locked_blocks(self):
        self.assertEqual(parse('keyguard_clear', 'mKeyguardDelegate\n  showing=false\n').returncode, 0)
        for dump in ['', 'showing=false', 'mKeyguardDelegate\n  showing=true\n']:
            self.assertNotEqual(parse('keyguard_clear', dump).returncode, 0)

class Monitor(unittest.TestCase):
    def run_scenario(self, scenario):
        # Run the actual service loop with external Android I/O replaced. No real
        # am, dumpsys, root paths, or sleeps are reachable in this harness.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'guard-lib.sh').write_text(LIB.read_text() + r'''
getprop() { case "$1" in ro.product.model) echo NX809J;; ro.build.version.sdk) echo 36;; esac; }
log_event() { echo "$*" >> "$MODDIR/events"; }
active_module() { [ "$(cat "$MODDIR/tick" 2>/dev/null || echo 0)" -lt 12 ]; }
sleep() { tick=$(cat "$MODDIR/tick" 2>/dev/null || echo 0); echo $((tick+1)) > "$MODDIR/tick"; }
read_role() {
 t=$(cat "$MODDIR/tick")
 if [ "$SCENARIO" = role_change ] && [ "$t" -ge 3 ]; then echo org.other.launcher; else echo org.example.launcher; fi
}
eligible() { [ "$SCENARIO" != locked ] && [ "$(read_role)" = "$BASE_HOLDER" ]; }
foreground_ok() { [ "$SCENARIO" != other_app ]; }
uptime_seconds() { echo 1000; }
read_routing() {
 t=$(cat "$MODDIR/tick")
 if [ "$SCENARIO" = unknown ]; then echo 'Failed transaction'; return; fi
 if [ "$SCENARIO" = healthy ] || { [ "$t" = 1 ] && [ "$SCENARIO" != no_baseline ]; } || { [ "$SCENARIO" = transient ] && [ "$t" -ge 3 ]; }; then
   cat "$MODDIR/healthy"
 else cat "$MODDIR/stale"; fi
}
capture() { echo capture >> "$MODDIR/events"; }
timeout() { shift; shift; echo "am $*" >> "$MODDIR/events"; }
dumpsys() { echo 'topResumedActivity=ActivityRecord{123 u0 com.zte.mifavor.launcher/com.android.launcher3.uioverrides.QuickstepLauncher t2}'; }
''')
            (root / 'healthy').write_text(routing('org.example.launcher/.Home'))
            (root / 'stale').write_text(routing(STOCK, STOCK, 'true'))
            service = (ROOT / 'module/service.sh').read_text()
            service = service.replace('PATH=/system/bin:/system/xbin', 'PATH=/usr/bin:/bin')
            service = service.replace('STATE=/data/adb/redmagic_launcher_guard', 'STATE=$MODDIR/state').replace('LOCK=/dev/.redmagic_launcher_guard.lock', 'LOCK=$MODDIR/lock')
            # Fake timeout ignores the absolute am path; its body only records args.
            (root / 'service.sh').write_text(service)
            p = subprocess.run(['sh', str(root / 'service.sh')], env={'SCENARIO': scenario, 'PATH': '/usr/bin:/bin'}, capture_output=True, text=True, timeout=5)
            self.assertEqual(p.returncode, 0, p.stderr)
            return (root / 'events').read_text()

    def test_only_persistent_stale_recovers(self):
        events = self.run_scenario('stale')
        self.assertEqual(events.count('am force-stop'), 1)
        self.assertIn('am start --user 0 -n org.example.launcher/.Home', events)
        self.assertLess(events.index('capture'), events.index('am force-stop'))

    def test_no_restart_for_normal_transient_unknown_changed_or_locked_state(self):
        for scenario in ['healthy', 'transient', 'unknown', 'role_change', 'no_baseline', 'locked', 'other_app']:
            with self.subTest(scenario=scenario):
                self.assertNotIn('am force-stop', self.run_scenario(scenario))

if __name__ == '__main__':
    unittest.main()
