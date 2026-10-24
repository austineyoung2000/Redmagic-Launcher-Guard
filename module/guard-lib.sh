#!/system/bin/sh
STOCK=com.zte.mifavor.launcher
SERVICE=$STOCK/com.android.quickstep.TouchInteractionService

# Pure parsers: unknown or ambiguous input must never authorize recovery.
role_holder() {
    tr '\n\r' '  ' | sed 's/></>\
</g' | awk '
    /<role[ >]/ { home=($0 ~ /name="android.app.role.HOME"/); count=0; holder="" }
    home && /<holder / {
        line=$0; sub(/^.*name="/, "", line); sub(/".*$/, "", line)
        holder=line; count++
    }
    home && /<\/role>/ { if(count==1) print holder; home=0 }
    '
}
routing_state() {
    awk '
    /OverviewComponentObserver:/ { inside=1; next }
    inside && /isDefaultHome=/ { def=$0; sub(/^.*=/,"",def) }
    inside && /isHomeDisabled=/ { disabled=$0; sub(/^.*=/,"",disabled) }
    inside && /homeAndOverviewSame=/ { same=$0; sub(/^.*=/,"",same) }
    inside && /overviewIntent=/ { overview=$0 }
    inside && /homeIntent=/ { home=$0; inside=0 }
    END {
      if (def!="false" || disabled!="false") { print "unknown"; exit }
      if (same=="false" && home !~ /cmp=com.zte.mifavor.launcher\// && home ~ /cmp=[A-Za-z0-9_.]+\/[A-Za-z0-9_.$]+[ }]/ && overview ~ /cmp=com.zte.mifavor.launcher\/com.android.quickstep.RecentsActivity[ }]/) print "healthy"
      else if (same=="true" && home ~ /cmp=com.zte.mifavor.launcher\/com.android.launcher3.uioverrides.QuickstepLauncher[ }]/ && overview ~ /cmp=com.zte.mifavor.launcher\/com.android.launcher3.uioverrides.QuickstepLauncher[ }]/) print "stale"
      else print "unknown"
    }'
}
stock_home_foreground() {
    grep -E 'topResumedActivity=.*com\.zte\.mifavor\.launcher/com\.android\.launcher3\.uioverrides\.QuickstepLauncher([[:space:]}]|$)' >/dev/null
}
keyguard_clear() {
    awk '
    /mKeyguardDelegate/ { inside=1 }
    inside && /^[[:space:]]*showing=/ {
      sub(/^[[:space:]]*showing=/, ""); if ($0=="false") ok=1; exit
    }
    END { exit !ok }'
}
home_component() {
    awk '/^[[:space:]]*homeIntent=/ {
        sub(/^.*cmp=/, ""); sub(/[ }].*$/, ""); print
    }'
}
third_party_holder() {
    case "$1" in
        ""|android|com.zte.mifavor.launcher|cn.nubia.gamelauncher|com.android.zte.gdpr.provision|*setupwizard*|*provision*) return 1 ;;
    esac
    printf '%s\n' "$1" | grep -Eq '^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+$'
}
read_role() {
    for role_path in /data/misc_de/0/apexdata/com.android.permission/roles.xml /data/system/users/0/roles.xml; do
        if [ -r "$role_path" ]; then role_holder < "$role_path"; return; fi
    done
}
active_module() { [ ! -e "$MODDIR/disable" ] && [ ! -e "$MODDIR/remove" ]; }
eligible() {
    active_module || return 1
    [ "$(getprop sys.boot_completed)" = 1 ] || return 1
    [ "$(timeout 5 /system/bin/am get-current-user 2>/dev/null)" = 0 ] || return 1
    [ -n "$BASE_HOLDER" ] && [ "$(read_role)" = "$BASE_HOLDER" ] || return 1
    dumpsys -t 3 power 2>/dev/null | grep -q 'mWakefulness=Awake' || return 1
    dumpsys -t 3 window policy 2>/dev/null | keyguard_clear || return 1
}
read_routing() { dumpsys -t 4 activity service "$SERVICE" 2>/dev/null; }
foreground_ok() { dumpsys -t 4 activity activities 2>/dev/null | stock_home_foreground; }
uptime_seconds() { cut -d. -f1 /proc/uptime; }
log_event() {
    if [ -f "$STATE/events.log" ] && [ "$(wc -c < "$STATE/events.log")" -gt 32768 ]; then
        mv -f "$STATE/events.log" "$STATE/events.previous.log"
    fi
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S%z')" "$*" >> "$STATE/events.log"
}
capture() {
    [ ! -f "$STATE/latest.txt" ] || mv -f "$STATE/latest.txt" "$STATE/previous.txt"
    {
        echo "Redmagic Launcher Guard 0.1.0-test"
        date
        echo "Reason: $1"
        echo "Model: $(getprop ro.product.model)"
        echo "ROM: $(getprop ro.build.display.id)"
        echo "Saved HOME holder: $(read_role)"
        echo "=== GESTURE SERVICE ==="
        read_routing
        echo "=== WINDOW POLICY ==="
        dumpsys -t 3 window policy
        echo "=== LAUNCHER EXIT HISTORY ==="
        dumpsys -t 3 activity exit-info "$STOCK"
        echo "=== RECENT LAUNCHER LOGS ==="
        launcher_pid=$(pidof "$STOCK" | awk '{print $1}')
        if [ -n "$launcher_pid" ]; then
            timeout 5 /system/bin/logcat -b main -b system -d -v threadtime -t 300 --pid="$launcher_pid"
        fi
    } 2>&1 | head -c 524288 > "$STATE/latest.txt"
    chmod 600 "$STATE/latest.txt"
}
