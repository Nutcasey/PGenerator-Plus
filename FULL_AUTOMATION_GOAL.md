# Full automation: goal specification

Status: execution contract for a single `/goal` run. Agreed with the owner on 12 September 2026 after a 29-question design interview and a read-only survey of the code at commit `42a6f3e8`. Implementation is in progress; live smoke evidence exists for measurement-only and HDR settings paths, and calibration stop-path proof remains in progress.

[FULL_AUTOMATION_DESIGN.md](FULL_AUTOMATION_DESIGN.md) is the product specification. This file is the execution contract. Where the two differ, this file wins, because every difference below is a decision the owner made after seeing the code facts.

## 0. Read these first

| Document | What it is |
|---|---|
| [FULL_AUTOMATION_DESIGN.md](FULL_AUTOMATION_DESIGN.md) | Product spec: queue items, stages, settings authority, queue behaviour, failure semantics, results, eight acceptance examples. |
| [full-automation/LIVE-PROOF-PROTOCOL.md](full-automation/LIVE-PROOF-PROTOCOL.md) | How to reach the Pi and TV, deploy, run smoke and full-length proofs, collect evidence. |
| [full-automation/CODE-FACTS-workers.md](full-automation/CODE-FACTS-workers.md) | How workers are launched and tracked, daemon and watchdog lifecycle, persistence, report storage. |
| [full-automation/CODE-FACTS-lg-control.md](full-automation/CODE-FACTS-lg-control.md) | Picture-mode selection, the 31 picture keys, the four resets and what they move, session hold, apply-to-all, DV, hazards. |
| [full-automation/CODE-FACTS-autocal-ui.md](full-automation/CODE-FACTS-autocal-ui.md) | The browser-only Full AutoCal orchestration to re-implement, report data model, stop and retry mechanics, fragment rules, test suite. |
| [full-automation/KNOWN-BUGS-OUT-OF-SCOPE.md](full-automation/KNOWN-BUGS-OUT-OF-SCOPE.md) | Confirmed defects the queue will walk through. Out of scope. Record their effects, never mask them. |
| `usr/share/PGenerator/README-webui-fragments.md` | Byte-sensitive fragment rules. Its golden-hash instructions are stale (see 7.3). |

Repository facts: `origin` is `https://github.com/oldgithubman/PGenerator-Plus.git`, default branch `main`. CI is `.github/workflows/tests.yml`: installs `libio-socket-ssl-perl`, runs `perl -c` on both workers, `usr/sbin/pgenerator-lg`, `lg.pm` and `webui.pm`, then `prove -v t/` (8 files, 88 tests). The untracked `Bugs/` directory must never be committed.

## 1. Definition of done

All of the following, in this order of proof:

1. **Branch and PR.** All work on `feature/full-automation` off `main`. Exactly one pull request to `origin/main` at the end. Do not merge. Commit `FULL_AUTOMATION_DESIGN.md`, this file and `full-automation/` on the branch.
2. **CI green.** The existing 88 tests still pass and every `perl -c` in the workflow passes, including the new runner script added to that workflow.
3. **Every acceptance example in section 6 proved live** on the owner's TV, with the evidence bundle described in the live-proof protocol.
4. **One full-length proof run**: a queue of at least three SDR picture modes followed by at least two HDR picture modes, each with pre-readings, calibration with apply-to-all, and post-readings, run unattended from start to finish with the browser closed for at least one whole item. The run must appear in the history view with every item's graphs.
5. **Owner review of history.** The owner opens the full-length run in the history view and confirms it. This is the only human gate.
6. **PR body** lists the acceptance examples with a one-line result each and links the evidence bundle.

No unit tests are required for the executor. Tests may be added where they cost little, but "done" does not depend on them. Deleted tests from commit `adcd80a9` stay deleted.

## 2. Settled decisions

These were decided by the owner on 12 September 2026. Do not re-open them. The full question-and-answer log is in Appendix A.

