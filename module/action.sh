#!/system/bin/sh
MODDIR=${0%/*}
PATH=/system/bin:/system/xbin
export PATH
umask 077
. "$MODDIR/guard-lib.sh"
STATE=/data/adb/redmagic_launcher_guard
mkdir -p "$STATE"
echo "Saved Home: $(read_role)"
echo "Routing: $(read_routing | routing_state)"
echo "=== Recent monitor events ==="
tail -n 12 "$STATE/events.log" 2>/dev/null
echo "Action is read-only: it does not restart either launcher."
echo "Automatic captures: $STATE/latest.txt and previous.txt"
