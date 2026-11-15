import subprocess
import tempfile
import unittest
from pathlib import Path
from test_guard import ROOT, LIB, STOCK, RECENTS, routing

VENDOR='com.vendor.redmagic.home'
HOME=VENDOR+'/com.vendor.redmagic.home.HomeScreen'
OVERVIEW=VENDOR+'/com.vendor.redmagic.home.OverviewScreen'
SERVICE=VENDOR+'/com.vendor.redmagic.home.GestureService'

def package_dump(package=VENDOR):
    return f'''Activity Resolver Table:
  Non-Data Actions:
    android.intent.action.MAIN:
      abc {package}/.HomeScreen filter 123
        Action: "android.intent.action.MAIN"
        Category: "android.intent.category.HOME"
Service Resolver Table:
  Non-Data Actions:
    android.intent.action.QUICKSTEP_SERVICE:
      def {package}/.GestureService filter 456
        Action: "android.intent.action.QUICKSTEP_SERVICE"
Packages:
  Package [{package}] (123):
    pkgFlags=[ SYSTEM HAS_CODE ALLOW_CLEAR_USER_DATA ]
'''

class Compatibility(unittest.TestCase):
    def discovered(self, package, recents, body):
        with tempfile.TemporaryDirectory() as temp:
            base=Path(temp)
            (base/'package').write_text(package)
            (base/'sysui').write_text('mRecentsComponentName=ComponentInfo{'+recents+'}\n')
            script=r'''
. "$1"
TESTDIR=$2
dumpsys() {
 case "$*" in
  "-t 5 activity service com.android.systemui/.SystemUIService") cat "$TESTDIR/sysui";;
  "-t 4 package "*) cat "$TESTDIR/package";;
 esac
}
detect_stock_launcher
'''+body
            return subprocess.run(['sh','-c',script,'test',str(LIB),temp],capture_output=True,text=True,check=True).stdout.strip()

    def test_dynamic_system_launcher_components(self):
        self.assertEqual(self.discovered(package_dump(),OVERVIEW,'printf "%s\\n" "$DETECTION_MODE" "$STOCK" "$STOCK_HOME" "$STOCK_RECENTS" "$SERVICE"'), '\n'.join(['discovered',VENDOR,HOME,OVERVIEW,SERVICE]))
        body="printf '%s\\n' '"+routing(HOME,HOME,'true')+"' | routing_state"
        self.assertEqual(self.discovered(package_dump(),OVERVIEW,body),'stale')
        body="printf '%s\\n' '"+routing('org.any.launcher/.Home',OVERVIEW)+"' | routing_state"
        self.assertEqual(self.discovered(package_dump(),OVERVIEW,body),'healthy')
        body="printf '%s\\n' 'topResumedActivity=ActivityRecord{1 u0 "+VENDOR+"/.HomeScreen t2}' | stock_home_foreground; echo $?"
        self.assertEqual(self.discovered(package_dump(),OVERVIEW,body),'0')

    def test_discovered_known_launcher_keeps_original_stale_and_healthy_detection(self):
        package='com.zte.mifavor.launcher'
        dump=package_dump(package).replace('/.HomeScreen','/com.android.launcher3.uioverrides.QuickstepLauncher').replace('/.GestureService','/com.android.quickstep.TouchInteractionService')
        for data, expected in [(routing(STOCK,STOCK,'true'),'stale'),(routing('com.teslacoilsw.launcher/.NovaLauncher',RECENTS),'healthy')]:
            body="printf '%s\\n' '"+data+"' | routing_state"
            self.assertEqual(self.discovered(dump,RECENTS,body),expected)

    def test_unrecognized_or_non_system_discovery_keeps_verified_automatic_recovery(self):
        cases=['',package_dump().replace('SYSTEM ','UPDATED_SYSTEM_APP '),package_dump().replace('android.intent.category.HOME','unknown.HOME'),package_dump().replace('android.intent.action.QUICKSTEP_SERVICE','unknown.SERVICE')]
        for dump in cases:
            body='echo "$DETECTION_MODE"; '+"printf '%s\\n' '"+routing(STOCK,STOCK,'true')+"' | routing_state"
            self.assertEqual(self.discovered(dump,OVERVIEW,body),'verified-fallback\nstale')

    def test_ambiguous_home_does_not_replace_known_recovery(self):
        extra='''      second com.vendor.redmagic.home/.OtherHome filter 789
        Category: "android.intent.category.HOME"
'''
        dump=package_dump().replace('Service Resolver Table:',extra+'Service Resolver Table:')
        self.assertEqual(self.discovered(dump,OVERVIEW,'echo "$DETECTION_MODE"'),'verified-fallback')

    def test_install_allows_other_sdk_versions_on_nx809j(self):
        for sdk in [30,35,36,37,38]:
            script=r'''
MODPATH=$1
SDK=$2
getprop() { case "$1" in ro.product.model) echo NX809J;; ro.build.version.sdk) echo "$SDK";; esac; }
abort() { echo "ABORT: $*"; exit 99; }
ui_print() { :; }
set_perm_recursive() { :; }
set_perm() { :; }
. "$MODPATH/customize.sh"
'''
            p=subprocess.run(['sh','-c',script,'test',str(ROOT/'module'),str(sdk)],capture_output=True,text=True)
            self.assertEqual(p.returncode,0,p.stdout+p.stderr)

    def test_other_device_rejected(self):
        p=subprocess.run(['sh','-c','. "$1"; getprop() { echo NX999J; }; is_redmagic11pro','test',str(LIB)],capture_output=True,text=True)
        self.assertNotEqual(p.returncode,0)

if __name__=='__main__': unittest.main()
