# Automation polish deployment — 14 September 2026

Deployed to 192.168.50.110 after the two-job Test Queue completed. No new
calibration was started by this deployment.

## Installed changes

- Compact red Run queue button, matching Readiness height, font and padding.
- Read-only Calibration workspace observer showing the automation job's work.
- New items default to pre/post sweeps off; explicit saved opt-ins survive.
- Reference jobs retain mode-specific gamma defaults, ΔE 0.5 and sweeps off.
- Structured 1D adjustment/measurement logging with duplicate chatter removed.
- Known unsupported Apply All confirmation is informational, not a warning;
  actual settings verification remains required.
- Advisory stage/batch time estimates, recalculated every two minutes and at
  stage changes; estimates remain unavailable until enough evidence exists.
- Saved-run history gets a 30-second timeout, a visible failure and Retry,
  preserving previously loaded results rather than claiming history is empty.

The history issue reproduced after restart: the API took 5.28 seconds with
24 saved runs, exceeding its previous five-second UI timeout. This change
allows more time; it does not make the underlying history scan faster.

## Deployment evidence

Backup on Pi: `/root/pgen-automation-polish-ILPc2s/before/`.
Staged files: `/root/pgen-automation-polish-ILPc2s/stage/`.

Nine changed/new runtime files installed; all other packaged files already
matched. After the final restart, all **608** packaged files matched local
SHA-256, with no missing files. Device configuration and runtime files were
excluded from replacement and checksum comparison.

Initial boot ID: `b3ac2bfa-c5c3-4f15-a0be-74b8f47fb680`.
Final boot ID: `4a514a0f-ee0f-4863-aac6-fe2f7331060b`.
Process audit found no calibration/meter workers. Stored TV pairing reconnected
successfully; TV reported connected, on, and calibration mode false.

`prove t/`: 45 suites, 1,809 assertions passed. Offline browser checks passed
for editor, activity, history errors/recovery, job detail and calibration
observer. Served editor checks passed for all six reference presets, new-item
sweep defaults, compact button, observer presence and ETA helper.

Actual served button geometry: Run queue and Check Readiness both 24px high,
12px font and 5px/10px padding. Run queue background is rgb(255, 68, 68).
An existing browser tab needs refreshing to load the changed UI.

## Completed run audit

Run `20260914-112315-470e19`: SDR Filmmaker and HDR Filmmaker completed.
Both jobs have verified final 1D and 3D uploads, verified 3D terminal commits,
saved exports, and completed pre/post greyscale, colour and saturation sweeps.
No setting mismatch/failed checks were found, nor worker errors matching the
audit's selected fatal/upload/measurement failure patterns.

Both jobs' saved warnings were the previously unsupported Apply All readback.
Historical warnings remain unchanged; the new reporting applies to future jobs.

Completion does not imply every point met ΔE 0.5. The SDR 2.3% point's best
observed 1D-worker ΔE was about 6.34; HDR's worst was about 0.87. These are
1D-worker values, not final post-3D-LUT quality measurements. No calibration
algorithm, convergence tolerance or acceptance policy was changed.

Read-only audit script: `Logs/2026-09-14-batch-deployment-audit.pl`.
Browser evidence directory: `/tmp/pgen-polish-deployed-yv1Z3e`.

Deployed history/graph checks passed after the final restart: 169 setting
checks, eight snapshots and ten displayed graph images for the saved SDR
job. Both before/after EOTF and luminance images were 1078 × 300. Desktop,
mobile, chart selector restoration and browser-error checks passed.

## Remaining issue found during verification

A current-status GET took 12.108 seconds while saved-history browser checks
were running. Live polling times out at eight seconds (the general refresh
uses five). Automation history and current-status GETs share the serialized
general request lane. This can produce the "last known state" warning even
though the Pi responds successfully later. Raising the history timeout does
not resolve live-status contention. Further work should isolate lightweight
status delivery from expensive history reads and clarify connection-state
reporting without pretending old progress is live. No concurrency/routing
change was deployed in this turn.

Latest status check returned no active run or execution owner. The completed
Test Queue remains accessible through History.
