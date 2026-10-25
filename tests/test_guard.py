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

    def test_android_pretty_printed_roles_with_trailing_empty_roles(self):
        xml = """<?xml version='1.0' encoding='UTF-8' standalone='yes' ?>
<roles version="1" packagesHash="synthetic">
  <role name="android.app.role.BROWSER" fallbackEnabled="true">
    <holder name="org.example.browser" />
  </role>
  <role name="android.app.role.HOME" fallbackEnabled="true">
    <holder name="org.example.launcher" />
  </role>
  <role name="android.app.role.RESERVED_FOR_TESTING_PROFILE_GROUP_EXCLUSIVITY" fallbackEnabled="true" activeUserId="0" />
  <role name="android.app.role.SYSTEM_VENDOR_INTELLIGENCE" fallbackEnabled="true" />
</roles>"""
        for text in [xml, xml.replace('\n', '\r\n'), xml.replace('\n', '   ')]:
            self.assertEqual(parse('role_holder', text).stdout.strip(), 'org.example.launcher')

    def test_missing_empty_duplicate_or_unclosed_home_is_unknown(self):
        for xml in [
            '<roles><role name="android.app.role.HOME" /></roles>',
            '<roles><role name="android.app.role.HOME"><holder name="org.example"/></role><role name="android.app.role.HOME"><holder name="org.other"/></role></roles>',
            '<roles><role name="android.app.role.HOME"><holder name="org.example"/></roles>',
        ]:
            self.assertEqual(parse('role_holder', xml).stdout.strip(), '')

    def test_focus_recents_is_not_home(self):
        self.assertEqual(parse('stock_home_foreground', 'topResumedActivity=ActivityRecord{123 u0 ' + STOCK + ' t2}').returncode, 0)
        for component in [RECENTS, 'com.example/.Home', '']:
            self.assertNotEqual(parse('stock_home_foreground', 'topResumedActivity=ActivityRecord{123 u0 ' + component + ' t2}').returncode, 0)

    def test_keyguard_unknown_or_locked_blocks(self):
        self.assertEqual(parse('keyguard_clear', 'mKeyguardDelegate\n  showing=false\n').returncode, 0)
        for dump in ['', 'showing=false', 'mKeyguardDelegate\n  showing=true\n']:
            self.assertNotEqual(parse('keyguard_clear', dump).returncode, 0)