| Topic | Decision |
|---|---|
| Goal shape | One monolithic goal. Section 5 is an internal build order, not a set of gates. |
| Display scope | LG webOS TVs only. Non-LG displays are refused at readiness. |
| Signal formats | Everything the existing AutoCal supports: SDR, HDR10, HLG, Dolby Vision, with the constraints the guided flow already enforces. |
| TV generations | All generations may run. On sets that cannot read back a value, the step is recorded as `unverified` and execution continues. Never recorded as verified, never treated as a failure. |
| Executor | A standalone `setsid` Perl runner launched by the daemon, driving the same `127.0.0.1` HTTP endpoints the browser uses. The browser is a viewer. |
| Storage | Own store under `/var/lib/PGenerator/automation/`. Artefacts copied in at every checkpoint. Retain until the user deletes. |
| Queue items | Full snapshots copied from a recipe at add time. Recipe edits never change queued or historical items. |
| Checkpoints | Worker boundaries (section 4.5). Pause lands at the next checkpoint. Resume restarts from the last verified one. |
| Pi reboot or daemon death mid-run | The run comes up `interrupted` with state preserved. The user presses Resume. No unattended auto-restart. |
| Exclusion | Global execution lock. Guided Full AutoCal, standalone AutoCal, series and DV-profile starts refuse while a queue run is active or paused. The queue refuses to start while any guided worker or meter session is alive. |
| Guided flow | Unchanged apart from the lock. |
| Recipe settings | Any of the 31 picture keys. Only explicitly set keys are enforced. |
| Panel light | Both policies from the design. The target-luminance loop is new capability and is built here (section 4.6). |
| Sweeps | Exactly the existing report sets: `greyscale-21`, `colors-30`, `saturations-24`. No new sweep types. |
| Quality checks | Per-item average and maximum dE limits per sweep, off by default. A miss flags the item and the queue continues. |
| TV hazards | Readiness check plus mitigation through the TV API where the API allows (section 4.10). |
| Extras | Per-item warm-up delay: in. Notifications, webhooks, recipe export and import: out. |
| Known bugs | Out of scope. Being fixed elsewhere. |
| Tests | No unit-test requirement. Do not restore deleted tests. |
| Live access | The agent deploys to the Pi, restarts the service, and drives the TV and meter itself (section 8). |
| Proof budget | Short smoke recipes freely, in any picture mode. One announced full-length proof at the end. |

## 3. Verified findings that change the design text

The design's "Existing implementation findings" section is accurate. These additional facts were verified on 12 September 2026 and shape the work:

1. **Nothing in the browser Full AutoCal is callable from Perl.** `meterStartFullAutoCal` (`webui-workspace.js:8200`) is reachable only from an `onclick`. The runner must re-implement: stage order (`webui-app.js:15338`), preflight reset and picture-mode guard (`webui-workspace.js:5739`, `5800-5823`), the greyscale payload (`webui-workspace.js:10019-10090`), 3D start retries and adoption (`11507-11541`), DV map-mode sequencing (`8261-8289`, `8439`), calibration-mode teardown before post readings (`8023-8078`), and report capture (`7863`).
2. **No panel-light control loop exists.** Neither worker reads or writes `oledLight`, `backlight` or `oledPixelBrightness`. Resets pin `BACKLIGHT_UI_DATA` to 80 (SDR) or 100 (HDR and DV). Peak luminance is handled entirely in the 1D LUT chain.
3. **All four resets move picture controls**: picture reset, SDR Calman, HDR Calman and DV Calman set brightness 50, colour 50, and contrast/backlight 85/80 (SDR) or 100/100 (HDR, DV), plus 32 general keys and 22 white-balance keys for the picture reset. Reapply-and-verify after every reset is mandatory, not optional.
4. **Report graphs need a live DOM.** Charts are canvases regenerated from saved readings (`webui-workspace.js:7936`, `18644`). There is no server-side renderer. The history view renders in the browser from stored readings.
5. **Worker `/tmp` state and logs are deleted at daemon startup.** Copy them into the run directory at every checkpoint, never only at the end.
6. **The daemon is SysV init plus a cron watchdog** that restarts it on a failed ping. Workers survive that restart because the stop script only kills the daemon processes. The runner will see HTTP failures during a restart and must retry.
7. **The 1D worker start path has no concurrency lock** (the 3D path has one). The runner is the single caller under the global lock.
8. **Apply-to-all support is generation-dependent.** The existing grading (`confirmed`, `acknowledged`, alert-bridge) is reused verbatim; generations that refuse readback record `unverified`. The live G3 target must be measured rather than inferred from the earlier G5 observation.
9. **Dolby Vision** uses greyscale plus a panel-profile upload, no 3D LUT. Readings need Absolute map mode with an ST 2084 target and P3-D65 gamut override; greyscale needs Relative. Each map-mode switch is a renderer restart of up to 25 s.
10. **The picture-settings passthrough is fixed to `category: "picture"`.** Auto power-off, no-signal power-off and screen-saver keys live in other webOS categories, so mitigating them needs a `category` parameter on the passthrough.
11. **Fragment golden-hash test is gone.** `t/webui_html_golden.t` and its hash were deleted in `adcd80a9`; the README still cites them. There is no automated guard on fragment bytes.
12. **The full-autocal report store** (`/var/lib/PGenerator/reports/full-autocal/`) has no list, read or delete endpoint. `PGAutoCalRun` prunes to ten runs on every start. Neither is a suitable history store.

