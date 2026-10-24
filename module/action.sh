#!/system/bin/sh
MODDIR=${0%/*}
PATH=/system/bin:/system/xbin
export PATH
umask 077
. "$MODDIR/guard-lib.sh"
STATE=/data/adb/redmagic_launcher_guard
mkdir -p "$STATE"
echo "Version: $(sed -n 's/^version=//p' "$MODDIR/module.prop")"
echo "=== Monitor ==="
monitor_pid=$(cat "$STATE/monitor.pid" 2>/dev/null)
monitor_boot=$(cat "$STATE/monitor.boot" 2>/dev/null)
current_boot=$(cat /proc/sys/kernel/random/boot_id)
case "$monitor_pid" in
    ""|*[!0-9]*) running=no ;;
    *)
        if [ "$monitor_boot" = "$current_boot" ] && kill -0 "$monitor_pid" 2>/dev/null &&
            tr '\0' ' ' < "/proc/$monitor_pid/cmdline" | grep -Fq "$MODDIR/service.sh"; then
            running=yes
        else running=no; fi ;;
esac
echo "Monitor running: $running"
if [ "$running" = yes ]; then cat "$STATE/status.txt" 2>/dev/null; fi
BASE_HOLDER=$(read_role)
echo "Saved Home: $BASE_HOLDER"
if eligible; then echo "Live checks: eligible"; else echo "Live checks: $GATE_REASON"; fi
echo "Routing: $(read_routing | routing_state)"
echo "=== Recent monitor events ==="
tail -n 12 "$STATE/events.log" 2>/dev/null
echo "Action is read-only: it does not restart either launcher."
echo "Automatic captures: $STATE/latest.txt and previous.txt"
