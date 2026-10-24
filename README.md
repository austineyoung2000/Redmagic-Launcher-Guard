# Redmagic Launcher Guard

Standalone Magisk / KernelSU module for the REDMAGIC 11 Pro **NX809J on Android 16**. Automatically recovers confirmed stale stock-launcher Home gesture routing for the selected third-party launcher. Independent of nubia-ly, Vector, Redmagic 11 Toolbox and Trigger Bridge. No launcher package is hardcoded as the preferred Home app.

**0.1.2-test — phone validation required.** The manual recovery action was verified on an affected phone; the updated automatic checks still require phone testing. Detection was derived from REDMAGICOS11.0.18MR1_GB / launcher 16.0.020.000.2603171131. Unsupported dump formats cause no automatic recovery.

## What changed in 0.1.2

The installed module's report exposed two blocked checks: `am get-current-user` failed with a Binder transaction error, and this firmware prints `KeyguardServiceDelegate` rather than `mKeyguardDelegate`. Eligibility now uses the working `dumpsys user` output to verify both current user 0 and `RUNNING_UNLOCKED`, accepts both observed keyguard labels, and reports the exact failed check.

A prior healthy routing observation is no longer required. A stale-at-startup session can recover after a 90-second startup grace period if every mismatch and eligibility check passes. A previously observed healthy Home component is optional; otherwise the post-restart Home launch is constrained to the selected package with `MAIN` / `HOME` intent categories. Android resolves that launch, rather than guessing an activity name.

Version 0.1.1 fixed Android whitespace-formatted `roles.xml` parsing and added monitor visibility. Earlier 0.1.0 and 0.1.1 test versions could remain blocked on the affected device; do not treat their lack of recoveries as evidence that the firmware issue disappeared.

## When it acts

Automatic recovery requires all of these conditions:

- NX809J, SDK 36, completed boot, at least 90 seconds uptime, awake screen, current user 0 in `RUNNING_UNLOCKED`, and keyguard explicitly showing false.
- Exactly one saved HOME role holder that is a third-party package. Selecting the stock launcher, Game Space or a setup/provisioning Home does not qualify.
- Three consecutive stale observations over at least ten seconds: `isDefaultHome=false`, `isHomeDisabled=false`, `homeAndOverviewSame=true`, and stock Quickstep Home targeted for both Home and Overview.
- The saved default remains the same package throughout confirmation and immediately before recovery.
- The stock Home activity is foreground throughout confirmation and immediately before recovery. Merely opening Recents does not qualify; another app in front defers recovery.
- The selected package is installed for user 0, visible, enabled, not suspended and not quarantined, checked before confirmation and again immediately before recovery.
- No recovery attempt within the last ten minutes, and fewer than three attempts this boot/monitor session.

Then it saves bounded diagnostics and force-stops **only** `com.zte.mifavor.launcher`. It opens the selected Home only if focus is still stock Home or explicitly null and eligibility still passes. If another app takes focus, it leaves that app alone. Commands use null stdin; a failed force-stop is reported as failure, consumes an attempt, and does not proceed to a launcher launch. Later attempts require a new complete confirmation and respect cooldown/limits.

Normal checks never restart launchers. There is no unconditional startup restart, scheduled launcher refresh, data/cache clearing, default-app reassignment, system APK modification or Vector hook. Unknown, missing or ambiguous state causes no action. No permission or SELinux policy changes.

## Monitoring overhead

The loop sleeps 30 seconds between checks; only a suspect state adds two five-second confirmation intervals. Detection normally takes about 10–40 seconds after an eligible stale stock Home screen appears, plus bounded command/capture time. No wake lock, continuous logcat collection or per-poll diagnostic writes. Status is rewritten only when its state changes; Android dump calls still have a polling cost. Screen-off state stops the deeper user/keyguard/routing checks. This is a recovery workaround, not a patch to the underlying firmware.

## Install and test

1. Get the ZIP from **Actions → Validate and package → Artifacts**, or run `python3 scripts/build.py` locally.
2. Install the module ZIP through Magisk or KernelSU Manager and reboot once.
3. Keep your preferred third-party launcher selected in Android settings.
4. After unlocking and at least 90 seconds uptime, use the module's **Action** button. It prints the module version, monitor liveness, selected Home, current routing, exact live eligibility result and recorded recovery results. Action is read-only and never restarts launchers.
5. If the bug is present, leave stock Home visible for about a minute. Read Action afterward; `confirmed mismatch; recovery attempt ...` followed by `post-recovery routing: healthy` is evidence of an automatic recovery.

Healthy routing should show `monitoring: healthy baseline learned`; that observed component improves launch specificity but is optional. A stale state while another app is foreground shows `waiting for stock Home foreground`. Paused checks report their reason. Zero attempts alone is not proof that recovery works.

Script-only module: no mount/metamodule dependency. Installation through Magisk and KernelSU still needs phone validation for this test version.

## Diagnostics

Root-private files under `/data/adb/redmagic_launcher_guard`:

- `status.txt`, `monitor.pid`, `monitor.boot`: transition state and liveness metadata.
- `events.log`, `events.previous.log`: approximately 32 KiB per event-log generation.
- `latest.txt`, `previous.txt`: at most 512 KiB per diagnostic capture.

The Action display distinguishes current live eligibility from the monitor's recorded status, which can be up to one poll behind. Logs contain package/component names and recent launcher messages; inspect before sharing. No network activity or telemetry. Disable/remove via the root manager; the monitor exits after its current bounded check/sleep. Diagnostics remain after uninstall for investigation.

Copy a capture with Termux:

```bash
su -c 'cp /data/adb/redmagic_launcher_guard/latest.txt /sdcard/Download/redmagic-launcher-guard.txt'
```

## Evidence and limits

The saved HOME holder remained Nova while the gesture service targeted stock Quickstep Home for both Home and Overview. Restarting the stock launcher restored Nova Home and the separate Recents activity without clearing data. Synthetic tests cover other third-party component names; those launchers have not all been tested on-device.

The stock APK has a `getHomeActivities()` wrapper returning null after a `RemoteException`, and a routing path that can fall back to stock Home when no Home component is available. This is a plausible trigger, not a proven cause. The failure predates nubia-ly. No claim about vendor intent or responsibility of customization modules is made.

No private uploaded reports or vendor APKs are included in this repository. Diagnostic formats and eligibility checks from the supplied reports are covered using synthetic fixtures.

## Development

```bash
python3 -m unittest discover -s tests -v
python3 scripts/build.py
```

The installer entry is the upstream Magisk `scripts/module_installer.sh`, distributed under GPL-3.0. See `THIRD_PARTY.md` and `LICENSE-MAGISK`.