## 4. Architecture contract

### 4.1 Runner process

- Script: `usr/bin/pgen_automation_runner.pl`. Core Perl plus the modules already on the appliance (`JSON::PP`, `Fcntl`, `File::Path`, `HTTP::Tiny` or the socket client already used by the workers). No new CPAN dependencies.
- Launched by `POST /api/automation/runs/start` exactly like the other workers (`webui.pm:6512` shape): `setsid`, stdin from `/dev/null`, stdout and stderr to `/var/lib/PGenerator/automation/runs/<run-id>/runner.log`. Runs as the `pgenerator` user like the daemon.
- Single instance: `flock` on `/var/lib/PGenerator/automation/runner.lock`. A second start returns `error_code: automation-active`.
- Writes `runs/<run-id>/run.json` atomically (tmp plus rename, and check the return values of `print`, `close` and `rename`) with a heartbeat timestamp at least every 5 s while alive. `runs/<run-id>/runner.pid` holds the PID; liveness is PID plus `/proc/<pid>/cmdline` match, never `pgrep` alone.
- Control file `runs/<run-id>/control.json` written by the daemon: `{"request":"pause"|"stop"|"none", "requested_at":...}`. The runner polls it at least every 2 s and between every HTTP call.
- Pause: finish the active stage, write its checkpoint, set `status: "paused"`, exit. Resume relaunches the runner with the same run id; it re-runs readiness, verifies the last checkpoint, continues.
- Stop: write the active worker's stop file through the existing stop endpoint, wait up to 60 s for the worker to exit on its own (workers poll the stop file), escalate through the existing kill endpoint only after that, close any held calibration session through `POST /api/lg/autocal/run/end` with `aborted`, mark the active stage `interrupted`, set `status: "stopped"`, exit. An interrupted stage is never presented as completed.
- Daemon restart or HTTP failure: retry every 5 s for up to 5 minutes for the same call, then fail the stage with `error_code: daemon-unreachable` and stop the queue with results preserved.
- Boot: `/etc/init.d/PGenerator` does not launch the runner. On daemon start, every run with `status: "running"` and no live runner PID is set to `status: "interrupted"`, the active stage to `interrupted`, and the UI offers Resume.
- Every HTTP request the runner makes carries the run's token in the body as `automation_token` so the lock (4.4) lets it through.
- Between items, and after any verified picture-mode switch, wait a settle period (default 8 s, configurable in the queue) before the first TV write or measurement. The operator has found back-to-back scripted switches unreliable across the tested generations.
- Test-only fault hook: if `/var/lib/PGenerator/automation/fault.json` exists, the runner reads `{"stage": <checkpoint name>, "mode": "error"}` and treats that stage's result as an explicit error once, recording `fault_injected: true` in the item and deleting the file. This is how A4 and similar failure paths are proved on real hardware without breaking the TV. It must never be created by the UI or the daemon.

### 4.2 Store

```
/var/lib/PGenerator/automation/
  recipes/<recipe-id>.json
  queues/<queue-id>.json
  runs/<run-id>/
    run.json            status, queue snapshot, item statuses, checkpoints, lock token
    control.json
    runner.log
    runner.pid
    items/<n>/
      item.json         the exact snapshot that ran, plus results index
      settings-checks.ndjson
      pre/<series-key>.json
      post/<series-key>.json
      calibration/      grey-state.json grey-log.txt 3d-state.json 3d-log.txt
                        emitted LUT files, DV profile measurements, final readings
      panel-light.json  loop iterations and settled value (target policy only)
      apply-all.json
      quality.json
```

- Ids: `YYYYMMDD-HHMMSS-<6 random hex>`, generated by the daemon. Lexical order is chronological.
- Every write is tmp plus rename with error checking. Every read-modify-write holds `flock(LOCK_EX)` on `<file>.lock`.
- Retention: nothing is pruned. Delete only through `DELETE`-style endpoints (4.3) and only what the user named. Rerunning a saved queue creates a new run directory.
- Series snapshot files use exactly the fields `meterRecoverSeries` consumes (`webui-workspace.js:7955-7971`): `type`, `points`, `steps`, `readings`, `white_reading`, `black_reading`, `signal_mode`, `target_gamma`, `max_luma`, `dv_map_mode`, `status`, `report_key`. That is what lets the existing chart code render history.
- The daemon creates and chowns `/var/lib/PGenerator/automation` in `/etc/init.d/PGenerator start` alongside the other `lg/` directories.

