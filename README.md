# Redmagic Launcher Guard

Standalone Magisk / KernelSU module for the REDMAGIC 11 Pro **NX809J on Android 16**. Automatically recovers the stock-launcher gesture-routing bug that can take over a selected third-party launcher. Independent of nubia-ly, Vector, Redmagic 11 Toolbox and Trigger Bridge.

**0.1.0-test — phone validation required.** The recovery action was verified on an affected phone; automatic detection, installation and scheduling still require device testing. Detection is based on REDMAGICOS11.0.18MR1_GB and launcher 16.0.020.000.2603171131. Different dump formats fail closed.

## When it acts

The module learns the healthy Home component of the selected launcher; it is not tied to Nova. Automatic recovery requires all of these conditions:

- NX809J, SDK 36, completed boot, user 0, screen awake and keyguard confirmed clear.
- Exactly one saved HOME role holder, matching the previously observed healthy third-party launcher.
- A healthy baseline during the current monitor session: separate stock `RecentsActivity`, third-party Home target, `isDefaultHome=false`, `isHomeDisabled=false`.
- Three consecutive stale observations over at least ten seconds: `homeAndOverviewSame=true`, stock Quickstep Home targeted for both Home and Overview, despite the saved default remaining unchanged.
- The stock Home activity is foreground throughout confirmation and immediately before recovery. Recents alone does not qualify.
- No attempt within the last ten minutes and fewer than three attempts this boot.

Then it saves bounded diagnostics and force-stops **only** `com.zte.mifavor.launcher`. It opens the remembered default Home component only if the foreground is still stock Home or explicitly null, and the eligibility checks still pass. If another app takes focus, it leaves that app alone. A new healthy baseline is required before another attempt.

Normal checks never restart launchers. There is no startup restart, scheduled refresh, data/cache clearing, default-app reassignment, system APK modification, or Vector hook. Missing/ambiguous output never authorizes recovery. Selecting another default disarms the previous baseline. Booting directly into a stale state without any healthy baseline is intentionally left alone in this test version.

Polling uses a 30-second interval, with two extra five-second confirmation intervals only when suspect. Detection normally takes about 10–40 seconds after an eligible stale stock Home screen appears, plus bounded command time. It does not keep a wake lock, run logcat continuously, or write diagnostics on every poll. Android dump calls do have a small polling cost; the module does not claim to be event driven or eliminate the underlying firmware bug.

## Install and test

1. Download the ZIP produced by **Actions → Validate and package → Artifacts**, or build it locally with `python3 scripts/build.py`.
2. Install the module ZIP through Magisk or KernelSU Manager and reboot once.
3. Keep your preferred third-party launcher selected in Android's default-app settings. Use Home normally so the guard can observe healthy routing.
4. Normal use must not restart either launcher. If the stock launcher later takes over, wait up to about a minute while its Home screen remains visible.
5. Use the module's **Action** button to view routing and recent events. Action is read-only and never forces recovery.

Script-only module: no mount/metamodule dependency and no SELinux policy changes. Unknown shell output or unsupported firmware means no automatic action.

## Diagnostics

Root-private files under `/data/adb/redmagic_launcher_guard`:

- `events.log`, `events.previous.log`: approximately 32 KiB per event-log generation.
- `latest.txt`, `previous.txt`: at most 512 KiB per diagnostic capture.

Logs include app/component names and recent launcher messages. Inspect before sharing. No network activity or telemetry. Disable/remove via your root manager; the monitor exits after its current bounded check/sleep. Diagnostics remain after uninstall for investigation.

Copy a capture with Termux:

```bash
su -c 'cp /data/adb/redmagic_launcher_guard/latest.txt /sdcard/Download/redmagic-launcher-guard.txt'
```

## Evidence and limits

On the affected device, the saved HOME holder remained the third-party launcher while `OverviewComponentObserver` targeted stock Quickstep Home for both Home and Overview. Restarting the stock launcher restored third-party Home and the separate Recents activity without clearing data. Healthy and stale parser fixtures reflect that observed difference; alternative third-party component names are tested synthetically, not yet on-device.

The stock APK contains a `getHomeActivities()` wrapper that returns null after a `RemoteException`, and routing logic that can fall back to stock Home when no Home component is available. This is a plausible path, not a proven trigger. The failure predates nubia-ly. The project makes no claim about vendor intent or that any customization module caused it.

No private uploaded reports or vendor APKs are included in this repository.

## Development

```bash
python3 -m unittest discover -s tests -v
python3 scripts/build.py
```

The installer entry is the upstream Magisk `scripts/module_installer.sh`, distributed under its upstream GPL-3.0 license. See `THIRD_PARTY.md` and `LICENSE-MAGISK`.
