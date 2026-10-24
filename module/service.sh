#!/system/bin/sh
MODDIR=${0%/*}
PATH=/system/bin:/system/xbin
export PATH
umask 077
. "$MODDIR/guard-lib.sh"
[ "$(getprop ro.product.model)" = NX809J ] || exit 0
[ "$(getprop ro.build.version.sdk)" = 36 ] || exit 0
# In-memory state and lock disappear at reboot. Never kill an unrelated PID.
STATE=/data/adb/redmagic_launcher_guard
mkdir -p "$STATE"
LOCK=/dev/.redmagic_launcher_guard.lock
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK" 2>/dev/null' EXIT
trap 'exit 0' INT TERM
armed=0
BASE_HOLDER=
BASE_COMPONENT=
last_attempt=0
attempts=0
LAST_RESULT=none
printf '%s\n' "$$" > "$STATE/monitor.pid"
cat /proc/sys/kernel/random/boot_id > "$STATE/monitor.boot"
write_status "waiting for healthy baseline"
log_event "monitor started; waiting for healthy default-launcher routing"
while active_module; do
    sleep 30
    holder=$(read_role)
    if ! third_party_holder "$holder"; then
        armed=0
        BASE_HOLDER=
        BASE_COMPONENT=
        write_status "no eligible third-party Home role"
        continue
    fi
    if [ "$holder" != "$BASE_HOLDER" ]; then
        armed=0
        BASE_HOLDER=$holder
        BASE_COMPONENT=
    fi
    if ! eligible; then
        write_status "paused: screen, keyguard, user or default check"
        continue
    fi
    routing_dump=$(read_routing)
    route=$(printf '%s\n' "$routing_dump" | routing_state)
    if [ "$route" = healthy ]; then
        component=$(printf '%s\n' "$routing_dump" | home_component)
        if [ "${component%%/*}" = "$BASE_HOLDER" ]; then
            if [ "$armed" != 1 ] || [ "$BASE_COMPONENT" != "$component" ]; then
                log_event "healthy baseline learned: $component; recovery armed"
            fi
            BASE_COMPONENT=$component
            armed=1
            write_status "monitoring: healthy baseline learned"
        else
            armed=0
            write_status "blocked: routing does not match saved default"
        fi
        continue
    fi
    if [ "$route" != stale ]; then
        write_status "blocked: unknown routing output"
        continue
    fi
    if [ "$armed" != 1 ]; then
        write_status "stale routing: waiting for healthy baseline"
        continue
    fi
    if ! foreground_ok; then
        write_status "stale routing: waiting for stock Home foreground"
        continue
    fi
    now=$(uptime_seconds)
    if [ "$last_attempt" != 0 ] && [ "$((now-last_attempt))" -lt 600 ]; then
        write_status "stale routing: cooldown"
        continue
    fi
    if [ "$attempts" -ge 3 ]; then
        write_status "blocked: recovery limit reached this boot"
        continue
    fi
    write_status "confirming persistent stale routing"
    confirmed=1
    for sample in 2 3; do
        sleep 5
        if ! eligible || ! foreground_ok || [ "$(read_routing | routing_state)" != stale ]; then
            confirmed=0
            break
        fi
    done
    [ "$confirmed" = 1 ] || continue
    capture "three persistent stale-routing samples with stock Home foreground"
    # Recheck after capture: never act on stale observations from diagnostics.
    eligible && foreground_ok && [ "$(read_routing | routing_state)" = stale ] || continue
    last_attempt=$(uptime_seconds)
    attempts=$((attempts+1))
    armed=0
    write_status "recovering confirmed stale routing"
    log_event "confirmed mismatch; recovery attempt $attempts of 3 this boot"
    stop_output=$(timeout 8 /system/bin/am force-stop --user 0 "$STOCK" 2>&1)
    stop_status=$?
    if [ "$stop_status" -ne 0 ] || printf '%s' "$stop_output" | grep -qiE 'failed|error|exception'; then
        LAST_RESULT="force-stop failed"
        log_event "force-stop failed; no further action: $stop_output"
        write_status "recovery failed; waiting for healthy baseline"
        continue
    fi
    # Do not bring the default launcher over another app if focus changed during the restart.
    eligible || continue
    focus=$(dumpsys -t 4 activity activities 2>/dev/null | grep 'topResumedActivity=')
    if printf '%s' "$focus" | grep -q 'topResumedActivity=null' || printf '%s' "$focus" | stock_home_foreground; then
        result=$(timeout 8 /system/bin/am start --user 0 -n "$BASE_COMPONENT" 2>&1)
        log_event "Default launcher launch result: $result"
    else
        log_event "focus changed; left current app untouched"
    fi
    sleep 5
    result=$(read_routing | routing_state)
    LAST_RESULT=$result
    write_status "recovery attempted; verifying healthy baseline"
    log_event "post-recovery routing: $result; fresh healthy baseline required"
    [ "$result" != healthy ] || armed=1
 done
write_status "monitor stopped"
log_event "monitor stopped"