### 4.3 New endpoints

All under `/api/automation/`, routed on the `tv` lane so they serialise with the LG helper and never starve the meter lane (`webui.pm:917-941`).

| Endpoint | Purpose |
|---|---|
| `GET recipes`, `POST recipes`, `POST recipes/delete` | List, create or update, delete. |
| `GET queues`, `POST queues`, `POST queues/delete` | Same for saved queues. |
| `POST readiness` | Full readiness report for a queue (4.9). No TV writes. |
| `POST runs/start` | Readiness, lock, run directory, launch runner. Refuses with the readiness report when not ready. |
| `GET runs/current` | Live state: run, items, active stage, checkpoint, heartbeat age, lock owner. Polled by the UI every 2-3 s. |
| `POST runs/pause`, `runs/resume`, `runs/stop` | Control file writes; resume relaunches. |
| `POST runs/edit` | Add, edit, reorder or remove pending items of the active run. Refuses for the active or completed items. Marks changed items `recheck: true`; the runner re-runs per-item readiness before starting them. |
| `GET runs`, `GET runs/<id>`, `POST runs/delete` | History listing, one run with every item's series files, delete one run. |
| `GET runs/<id>/items/<n>/<file>` | Serve a stored artefact (series JSON, logs, LUTs) to the browser. |

### 4.4 Global execution lock

- `/var/lib/PGenerator/automation/execution.json`: `{owner: "automation", run_id, token, pid, updated_at}` while a run is `running`, `paused` or `interrupted`. Absent otherwise.
- The four guided start handlers (`webui_meter_lg_autocal_start`, `webui_meter_lg_3d_autocal_start`, `webui_meter_series_start`, DV profile start in `lg.pm`) and the meter-session start refuse with `error_code: automation-active` and a link to the workspace unless the request's `automation_token` matches. The Full AutoCal button and the other start buttons show the reason.
- `runs/start` refuses when `webui_meter_lg_autocal_running`, the 3D equivalent, the DV profile worker, or `/tmp/meter_session.pid` shows a live guided process.

### 4.5 Item execution and checkpoints

Stage order for one item, with the checkpoint written after each. Optional stages are skipped when disabled and their checkpoint recorded as `skipped`. Every checkpoint record carries `verified: true|false|"unverifiable"` and the evidence used.

| # | Checkpoint | What must be true |
|---|---|---|
| c0 | `item-started` | Readiness for this item re-run if `recheck` was set. |
| c1 | `tv-setup-verified` | Signal format applied (4.7). Picture mode selected and read back through the same endpoint `lgSetPictureMode` uses (`webui-lg.js:1658`). Pinned settings applied and verified (4.6). Hazard mitigations applied (4.10). Settle period elapsed. |
| c2 | `warmup-done` | Warm-up minutes elapsed showing a mid-grey pattern (item default 0). |
| c3 | `pre-readings-done` | Calibration mode confirmed off (three attempts as in `webui-workspace.js:8023-8078`). Existing calibration untouched. Each selected series run through `/api/meter/series` with the DV overrides where applicable, snapshot stored. |
| c4 | `reset-and-reapply-verified` | `POST /api/lg/autocal/run/begin` with `workflow: "automation"`. Preflight reset replicated from `meterAutoCalRunPreflightReset` (`webui-workspace.js:5739-5866`) including the 3D baseline reset for non-DV. Then pinned settings reapplied and verified. A reset that returns `calibration_session_unconfirmed` is recorded and the flag left set. |
| c5 | `panel-light-settled` | Target-luminance loop (4.6) converged, or fixed value re-verified. Value recorded. |
| c6 | `greyscale-done` | Greyscale worker launched with the payload shape of `webui-workspace.js:10019-10090` built from the item, polled to a terminal state, state and log copied. A terminal `error` fails the item and stops the queue. |
| c7 | `volume-done` | SDR, HDR10, HLG: 3D worker started with the retry and adoption logic of `webui-workspace.js:11507-11541`. If it ends with `upload_retry_available: true`, call `retry-upload` once automatically, then fail if still unverified. DV: profile stage as `webui-workspace.js:8578`. LUT files and states copied. |
| c8 | `session-closed` | Calibration mode off, verified by `/api/lg/status`. `run/end` posted with `complete`. Pinned settings verified again; drift handling per 4.6. |
| c9 | `apply-all-done` | Only when enabled and the item has a calibration stage. Pinned settings verified first. `POST /api/lg/picture-settings/apply-all-inputs`; outcome recorded from the response fields `confirmed`, `acknowledged`, `transport`, `readback_error`, `lg_generation` as one of `confirmed`, `unverified`, `failed`. Explicit error, `lg-calibration-session-held`, `apply-all-inputs-unsupported`: fail the item and stop the queue. |
| c10 | `post-readings-done` | Calibration mode off. Pinned settings verified. DV back to Absolute. Series run and stored. Quality limits evaluated (4.8). |
| c11 | `item-complete` | Item status `complete`, `complete-with-warnings`, or `failed`. |

