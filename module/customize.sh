#!/system/bin/sh
[ "$(getprop ro.product.model)" = NX809J ] || abort "NX809J only."
[ "$(getprop ro.build.version.sdk)" = 36 ] || abort "Android 16 / SDK 36 only."
ui_print "- Redmagic Launcher Guard 0.1.2-test"
ui_print "- Standalone; no Vector, nubia-ly or Toolbox dependency"
ui_print "- Automatic recovery only after confirmed stale third-party routing"
ui_print "- No data clearing; no boot-time launcher restart"
set_perm_recursive "$MODPATH" 0 0 0755 0644
for script in service.sh guard-lib.sh action.sh uninstall.sh; do
    set_perm "$MODPATH/$script" 0 0 0755
done