class DeviceGateParsers(unittest.TestCase):
    def test_redmagic_keyguard_label(self):
        self.assertEqual(parse('keyguard_clear', '    KeyguardServiceDelegate\n      showing=false\n      inputRestricted=false\n').returncode, 0)
        for data in ['    KeyguardServiceDelegate\n      showing=true\n', 'KeyguardServiceDelegate\n  occluded=false\n']:
            self.assertNotEqual(parse('keyguard_clear', data).returncode, 0)

    def test_current_owner_and_unlock_state(self):
        unlocked = 'Current user: 0\nUsers:\n  UserInfo{0:null:4c13} serialNo=0\n    State: RUNNING_UNLOCKED\n  UserInfo{10:Work:30} serialNo=10\n    State: RUNNING_LOCKED\n'
        self.assertEqual(parse('user_zero_unlocked', unlocked).returncode, 0)
        for data in [unlocked.replace('Current user: 0', 'Current user: 10'), unlocked.replace('State: RUNNING_UNLOCKED', 'State: RUNNING_LOCKED'), 'cmd: Failure calling service activity: Failed transaction (2147483646)', '', unlocked.replace('Current user: 0', '')]:
            self.assertNotEqual(parse('user_zero_unlocked', data).returncode, 0)

    def test_actual_eligibility_function_on_redmagic_dump_format(self):
        script = r''' . "$1"
BASE_HOLDER=org.example.launcher
active_module() { return 0; }
getprop() { echo 1; }
uptime_seconds() { echo 1000; }
read_role() { echo org.example.launcher; }
dumpsys() {
 case "$*" in
  "-t 3 power") echo '  mWakefulness=Awake';;
  "-t 3 user") printf 'Current user: 0\nUsers:\n  UserInfo{0:null:4c13} serialNo=0\n    State: RUNNING_UNLOCKED\n';;
  "-t 3 window policy") printf '    KeyguardServiceDelegate\n      showing=false\n';;
  *) return 1;;
 esac
}
eligible
code=$?
echo "$GATE_REASON"
exit "$code"
'''
        p = subprocess.run(['sh', '-c', script, 'test', str(LIB)], capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual(p.stdout.strip(), 'eligible')
        cases = [
            (script.replace('mWakefulness=Awake', 'mWakefulness=Asleep'), 'screen not awake'),
            (script.replace('Current user: 0', 'Current user: 10'), 'current user is not unlocked user 0'),
            (script.replace('RUNNING_UNLOCKED', 'RUNNING_LOCKED'), 'current user is not unlocked user 0'),
            (script.replace('showing=false', 'showing=true'), 'keyguard showing'),
            (script.replace('KeyguardServiceDelegate', 'UnknownPolicySection'), 'keyguard showing'),
            (script.replace('uptime_seconds() { echo 1000;', 'uptime_seconds() { echo 30;'), 'startup grace period'),
            (script.replace('read_role() { echo org.example.launcher;', 'read_role() { echo org.other.launcher;'), 'saved Home changed'),
        ]
        for body, reason in cases:
            with self.subTest(reason=reason):
                blocked = subprocess.run(['sh', '-c', body, 'test', str(LIB)], capture_output=True, text=True)
                self.assertNotEqual(blocked.returncode, 0)
                self.assertIn(reason, blocked.stdout)

    def test_target_package_state(self):
        valid = '    User 0: installed=true hidden=false suspended=false stopped=false enabled=0 quarantined=false'
        for data, accepted in [(valid, True), (valid.replace('enabled=0', 'enabled=1'), True), (valid.replace('installed=true', 'installed=false'), False), (valid.replace('enabled=0', 'enabled=2'), False), (valid.replace('suspended=false', 'suspended=true'), False), (valid.replace('hidden=false', 'hidden=true'), False), (valid.replace('quarantined=false', 'quarantined=true'), False), ('Failed transaction', False)]:
            script = '. "$1"; dumpsys() { printf "%s\\n" "$SAMPLE"; }; BASE_HOLDER=org.example.launcher; target_available'
            p = subprocess.run(['sh', '-c', script, 'test', str(LIB)], env={'SAMPLE': data, 'PATH':'/usr/bin:/bin'}, capture_output=True, text=True)
            self.assertEqual(p.returncode == 0, accepted, data + p.stderr)

class FullPackageDump(unittest.TestCase):
    def test_other_user_headings_do_not_override_install_state(self):
        data = """Packages:
  Package [org.example.launcher] (123):
    User 0: ceDataInode=123 deDataInode=456 installed=true hidden=false suspended=false distractionFlags=0 stopped=false notLaunched=false enabled=0 instant=false virtual=false quarantined=false
    User 10: installed=false hidden=false suspended=false enabled=2
Queries:
  queryable via interaction:
    User 0:
      org.example.other:
        org.example.launcher
    User 10:
      org.example.work:
        org.example.launcher
"""
        self.assertEqual(parse('package_state', data).stdout.strip(), 'available')
        for flags in ['installed=false', 'hidden=true', 'suspended=true', 'enabled=2', 'quarantined=true']:
            key = flags.split('=')[0]
            import re
            changed = re.sub(r'(?<= )' + key + r'=[^ \n]+', flags, data, count=1)
            self.assertEqual(parse('package_state', changed).stdout.strip(), 'unavailable')

    def test_unknown_is_not_reported_as_disabled(self):
        for data in ['', 'Failed transaction (2147483646)', '    User 0:', '    User 0: installed=true', '    User 0: installed=true hidden=false suspended=false enabled=0\n    User 0: installed=true hidden=false suspended=false enabled=0']:
            self.assertEqual(parse('package_state', data).stdout.strip(), 'unknown')

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
 if [ "$SCENARIO" = role_change ] && [ "$t" -ge 3 ]; then echo org.launcher.t$t; else echo org.example.launcher; fi
}
eligible() { [ "$SCENARIO" != locked ] && [ "$(read_role)" = "$BASE_HOLDER" ]; }
foreground_ok() { [ "$SCENARIO" != other_app ]; }
target_available() { [ "$SCENARIO" != missing_target ]; }
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
        self.assertIn('healthy Home component observed: org.example.launcher/.Home', events)
        self.assertIn('am start --user 0 -n org.example.launcher/.Home', events)
        self.assertLess(events.index('capture'), events.index('am force-stop'))

    def test_stale_from_startup_uses_selected_package_home(self):
        events = self.run_scenario('no_baseline')
        self.assertEqual(events.count('am force-stop'), 1)
        self.assertIn('am start --user 0 -a android.intent.action.MAIN -c android.intent.category.HOME -p org.example.launcher', events)
        self.assertNotIn('-n ', events)

    def test_no_restart_for_normal_transient_unknown_changed_or_locked_state(self):
        for scenario in ['healthy', 'transient', 'unknown', 'role_change', 'locked', 'other_app', 'missing_target']:
            with self.subTest(scenario=scenario):
                self.assertNotIn('am force-stop', self.run_scenario(scenario))

if __name__ == '__main__':
    unittest.main()