Resume rules: on relaunch the runner re-runs readiness, then re-verifies the last written checkpoint before continuing. c1, c4, c8, c9 and c10 are re-verifiable by readback. c6 is valid if `grey-state.json` shows a terminal `complete` and the DDC upload was verified in that state. c7 is valid if `3d-state.json` shows a verified commit (or the DV upload acknowledged) and the emitted LUT files exist. Anything not re-verifiable restarts from c4. An apply-all failure resumes at c9 without repeating c4 to c8.

### 4.6 Settings authority and enforcement

- The item pins any subset of the 31 keys in `LG_DISPLAY_CONTROL_ITEMS` (`webui-lg.js:245`). The recipe editor shows only keys the paired TV reports in `supported_picture_keys` (`pgenerator-lg:1325` capability payload). Unpinned keys are left to whatever the reset produces.
- Apply: one key per `POST /api/lg/picture-settings/set` call, as `lgDisplayControlCommit` does (`webui-lg.js:1082`), with `picture_mode`, `signal_mode`, and `readback_keys: [key, "pictureMode"]`. Panel-light keys already take their own ladder inside the helper.
- Verify: one `POST /api/lg/picture-settings` read of all pinned keys plus `pictureMode`. A number matches within 0.1; a string matches case-insensitively. Up to three apply-and-verify cycles per verification point.
- Verification points: c1, c4, c5, c8, c9, c10. Each writes a line to `settings-checks.ndjson` with the expected and observed values.
- Unverifiable: a response with `virtual_picture_settings`, `manual_confirmation_required`, `picture_mode_read_forbidden` or a key in `unsupported_picture_keys` after a successful write records the check as `unverifiable` and continues. Never `verified`.
- Drift: a pinned key observed wrong after c8 (post-calibration) is reapplied and verified, the item is marked `settings-drift`, and c4 to c8 are repeated once. A second drift fails the item and stops the queue. A pinned key wrong at c1 or c4 after three cycles fails the item and stops the queue.
- Panel-light policy:
  - `fixed`: the pinned panel-light key (`oledLight`, `oledPixelBrightness` or `backlight`, whichever the TV supports) is reapplied after every reset and never adjusted.
  - `target`: SDR items only in this goal. The existing workflow suppresses luminance targets for HDR (`webui-workspace.js:9963`), so HDR10, HLG and DV items are refused at readiness with `target luminance not supported for this format`. At c5, with calibration mode off: read a 100 % white patch with the item's patch size and delay; compare with the item's target luminance (default 100 nits, the same field the greyscale payload sends as `target_luminance`); adjust the panel-light key proportionally (luminance is close to linear in `oledLight` on LG OLED); re-read; converge within 3 % or 2 nits, whichever is larger; at most 8 iterations; clamp 0 to 100. Every iteration is recorded in `panel-light.json`. If the clamp is reached and the target is still out of reach, record a quality warning `panel-light-target-unreachable` and continue with the clamp value. From c5 onward the settled value is the enforced value for that key. It is never overwritten with the recipe's initial value.
- Values produced by calibration (white-balance keys, DDC curves, LUTs) are never enforced by the runner and never reverted.

### 4.7 Signal format and Dolby Vision sequencing

- `signal_format` is one of `sdr`, `hdr10`, `hlg`, `dv`. It is applied through `POST /api/config` the way the guided Apply Settings modal does, then the runner waits for the renderer restart to finish (poll `/api/ping` and `/api/config` until the new `signal_mode` is reported and a pattern request succeeds).
- Picture mode must be valid for the format; `lg_picture_mode_signal_compatible` (`pgenerator-lg:247`) is the authority, HLG counting as HDR10.
- Calibration items require a mode `lg_calibration_mode_workflow` accepts (`pgenerator-lg:7521`) and one matching `$WRITABLE_PICTURE_MODES_RE` (`pgenerator-lg:2521`). Measurement-only items may use any mode the TV offers.
- DV: readings (c3, c10) use `dv_map_mode "1"`, target gamma `st2084`, gamut override `p3d65`, as `webui-workspace.js:7901`. Before c6 switch to `"2"`. When pre-readings are skipped go straight to Relative. Each switch is a renderer restart; wait for it. Target gamma for the DV greyscale is always 2.2 (`meter_lg_autocal.pl:14518`).
- HDR10 forces matrix-only profiling (`webui-workspace.js:8237`). Non-HDR default profiling is the hybrid 5³ lattice, series id 923 (`webui-workspace.js:6588-6604`).

