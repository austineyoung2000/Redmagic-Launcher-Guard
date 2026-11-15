#!/system/bin/sh
. "$MODPATH/guard-lib.sh"
is_redmagic11pro || abort "REDMAGIC 11 Pro / NX809J only."
ui_print "- No exact Android, REDMAGICOS or launcher version restriction"
ui_print "- Redmagic Launcher Guard 0.1.5-test"
ui_print "- Standalone; no Vector, nubia-ly or Toolbox dependency"
ui_print "- Automatic recovery only after confirmed stale third-party routing"
ui_print "- No data clearing; no boot-time launcher restart"
set_perm_recursive "$MODPATH" 0 0 0755 0644
for script in service.sh guard-lib.sh action.sh uninstall.sh; do
    set_perm "$MODPATH/$script" 0 0 0755
done
