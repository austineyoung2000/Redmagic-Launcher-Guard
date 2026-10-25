#!/system/bin/sh
STOCK=com.zte.mifavor.launcher
SERVICE=$STOCK/com.android.quickstep.TouchInteractionService

# Pure parsers: unknown or ambiguous input must never authorize recovery.
role_holder() {
    # Split at every tag boundary, not only adjacent ><. Android pretty-prints
    # roles.xml with whitespace between tags; collapsing lines loses boundaries.
    awk 'BEGIN { RS="<" }
    /^role[[:space:]]/ {
        home=($0 ~ /[[:space:]]name="android[.]app[.]role[.]HOME"/)
        count=0; holder=""
        if (home) homes++
        if ($0 ~ /\/[[:space:]]*>/) home=0
        next
    }
    home && /^holder[[:space:]]/ {
        line=$0
        if (line !~ /[[:space:]]name="[^"]+"/) { count=2; next }
        sub(/^.*[[:space:]]name="/, "", line)
        sub(/".*$/, "", line)
        holder=line; count++
        next
    }
    home && /^\/role[[:space:]]*>/ {
        if (count==1) result=holder
        home=0
    }
    END { if (homes==1 && result!="") print result }
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
    /mKeyguardDelegate|KeyguardServiceDelegate/ { inside=1 }
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
user_zero_unlocked() {
    awk '
    /^Current user: / { current=$3; seen++ }
    /^[[:space:]]*UserInfo[{]/ { owner=($0 ~ /UserInfo[{]0:/) }
    owner && /^[[:space:]]*State:/ { unlocked=($2=="RUNNING_UNLOCKED"); owner=0 }
    END { exit !(seen==1 && current=="0" && unlocked) }'
}
package_state() {
    awk '
    # Other dump sections also contain "User 0:" headings. Only an actual
    # per-user install-state record has an installed= attribute.
    /^[[:space:]]*User 0:/ && / installed=(true|false)([[:space:]]|$)/ {
      seen++
      complete=($0 ~ / hidden=(true|false)([[:space:]]|$)/ &&
                $0 ~ / suspended=(true|false)([[:space:]]|$)/ &&
                $0 ~ / enabled=[0-9]+([[:space:]]|$)/)
      ok=($0 ~ / installed=true([[:space:]]|$)/ &&
          $0 ~ / hidden=false([[:space:]]|$)/ &&
          $0 ~ / suspended=false([[:space:]]|$)/ &&
          $0 ~ / enabled=[01]([[:space:]]|$)/ &&
          $0 !~ / quarantined=true([[:space:]]|$)/)
    }
    END {
      if (seen!=1 || !complete) print "unknown"
      else if (ok) print "available"
      else print "unavailable"
    }'
}
target_available() {
    TARGET_STATE=$(dumpsys -t 4 package "$BASE_HOLDER" 2>/dev/null | package_state)
    case "$TARGET_STATE" in
      available) TARGET_REASON=available; return 0 ;;
      unavailable) TARGET_REASON="selected launcher not installed, enabled, visible or unsuspended" ;;
      *) TARGET_REASON="package state unavailable or ambiguous" ;;
    esac
    return 1
}

eligible() {
    GATE_REASON="module disabled or removed"
    active_module || return 1
    GATE_REASON="boot not complete"
    [ "$(getprop sys.boot_completed)" = 1 ] || return 1
    GATE_REASON="startup grace period (90 seconds)"
    [ "$(uptime_seconds)" -ge 90 ] || return 1
    GATE_REASON="saved Home is not a third-party launcher"
    third_party_holder "$BASE_HOLDER" || return 1
    GATE_REASON="saved Home changed or unavailable"
    [ -n "$BASE_HOLDER" ] && [ "$(read_role)" = "$BASE_HOLDER" ] || return 1
    GATE_REASON="screen not awake or power state unavailable"
    dumpsys -t 3 power 2>/dev/null | grep -q 'mWakefulness=Awake' || return 1
    GATE_REASON="current user is not unlocked user 0, or user dump unavailable"
    dumpsys -t 3 user 2>/dev/null | user_zero_unlocked || return 1
    GATE_REASON="keyguard showing or policy unavailable"
    dumpsys -t 3 window policy 2>/dev/null | keyguard_clear || return 1
    GATE_REASON=eligible
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
        echo "Redmagic Launcher Guard 0.1.3-test"
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

write_status() {
    # Persist only transitions, not every poll. Never source the resulting file.
    status_text=$(printf 'State: %s\nDefault: %s\nBaseline: %s\nAttempts this boot: %s\nLast result: %s\n' \
        "$1" "${BASE_HOLDER:-unknown}" "${BASE_COMPONENT:-optional; package-scoped Home fallback}" "${attempts:-0}" "${LAST_RESULT:-none}")
    old_status=$(cat "$STATE/status.txt" 2>/dev/null)
    [ "$status_text" = "$old_status" ] && return 0
    printf '%s\n' "$status_text" > "$STATE/status.tmp"
    mv -f "$STATE/status.tmp" "$STATE/status.txt"
}