### 4.8 Pre- and post-readings and quality checks

- Series keys and labels come from `meterFullAutoCalReportSeries()` (`webui-app.js:3832`): `greyscale-21`, `colors-30`, `saturations-24`. Pre and post default to the same selection; both editable per item.
- Each series is run through `POST /api/meter/series`, polled on `/api/meter/series/status`, and snapshotted with the filter `meterFullAutoCalSnapshotForKey` applies (`webui-workspace.js:6478-6491`).
- Calibration-only items keep their final calibration readings and graphs from `grey-state.json` and `3d-state.json` even when both sweeps are disabled.
- Quality: `item.quality = {enabled: false, dE_formula: <item's delta_e_formula>, limits: {<series-key>: {avg, max}}}`. Evaluated on post-readings only. A miss writes `quality.json` with the offending series and values and sets the item to `complete-with-warnings`. The queue continues.

### 4.9 Readiness

`POST /api/automation/readiness` returns a structured report with `ready: true|false` and one entry per check. `runs/start` and every Resume run it. No TV writes.

Checks: LG TV paired, reachable, model and generation known; meter detected and not simulated; no guided worker or meter session alive; disk space for the run; for each item: picture mode exists on this generation's list (`lgPictureModesForSignal`, `webui-lg.js:309`) and is compatible with the format; calibration items use a calibration-mappable and writable mode; every pinned key is in `supported_picture_keys`; apply-to-all enabled only where `lg_apply_all_inputs_generation_support` (`pgenerator-lg:5862`) is not 0; `target` panel-light policy only on SDR items; DV items only when the format is supported for this generation; at least one stage enabled.

A readiness failure names the item and the check. Items are never silently skipped.

### 4.10 TV hazards

- Readiness reads and reports `energySaving`, `aiPicture` (when the TV exposes it), and any auto-off, no-signal power-off and screen-saver keys the implementer can establish on the target webOS generation. Establishing those keys is part of this goal: extend the passthrough with an optional `category` parameter (default `picture`) and probe the settings service with `getSystemSettings` on the candidate categories.
- For every item: `energySaving` and `aiPicture` are pinned `off` for the item unless the recipe pins them otherwise, using the same apply-and-verify path as any pinned key. The DV profile preflight already does this for one stage (`pgenerator-lg:4154`); the runner does it for all.
- Where auto-off or screen-saver keys are controllable: readiness records their values, `runs/start` disables them, and the runner restores them when the queue finishes, stops or fails. Where they are not controllable: readiness lists them as named preconditions the user must set manually, and the report says so.
- Keep-alive: while waiting on a worker the runner polls `/api/lg/status` every 60 s. A TV that reports standby or stops answering fails the active stage with `error_code: tv-unreachable`, which stops the queue with results preserved.
- Socket drops during a helper call are handled by the helper's own routes; the runner retries the stage's current call up to three times before failing.

### 4.11 User interface

