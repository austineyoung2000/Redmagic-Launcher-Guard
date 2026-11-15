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

legacy_routing_state() {
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
legacy_stock_home_foreground() {
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
        ""|android|"$STOCK"|com.zte.mifavor.launcher|cn.nubia.gamelauncher|com.android.zte.gdpr.provision|*setupwizard*|*provision*) return 1 ;;
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
        echo "Redmagic Launcher Guard 0.1.5-test"
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

# A small retained snapshot survives opening KernelSU, which changes foreground.
# Caller must have observed stale routing with stock Home foreground.
remember_incident() {
    incident_now=$(uptime_seconds)
    if [ "${last_incident:-0}" != 0 ] && [ "$((incident_now-last_incident))" -lt 600 ]; then
        return 0
    fi
    last_incident=$incident_now
    incident_tmp=$(mktemp "$STATE/incident.XXXXXX") || return 1
    {
        echo "=== AUTOMATIC STALE INCIDENT (before opening Action) ==="
        date
        echo "Boot: $(cat /proc/sys/kernel/random/boot_id)"
        echo "Uptime: $incident_now"
        echo "Reason: $1"
        echo "Saved Home: $(read_role)"
        echo "=== MONITOR STATUS AT DETECTION ==="
        cat "$STATE/status.txt" 2>/dev/null
        echo "=== ROUTING AT DETECTION ==="
        printf '%s\n' "$2"
        echo "=== FOREGROUND AT DETECTION ==="
        dumpsys -t 4 activity activities 2>&1 |
            grep -E 'topResumedActivity=|mResumedActivity:|ResumedActivity:'
    } | head -c 131072 > "$incident_tmp"
    if [ -s "$incident_tmp" ]; then
        [ ! -f "$STATE/incident.txt" ] || cp -f "$STATE/incident.txt" "$STATE/incident.previous.txt"
        mv -f "$incident_tmp" "$STATE/incident.txt"
        log_event "stale incident snapshot retained"
    else
        rm -f "$incident_tmp"
        return 1
    fi
}

report_section() {
    echo
    echo "=== $1 ==="
    echo "Captured: $(date '+%Y-%m-%d %H:%M:%S%z')"
}
retained_section() {
    report_section "$1"
    if [ -s "$2" ]; then head -c "$3" "$2"; else echo "No retained capture available."; fi
    echo
}
write_action_report() {
    # Keep manual evidence separate from incident/pre-recovery evidence.
    # Bound each section independently so missing evidence remains explicit.
    {
        echo "REDMAGIC LAUNCHER GUARD SUPPORT REPORT"
        echo "Version: $(sed -n 's/^version=//p' "$MODDIR/module.prop")"
        date
        echo "Boot: $(cat /proc/sys/kernel/random/boot_id)"
        echo "Uptime seconds: $(uptime_seconds)"
        echo "Model: $(getprop ro.product.model)"
        echo "ROM: $(getprop ro.build.display.id)"
        echo "Action collects evidence only; no launcher restart or settings change."
        echo "IMPORTANT: the live foreground below may be KernelSU/Action."
        echo "Use the separately timestamped automatic incident for pre-Action evidence."
        echo "No incident capture can be reconstructed retroactively."
        report_section "FIRMWARE AND STOCK LAUNCHER DETECTION"
        compatibility_summary
        report_section "RECORDED MONITOR STATUS"
        cat "$STATE/status.txt" 2>/dev/null
        echo "Monitor running at Action start: ${running:-not checked}"
        echo "Monitor PID: $(cat "$STATE/monitor.pid" 2>/dev/null)"
        echo "Monitor boot: $(cat "$STATE/monitor.boot" 2>/dev/null)"
        BASE_HOLDER=$(read_role)
        echo "Saved HOME holder: $BASE_HOLDER"
        if eligible; then echo "Live eligibility: eligible"; else echo "Live eligibility: $GATE_REASON"; fi
        if third_party_holder "$BASE_HOLDER"; then
            target_available
            echo "Selected launcher availability: $TARGET_REASON"
        fi
        retained_section "RECENT MONITOR EVENTS" "$STATE/events.log" 40000
        retained_section "PREVIOUS MONITOR EVENTS" "$STATE/events.previous.log" 40000
        retained_section "LATEST AUTOMATIC STALE INCIDENT" "$STATE/incident.txt" 131072
        retained_section "PREVIOUS AUTOMATIC STALE INCIDENT" "$STATE/incident.previous.txt" 131072
        report_section "LIVE ROUTING (Action may now be foreground)"
        read_routing | head -c 262144
        report_section "LIVE FOREGROUND"
        dumpsys -t 4 activity activities 2>&1 |
            grep -E 'topResumedActivity=|mResumedActivity:|ResumedActivity:'
        report_section "LIVE POWER"
        dumpsys -t 3 power 2>&1 | grep -iE 'wakefulness|interactive|display power' | head -c 16384
        report_section "LIVE KEYGUARD POLICY"
        dumpsys -t 3 window policy 2>&1 | head -c 65536
        report_section "LIVE USER STATE"
        dumpsys -t 3 user 2>&1 | head -c 65536
        if third_party_holder "$BASE_HOLDER"; then
            report_section "SELECTED LAUNCHER PACKAGE"
            dumpsys -t 4 package "$BASE_HOLDER" 2>&1 | head -c 262144
            report_section "SELECTED LAUNCHER EXIT HISTORY"
            dumpsys -t 3 activity exit-info "$BASE_HOLDER" 2>&1 | head -c 65536
        fi
        report_section "STOCK LAUNCHER PACKAGE AND RESOLVERS"
        dumpsys -t 4 package "$STOCK" 2>&1 | head -c 262144
        report_section "STOCK LAUNCHER EXIT HISTORY"
        dumpsys -t 3 activity exit-info "$STOCK" 2>&1 | head -c 65536
        report_section "RECENT STOCK LAUNCHER LOGS"
        report_pid=$(pidof "$STOCK" | awk '{print $1}')
        if [ -n "$report_pid" ]; then
            timeout 5 /system/bin/logcat -b main -b system -d -v threadtime -t 300 --pid="$report_pid" 2>&1 | head -c 65536
        else echo "Stock launcher process not found."; fi
        retained_section "LATEST PRE-RECOVERY CAPTURE" "$STATE/latest.txt" 524288
        retained_section "PREVIOUS PRE-RECOVERY CAPTURE" "$STATE/previous.txt" 524288
        echo "=== END OF SUPPORT REPORT ==="
    } > "$1" 2>&1
}
save_action_report() {
    report_tmp=$(mktemp "$STATE/report.XXXXXX") || return 1
    write_action_report "$report_tmp"
    if ! grep -q '^=== END OF SUPPORT REPORT ===$' "$report_tmp"; then
        echo "Report capture did not complete."
        rm -f "$report_tmp"
        return 1
    fi
    chmod 600 "$report_tmp"
    mv -f "$report_tmp" "$STATE/manual-latest.txt" || return 1
    # Explicit user Action exports only this one latest report; no accumulation.
    public_tmp="$DOWNLOAD_REPORT.tmp.$$"
    if cp "$STATE/manual-latest.txt" "$public_tmp" 2>/dev/null &&
        mv -f "$public_tmp" "$DOWNLOAD_REPORT" 2>/dev/null; then
        echo "REPORT SAVED: $DOWNLOAD_REPORT"
        echo "Upload that text file to this chat."
    else
        rm -f "$public_tmp"
        echo "Could not export to Download. Root-private report saved: $STATE/manual-latest.txt"
        echo "Copy this file manually if shared storage is unavailable."
    fi
}

is_redmagic11pro() {
    for identity in "$(getprop ro.product.model)" "$(getprop ro.product.device)" \
        "$(getprop ro.product.vendor.model)" "$(getprop ro.product.vendor.device)"; do
        case "$identity" in NX809J|NX809J-*|nx809j|nx809j-*) return 0 ;; esac
    done
    return 1
}
firmware_identity() {
    firmware_display=$(getprop ro.build.display.id)
    case "$(printf '%s' "$firmware_display" | tr '[:lower:]' '[:upper:]')" in
        *REDMAGICOS*|*REDMAGIC_OS*) echo 'REDMAGICOS marker detected' ;;
        *) echo 'firmware name unrecognized; existing recovery checks retained' ;;
    esac
}
canonical_component() {
    component=$1
    case "$component" in
        */.*) printf '%s/%s%s\n' "${component%%/*}" "${component%%/*}" "${component#*/}" ;;
        */*) printf '%s\n' "$component" ;;
    esac
}
# Read one unique component from the PackageManager resolver tables. Labels and
# version numbers are not identities; package/component names are.
resolver_component() {
    awk -v package="$1" -v kind="$2" '
    /Activity Resolver Table:/ { section="home"; candidate="" }
    /Service Resolver Table:/ { section="service"; candidate="" }
    /Receiver Resolver Table:|Provider Resolver Table:/ { section=""; candidate="" }
    section==kind {
      for(i=1;i<=NF;i++) {
        if(index($i,package "/")==1) {
          candidate=$i
          if(candidate !~ /^[A-Za-z0-9_.$]+\/[A-Za-z0-9_.$]+$/) candidate=""
        }
      }
      if(candidate!="" && ((kind=="home" && /Category:.*android.intent.category.HOME"/) ||
                           (kind=="service" && /Action:.*android.intent.action.QUICKSTEP_SERVICE"/))) {
        split(candidate,parts,"/")
        if(substr(parts[2],1,1)==".") candidate=parts[1] "/" parts[1] parts[2]
        found[candidate]=1
      }
    }
    END { for(c in found) { count++; value=c }; if(count==1) print value }'
}
system_package() {
    grep -E '^[[:space:]]*(pkgFlags|flags)=\[.*(^|[[:space:]])SYSTEM([[:space:]]|\])' >/dev/null
}
detect_stock_launcher() {
    # Preserve the device-verified recovery path whenever discovery is incomplete.
    STOCK=com.zte.mifavor.launcher
    SERVICE=$STOCK/com.android.quickstep.TouchInteractionService
    STOCK_HOME=$STOCK/com.android.launcher3.uioverrides.QuickstepLauncher
    STOCK_RECENTS=$STOCK/com.android.quickstep.RecentsActivity
    DETECTION_MODE=verified-fallback
    DETECTION_REASON='using existing Redmagic launcher recovery checks'
    recents_candidate=$(dumpsys -t 5 activity service com.android.systemui/.SystemUIService 2>/dev/null |
        sed -n 's/^[[:space:]]*mRecentsComponentName=ComponentInfo{\([^}]*\)}.*/\1/p' | sort -u)
    printf '%s\n' "$recents_candidate" | grep -Eq '^[A-Za-z0-9_.$]+/[A-Za-z0-9_.$]+$' || return 0
    launcher_candidate=${recents_candidate%%/*}
    launcher_dump=$(dumpsys -t 4 package "$launcher_candidate" 2>/dev/null)
    printf '%s\n' "$launcher_dump" | system_package || return 0
    home_candidate=$(printf '%s\n' "$launcher_dump" | resolver_component "$launcher_candidate" home)
    service_candidate=$(printf '%s\n' "$launcher_dump" | resolver_component "$launcher_candidate" service)
    recents_candidate=$(canonical_component "$recents_candidate")
    [ -n "$home_candidate" ] && [ -n "$service_candidate" ] || return 0
    [ "$home_candidate" != "$recents_candidate" ] || return 0
    STOCK=$launcher_candidate
    STOCK_HOME=$home_candidate
    STOCK_RECENTS=$recents_candidate
    SERVICE=$service_candidate
    DETECTION_MODE=discovered
    DETECTION_REASON='system Recents provider, system-package flag, HOME and Quickstep service resolved'
}
# The original parsers remain the fallback; discovery never removes their
# automatic recovery when firmware reports an unfamiliar resolver format.
routing_state() {
    if [ "${DETECTION_MODE:-verified-fallback}" != discovered ]; then
        legacy_routing_state
        return
    fi
    awk -v home_target="$STOCK_HOME" -v recents_target="$STOCK_RECENTS" '
    function comp(line, a) {
      if(line !~ /cmp=/) return ""
      sub(/^.*cmp=/,"",line); sub(/[ }].*$/,"",line)
      split(line,a,"/"); if(substr(a[2],1,1)==".") line=a[1] "/" a[1] a[2]
      return line
    }
    /OverviewComponentObserver:/ { inside=1; next }
    inside && /isDefaultHome=/ { def=$0; sub(/^.*=/,"",def) }
    inside && /isHomeDisabled=/ { disabled=$0; sub(/^.*=/,"",disabled) }
    inside && /homeAndOverviewSame=/ { same=$0; sub(/^.*=/,"",same) }
    inside && /overviewIntent=/ { overview=comp($0) }
    inside && /homeIntent=/ { home=comp($0); inside=0 }
    END {
      if(def!="false" || disabled!="false") print "unknown"
      else if(same=="true" && home==home_target && overview==home_target) print "stale"
      else if(same=="false" && home!="" && home!=home_target && overview==recents_target) print "healthy"
      else print "unknown"
    }'
}
stock_home_foreground() {
    if [ "${DETECTION_MODE:-verified-fallback}" != discovered ]; then
        legacy_stock_home_foreground
        return
    fi
    awk -v wanted="$STOCK_HOME" '
    /topResumedActivity=/ {
      for(i=1;i<=NF;i++) if($i ~ /^[A-Za-z0-9_.$]+\/[A-Za-z0-9_.$]+$/) {
        split($i,a,"/"); component=$i
        if(substr(a[2],1,1)==".") component=a[1] "/" a[1] a[2]
        if(component==wanted) found=1
      }
    }
    END { exit !found }'
}
compatibility_summary() {
    echo "Device: $(getprop ro.product.model) / $(getprop ro.product.device)"
    echo "Android SDK: $(getprop ro.build.version.sdk) (no exact SDK/version gate)"
    echo "Firmware: $(firmware_identity)"
    echo "Stock launcher: $STOCK"
    echo "Stock Home: ${STOCK_HOME:-legacy Quickstep Home}"
    echo "Recents: ${STOCK_RECENTS:-legacy RecentsActivity}"
    echo "Quickstep service: $SERVICE"
    echo "Detection: ${DETECTION_MODE:-verified-fallback}; $DETECTION_REASON"
}