- New fragments `usr/share/PGenerator/webui-automation.html` (card) and `usr/share/PGenerator/webui-automation.js`, added to the allow-list (`webui.pm:12772-12782`) and the marker splices in `webui_html` (`webui.pm:12931-12975`). Strict-mode clean, UTF-8, LF, no banner comments, never run a formatter over any fragment.
- Views: **Recipes** (create, edit, duplicate with a different picture mode, delete), **Queue** (add from recipe, reorder, edit pending, save queue, readiness panel, Start, Pause, Resume, Stop), **Live** (current item, current stage, checkpoint, heartbeat age, per-item status list, updates while other tabs or no tabs are open), **History** (all runs newest first, open a run, every item's graphs rendered through the existing report builder from the stored series files, quality warnings and apply-all status visible, delete run).
- The existing Full AutoCal button and other starts show the lock reason when refused.

## 5. Build order

Internal ordering so live smoke proofs are possible early. None of these is a gate.

1. Access and baseline: reach the Pi and TV (protocol doc), deploy an unchanged tree, confirm the guided flow still works, record the TV model, firmware and supported keys.
2. Store, endpoints, lock, runner skeleton that runs a measurement-only item end to end and survives a daemon restart and a closed browser.
3. TV setup stage: format, mode, pinned settings, verification, settle, warm-up.
4. Readings stage with stored series that the existing chart code can render.
5. Calibration stage: reset, reapply, greyscale, volume or DV profile, session close, `run/begin` and `run/end`, artefact copying.
6. Apply-to-all and post-readings, quality checks.
7. Pause, stop, resume, interrupted-on-boot, edit-while-running.
8. Panel-light target loop.
9. Hazard mitigation and readiness completeness.
10. Workspace UI and history view.
11. Full-length proof, evidence bundle, PR.

## 6. Acceptance examples

The eight from the design, each with how it is proved live, plus five added by the interview.

| # | Example | Proof |
|---|---|---|
| A1 | HDR Filmmaker item with fixed OLED pixel brightness applies and verifies the value before pre-readings and again after the calibration reset. | `settings-checks.ndjson` shows the pinned value verified at c1 and at c4, with the reset in between having moved it. |
| A2 | Calibration-only item keeps final calibration graphs, performs apply-to-all, advances without sweeps. | Item directory has `calibration/` with final readings, `apply-all.json`, no `pre/` or `post/`; history renders the greyscale graphs. |
| A3 | Measurement-only item applies its settings, measures without resetting calibration, keeps graphs. | No `run/begin` in the LG run store for the item; no reset in `lg/last-write.log` during it; `pre/` present. |
| A4 | An apply-to-all failure stops the queue. Resume retries the copy without repeating a valid calibration. | Force a failure (for example, start with a held session), observe the stop, resume, observe c9 rerun with c4 to c8 untouched by timestamps. |
| A5 | Two items in the same mode run consecutively without an acknowledgement; both result sets remain. | Two item directories, both openable in history. |
| A6 | Closing the browser does not stop execution; reopening shows current progress and saved results. | Close every tab for at least one whole item; `runner.log` and checkpoint timestamps continue; reopen and see the state. |
| A7 | Rerunning a saved queue preserves the earlier run including failed or partial results. | Two run directories, both listed. |
| A8 | A quality warning or an unverified copy is visible in history and never reported as a failure or verified success. | `quality.json` and `apply-all.json` render as warnings; the item status is `complete-with-warnings`. |
| A9 | Guided Full AutoCal refuses to start while a queue is active or paused, and the queue refuses to start over a guided worker. | Both refusals observed with their messages. |
| A10 | Pause lands at the next checkpoint, Resume continues from it; Stop mid-worker marks the stage interrupted and closes the calibration session. | Checkpoint records and `/api/lg/status` showing calibration mode off after Stop. |
| A11 | A daemon restart during a worker stage does not lose the run; a Pi reboot leaves it `interrupted` and resumable. | Restart the service mid-stage and see the run continue. Reboot is the owner's call; if not exercised, prove the boot marking with a killed runner instead. |
| A12 | An SDR item with the `target` panel-light policy settles within tolerance and the settled value survives the reset and is the value enforced afterwards. | `panel-light.json` iterations, and c8 to c10 checks showing the settled value. |
| A13 | The full-length multi-mode run of section 1 item 4 completes and is reviewed by the owner. | History entry. |

## 7. Constraints on the implementation

### 7.1 Do not change

- Guided Full AutoCal behaviour, dialogs and ordering, apart from the lock refusal.
- The worker scripts' measurement or solver logic. Adding a config flag or a status field is fine; changing what they measure or upload is not.
- The helper `usr/sbin/pgenerator-lg` beyond adding the `category` parameter and any read-only probes readiness needs.
- Anything under `var/` in the repo, `etc/PGenerator/PGenerator.conf`, and the untracked `/usr/bin/pgen_lut_solve` on the Pi.

### 7.2 Known-bug handling

The entries in `full-automation/KNOWN-BUGS-OUT-OF-SCOPE.md` are being fixed elsewhere. Do not fix them here. Where one affects the queue, record the observed effect in the run (for example an unconfirmed commit surfaced by state fields) rather than working around it with changes to the affected code. If one blocks an acceptance example on the live TV, say so in the PR with the FAB id and the evidence, and finish everything else.

### 7.3 Fragments

Follow `README-webui-fragments.md` for byte hygiene. Correct its two stale verification commands to state that the golden test and packaging checker were removed in `adcd80a9` and that fragment bytes are currently unguarded.

### 7.4 Commit hygiene

Small commits with plain messages. Never commit `Bugs/`, evidence bundles, or anything from the Pi's `var/`. The evidence bundle lives outside the repository (protocol doc) and is linked from the PR.

## 8. Agent authorisations

Allowed without asking:

- Deploy `usr/` to the Pi with `rsync -rl --no-perms --no-owner --no-group --exclude='__pycache__/'` and no `--delete`; set modes explicitly on new files; restart with `/etc/init.d/PGenerator restart >/tmp/pgstart.log 2>&1`.
- Drive the paired TV and the attached meter through the web UI and its API, in any picture mode, with short smoke recipes as often as needed.
- Read anything on the Pi; copy run directories, `lg/last-write.log*` and `/tmp` logs to the Mac.

Ask first:

- The one full-length proof run (announce the queue contents and expected duration, then proceed unless told otherwise).
- Rebooting the Pi.

Never:

- Change the Pi's network configuration, hostname, or init scripts beyond the directory creation in 4.2.
- Sync `var/` or `PGenerator.conf`, delete `lg/clients.json` (TV pairing), or delete `meter_settings.json`.
- Factory-reset the TV, change its network or input settings, or use the Magic Remote paths.
- Touch `/usr/bin/pgen_lut_solve`.
- Merge the PR.

## 9. Non-goals

Fixing entries in `Bugs/`; notifications or webhooks; recipe or queue export and import; non-LG displays; server-side graph rendering; new sweep types or patch lists; restoring deleted tests; a fake LG TV or a workstation end-to-end harness; changing the guided flow; multi-TV queues; scheduling runs for a later time.

## 10. Facts established during this run

- The live Pi is reachable through the `pgen` SSH alias at `192.168.50.110`. Its paired display is the owner's LG `OLED55G36LA`, G3 generation, webOS 23, software release `9.2.2`; the G5 facts above do not describe this proof target.
- The G3 exposes `pictureMode`, `backlight` and `energySaving` through the current settings path. It does not expose the G5-specific `oledPixelBrightness` key used by the original smoke recipe.
- The G3 supports the current automation readiness path with manual hazard warnings for `aiPicture`, auto power-off, no-signal power-off and screen saver controls.
- The runner uses the same local HTTP endpoints as the guided flow, passes its automation token through worker callbacks, and records stage, checkpoint and worker launch transitions in `runner.log`.
- Line numbers cited in this file and the fact documents drift as code changes; re-grep before editing.

## Appendix A: interview decisions, 12 September 2026

| # | Question | Decision |
|---|---|---|
| 1 | Goal shape | One monolithic goal. |
| 2 | Signal formats | Everything the existing AutoCal supports. |
| 3 | Proof | The agent has live access to the TV, meter and Pi and proves things itself. |
| 4 | Quality checks | Per-item average and maximum dE limits per sweep on post-readings, off by default, flag and continue. |
| 5 | TV hazards | Readiness check plus API mitigation where possible. |
| 6 | Output | This file next to the design. |
| 7 | Git | Feature branch, one PR at the end. |
| 8, 20 | Known bugs | Initially "named blockers in scope", revised to "ignore, fixed elsewhere". The revision stands. |
| 9 | Agent access | Deploy to Pi, restart service, drive TV and meter, with the prohibitions in section 8. |
| 10 | Proof budget | Smoke recipes freely; one announced full-length proof. |
| 11 | Protecting existing calibration | Any picture mode is fair game during proofs. The real use is several SDR modes then several HDR modes in the user's order. |
| 12 | Display scope | LG webOS only. |
| 13 | Sweeps | Exactly the existing three report sets. |
| 14 | Exclusion | Global execution lock. |
| 15 | Reboot | Come up interrupted, user resumes. |
| 16, 17 | Extras | Warm-up delay in. Notification was ticked then withdrawn: out. Export and import out. The owner's stated priority is being able to look back over previous results. |
| 18 | Done | PR open, CI green, full-length live proof passed, history reviewed by the owner. |
| 19 | Executor | Standalone setsid runner over the local HTTP API. |
| 21 | Storage | Own store under `/var/lib/PGenerator/automation`, artefacts copied in. |
| 22 | Checkpoints | Worker boundaries. |
| 23 | Panel light | Build the target-luminance loop. |
| 24 | Generations | All, best effort with `unverified` on sets that cannot read back. |
| 25 | Recipe keys | Any of the 31 keys; only explicitly set keys enforced. |
| 26, 27 | Tests | Live proof only; no unit-test requirement; deleted tests stay deleted; fix the stale README text. |
| 28 | Recipes | Queue items are full snapshots copied at add time. |
| 29 | Guided flow | Unchanged apart from the lock. |
