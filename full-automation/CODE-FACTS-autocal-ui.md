> Code facts gathered 12 September 2026 against commit 42a6f3e8 for FULL_AUTOMATION_GOAL.md. Line numbers drift; re-grep before relying on one. Read-only survey, no design proposals.

# Full AutoCal orchestration and test infrastructure — facts

Repo: `/Users/garry.casey/Desktop/personal/PGenerator-Plus`
Branch: `main` @ `42a6f3e8`. Read-only investigation. All paths absolute unless a bare `t/…` or `usr/…` is shown inside a code block.

---

## 1. Full AutoCal stage sequence, configuration, and state

### 1.1 Entry point

`usr/share/PGenerator/webui-workspace.js:8200` — `async function meterStartFullAutoCal()`.

Preconditions checked in order at `webui-workspace.js:8201-8208`:

| Line | Guard |
|---|---|
| 8201 | `meterBlockAutoCalForSimulation()` — refuses when the simulated meter is active |
| 8202 | no other meter operation in progress |
| 8203 | `meterEnsureDetected()` |
| 8204 | `meterFullAutoCalAvailable()` — LG TV connected (`webui-workspace.js:3585`) |
| 8205 | `meterEnsureLgTvReadyForAutoCal('Full Auto Cal')` |
| 8206 | `meterEnsureLgAutoCalTransport('Full Auto Cal')` |
| 8207 | `meterEnsureLgAutoCalExtendedVideoTransport()` |
| 8208 | `meterEnsureAppliedGeneratorSettings()` |

### 1.2 Canonical stage order

`usr/share/PGenerator/webui-app.js:15338` — `meterFullAutoCalStageOrder()`:

```js
if(!skipPre) stages.push('precal-report');          // :15342
stages.push('first-greyscale');                      // :15343
if(dvSignal){ stages.push('dv-profile'); }           // :15347
else { stages.push('3d-lut');                        // :15349
       if(meterFullAutoCalPostCommitPolishEnabled()) stages.push('post-3d-polish'); } // :15350
stages.push('postcal-report','complete');            // :15352
```

Labels at `webui-app.js:15355-15367` (`meterFullAutoCalStageLabel`).
Stage index at `webui-app.js:15304` (`meterFullAutoCalStageIndex`).

| Order | Phase id | Set at | Notes |
|---|---|---|---|
| 0 (pre-phase) | preflight reset | `webui-workspace.js:5739` | not in stage order; runs inside the greyscale start |
| 1 | `precal-report` | `webui-workspace.js:8260` | skipped if operator picks Skip Pre-Cal |
| 2 | `first-greyscale` | `webui-workspace.js:8351` | 26-point greyscale AutoCal |
| 3a | `3d-lut` | `webui-workspace.js:8366`, `8418` | SDR / HDR10 |
| 3b | `dv-profile` | `webui-workspace.js:8578` | Dolby Vision replaces the 3D LUT stage |
| 4 | `post-3d-polish` | `webui-workspace.js:8803` | **unreachable** (see 1.3) |
| 4' | `touchup-greyscale` | `webui-workspace.js:8972` | **unreachable** (see 1.3) |
| 5 | `postcal-report` | `webui-workspace.js:8096` | operator-triggered from the completion dialog |
| 6 | `complete` | — | terminal |

### 1.3 Dead phases in this build

`touchup-greyscale` and `post-3d-polish` cannot be reached:

- `webui-workspace.js:6617-6619` — `meterFullAutoCalPostCommitPolishEnabled()` returns `false` unconditionally.
- `webui-workspace.js:6621-6623` — `meterFullAutoCalPostCommitVerifyEnabled()` returns `false`.
- `webui-workspace.js:6624-6626` — `meterFullAutoCalPostTouchupEnabled()` returns `false`.
- `webui-workspace.js:7152-7154` — `meterFullAutoCalTouchupChoiceValue()` returns `false`.
- `webui-app.js:3817` — `const METER_FULL_AUTOCAL_TOUCHUP_DISABLED=true;`
- `webui-workspace.js:8789-8793` — `meterFullAutoCalStartPost3dPolish` returns `false` immediately when polish is disabled.
- `webui-workspace.js:8915-8931` — `meterFullAutoCalStartTouchup` short-circuits into `meterFullAutoCalCompleteAfterHdrToneMap(..., {skipTouchup:true}, '3d-lut')`.

The bodies still exist (roughly `webui-workspace.js:8789-9010`) but are unused code paths.

### 1.4 Preflight reset

`usr/share/PGenerator/webui-workspace.js:5739` — `meterAutoCalRunPreflightReset()`.

- `webui-workspace.js:5770` — `POST /api/lg/autocal/run/begin` opens the server-side run record. Body carries `ip`, `workflow` (`'full'` vs `'greyscale2pt'`), `controller_id`, `client_run_token`, and a `config` block of `signal_mode`, `picture_mode`, `target_gamma`, `target_gamut`, `luminance_target`. Wrapped in try/catch: "diagnostics only: never block cal".
- `webui-workspace.js:5791` — `meterAutoCalResetDdc` via `meterAutoCalResetWithRecovery('LG picture-mode reset', …)`.
- `webui-workspace.js:5827` — `meterAutoCalReset3dLutBaseline`, **full workflow only**.
- `webui-workspace.js:5708` — `meterAutoCalResetWithRecovery(name,fn,hint)` wraps each reset. On terminal failure it offers Continue / Retry / Cancel. Continue records the skip in `meterAutoCalResetSkipped` (`:5733`) so it is surfaced, never silent.
- Picture-mode guard `webui-workspace.js:5800-5823`: refuses to start when no picture mode is selected (`:5819`), when a readable set reports a different mode (`:5814`), or when a non-readable set's last-written mode disagrees (`:5822`).
- Reset summary is folded into the wizard config and report at `webui-workspace.js:5831-5866`, and archived with stage `preflight-reset` at `:5866`.

### 1.5 Configuration

Default config: `usr/share/PGenerator/webui-workspace.js:6560` — `meterFullAutoCalDefaultConfig()`.
Live stamp: `webui-workspace.js:8292-8302`.

Fields: `signalMode`, `method`, `profileSource`, `latticeSeriesId`, `upload`, `targetDelta`, `targetY`, `setupY`, `headroomY`, `dtype`, `patternSignalRange`, `wp`, `preCalSkipped`, `postCommitPolishEnabled`, `shadowFixEnabled`, `darkDetailEnabled`, plus `preflightReset` (added at `:5862`) and `deltaEFormula` (added at `:9980`).

- HDR10 is forced matrix-only: `webui-workspace.js:8237-8240` and `6567-6586`.
- Non-HDR default profiling is hybrid 5³, series id **923**: `webui-workspace.js:6588-6604`.
- Dark Detail rebuilds the greyscale ladder at `webui-workspace.js:8315-8322` (`meterBuildStepsJS('greyscale',26)`), because the ladder is otherwise built before the option dialog.

Operator choices come from `meterFullAutoCalConfirmDialog` at `webui-workspace.js:8219`:
`showPostCalTouchupChoice`, `showShadowFixChoice` (HDR10 only), `showDarkDetailChoice`, `showProfilingChoice` (not HDR10, not DV).
Workflow description text: `webui-workspace.js:6514-6560` (`meterFullAutoCalPromptDefaults`), with separate DV / HDR10 / SDR stage wordings.

### 1.6 Worker payloads

**Greyscale** — `POST /api/meter/lg-autocal`, body built at `webui-workspace.js:10019-10090`:

```
type:'greyscale', points:26, lg_autocal_26:true, lg_greyscale_21:false,
display_type, ccss_override, delay_ms, patch_size,
signal_range, pattern_signal_range,
dark_detail (omitted when off),
lg_autocal_26_full_ddc_spine, lg_extended_sdr_16_255,
target_delta_e, delta_e_formula,
target_luminance, setup_luminance_reference, headroom_target_luminance,
target_gamma, target_white:{x,y}, picture_mode,
force_ddc_white_balance:true, lg_autocal_sdr_1d_dpg_upload_enabled:true,
restore_factory_levels:false, reset_ddc_baseline:false,
full_workflow / full_autocal_run_id / full_autocal_phase (full workflow only),
max_iterations:36, headroom_max_iterations:60,
max_polish_iterations:16, precision_polish_iterations:18,
low_light, refresh_rate, require_device_ready:false, steps:autocalSteps
```

Iteration caps are at `webui-workspace.js:10083-10086`. Luminance targets are suppressed for the HDR workflow at `webui-workspace.js:9963-9965`.

**3D LUT** — `POST /api/meter/lg-3d-autocal/start` at `webui-workspace.js:11509`, inside a 5-attempt loop (`:11507`) that only re-tries while the greyscale worker is still finishing (`meterFullAutoCalTransitionBusy`, `:11516`), with backoff honouring `retry_after_ms` capped at 3 s (`:11519`). On a null/error response it probes `/api/meter/lg-3d-autocal/status` and adopts a running worker whose run id matches (`:11532-11541`).

Start options for the full workflow are assembled at `webui-workspace.js:8398-8405`, with a config snapshot taken at `:8410-8412` so a failed start can be retried after `meterFullAutoCalResetState` clears state, then one re-attempt after an `/api/lg/status` refresh and a 4 s wait (`:8415-8425`).

### 1.7 Browser state

Key constants: `usr/share/PGenerator/webui-app.js:3814-3821`.

| Key | Storage | Written at | Contents |
|---|---|---|---|
| `meterFullAutoCalState` | localStorage | `webui-workspace.js:7174` | `active`, `controllerId`, `phase`, `runId`, `recordRunId`, `recordToken`, `startedAt`, `config`, `report`, `updated` |
| `meterFullAutoCalReportData` | localStorage | `webui-workspace.js:6329` | full pre/post report document |
| `meterFullAutoCalCompleteToken` | localStorage | `webui-workspace.js:7295` | completion dedup tokens |
| `meterAutoCalState` | localStorage | `webui-workspace.js:6406` | greyscale-only sibling state |
| `meterFullAutoCalLastReset` | localStorage | `webui-workspace.js:4537`, `7479` | forensic crumb: who reset the wizard |
| `meterFullAutoCalLastProfiling` | localStorage | `webui-workspace.js:7639` | last profiling choice |
| `meterHdrToneMapPromptChoice` | localStorage | `webui-workspace.js:6752`, `6889` | per-TV tone-map prompt answers |
| `pgen.meter.lg3dTargetRestore` | localStorage | `webui-workspace.js:10880`, `10901` | target dropdown restore for standalone 3D |
| `meterFullAutoCalControllerId` | **sessionStorage** | `webui-workspace.js:7194-7200` | per-tab identity, `tab-<base36>-<rand>` |

Lease/adoption model:

- `webui-workspace.js:7213` — `const METER_FULL_AUTOCAL_LEASE_MS=3*60*1000;`
- `webui-workspace.js:7191` — 30 s heartbeat `setInterval` refreshing the saved state while running.
- `webui-workspace.js:7162-7172` — a save is refused when another tab holds a live lease on the same run id.
- `webui-workspace.js:7218` — lease-expiry test; an expired record is adoptable by another tab.
- `webui-workspace.js:6452-6475` — on page load, both worker statuses are polled first; if neither is running the saved state is discarded rather than resurrected.
- `webui-workspace.js:7431-7484` — `meterFullAutoCalRestoreSavedState()` re-enters the correct phase (`3d-lut` at `:7456`, report phases at `:7458`).

### 1.8 Server-side state

- Worker state files `/tmp/meter_lg_autocal.json`, `/tmp/meter_lg_3d_autocal.json`.
- Run records under `/var/lib/PGenerator/lg/autocal-runs/` (section 4.4).
- Report state JSON under `/var/lib/PGenerator/reports/full-autocal/` (section 2.4).
- The Perl side treats `full_workflow` / `full_autocal_phase` / `full_autocal_run_id` / `full_autocal_post_*` / `full_autocal_touchup` as opaque stamps it can clear: `usr/share/PGenerator/webui.pm:6123-6138`.

---

## 2. The before/after report

### 2.1 Measurement sets

Declared twice, identically:

- `usr/share/PGenerator/webui-app.js:3822-3826` — `const METER_FULL_AUTOCAL_REPORT_SERIES` (not referenced anywhere else; dead).
- `usr/share/PGenerator/webui-app.js:3832-3835` — `meterFullAutoCalReportSeries()`, the live source.

| key | type | points | label |
|---|---|---|---|
| `greyscale-21` | `greyscale` | 21 | `Greyscale 21pt` |
| `colors-30` | `colors` | 30 | `ColorChecker` |
| `saturations-24` | `saturations` | 24 | `Sat Sweep` |

Total 75 reads per side; used as the progress weight at `webui-app.js:15396` and `15423`.

### 2.2 Capture

`usr/share/PGenerator/webui-workspace.js:7863` — `meterFullAutoCalCaptureReportSet(stage)` where `stage` is `'pre'` or `'post'`.

- `:7869-7873` — initialises `data[stage]`, `data.stages[stage] = {status:'running', started_at, series:{}}`, saves, archives `<stage>-started`.
- `:7876` — `meterClearAutoCalStatusPollingForReport()` (also `webui-app.js:15375`) stops the AutoCal pollers so they cannot mistake a report read for a worker run.
- `:7880-7926` — per-series loop: `meterSelectSeries(item.type,item.points,{force:true,bypassCache:true})` awaited (`:7896`), then `meterRunSeries` (`:7901`) with `dvMapModeOverride:'1'` and `targetGamutOverride:'p3d65'` for DV, then `meterFullAutoCalWaitForSeriesComplete`.
- `:7916` — `meterFullAutoCalSnapshotForKey(item.key)` captures the finished series; snapshot builder at `webui-workspace.js:6478-6491` filters to readings with luminance and stamps `report_key`.
- `:7919-7925` — per-series stage record `{status:'complete', completed_at, readings:<count>}`, saved and archived as `<stage>-<series key>`.
- `:7928-7931` — stage marked complete, archived as `<stage>-complete`.

Post-cal only: `meterFullAutoCalGeneratePostReport` at `webui-workspace.js:8085` first forces LG calibration mode **off** via `meterFullAutoCalEnsureCalibrationModeOff` (`webui-workspace.js:8023`), three attempts, each verified by a fresh `/api/lg/status` read (`:8060-8070`). It also re-points Target Gamma per signal mode at `webui-workspace.js:8118-8150` (HDR10 → `st2084`, SDR → `bt1886` when unset, DV → Absolute map mode plus `st2084`).

### 2.3 Data model

`meterFullAutoCalDefaultReportData()` at `webui-workspace.js:6301`; save/load/clear at `:6305`, `:6317`, `:6333`; run-freshness guard `meterFullAutoCalEnsureReportRun` at `:6361`.

Top level: `run_id`, `started_at`, `updated_at`, `signal_mode`, `pre_cal_skipped`, `reset`, `stages{pre,post}`, `pre{…}`, `post{…}`.

Each `pre`/`post` map is keyed by series key and holds a series snapshot: `type`, `points`, `steps`, `readings`, `white_reading`, `black_reading`, `signal_mode`, `target_gamma`, `max_luma`, `dv_map_mode`, `status`, `report_key` (fields enumerated at the replay site, `webui-workspace.js:7957-7970`).

### 2.4 Endpoints and persistence

Exactly one endpoint: **`POST /api/meter/full-autocal/report-state`**.

- Client: `webui-workspace.js:6380-6400` — `meterFullAutoCalArchiveReportData(stage,extra)` posts `{run_id, stage, saved_at, report, config, results, extra}`, `_quiet:true`, 6 s timeout, errors swallowed.
- Route: `usr/share/PGenerator/webui.pm:1968-1969`.
- Handler: `usr/share/PGenerator/webui.pm:5950-5980`. Sanitises `run_id` to `[A-Za-z0-9_.-]`, tries `/var/lib/PGenerator/reports/full-autocal` then `/tmp/PGenerator_full_autocal_reports`, `mkdir -p` (with a `sudo` fallback and `chmod 0777`), writes `<run_id>.json` via tmp + `rename`, `chmod 0666`, returns the path.

One file per run id, overwritten on every stage transition.

### 2.5 Graph regeneration

Charts are **not** stored. Regeneration replays saved readings through the live DOM:

- `webui-workspace.js:7936` — `meterFullAutoCalBuildSnapshotReportSections(entries)`. Backs up `meterSeriesCache` (`:7945`), and per entry calls `meterRecoverSeries({type,points,steps,readings,white_reading,black_reading,signal_mode,target_gamma,max_luma,dv_map_mode,…})` at `:7955-7971`.
- `webui-workspace.js:18566` — `meterPrepareCurrentSeriesForReport()`; `webui-workspace.js:18562` — `meterReportNextPaint()` waits two `requestAnimationFrame` ticks so the canvases are painted.
- `webui-workspace.js:18644` — `meterBuildCurrentSeriesReportSection(title)` snapshots the live canvases: greyscale takes Low/High RGB balance, `chartRGB`, `chartDeltaE`, `chartGammaValue`, `chartEOTF`, `chartGamma` (`:18652-18658`); colour series force CIE to 2D (`:18663-18672`), then take `chartCIE` and `chartColorDE`.
- `webui-workspace.js:7975-7986` — the operator's own series cache, selection, pinned reading, current patch and thumb are restored afterwards.
- `webui-workspace.js:18694` — `meterBuildReportDocument(sectionHtml,documentTitle)` wraps it in a standalone light-theme HTML document.
- `webui-workspace.js:8014-8022` — `meterFullAutoCalDownloadReport(filename)` → `meterDownloadBlob(new Blob([html],{type:'text/html'}),filename)`.

**Consequence for any headless executor:** report generation requires a live, rendered browser with the real chart canvases. There is no server-side renderer.

Entry selection (which sections appear, and the "no pre-cal" notice) is at `webui-workspace.js:7991-8012` (`meterFullAutoCalReportEntries`).

Filename: `meterDefaultExportFilename('report','pgenerator_full_autocal_report','html')` at `webui-workspace.js:8088`.

### 2.6 List / browse / delete

**None exists.**

- The generated HTML goes only to the browser's download stream (`webui-workspace.js:8021`); it is never stored server-side.
- The per-run JSON files are written but never listed, served, enumerated, or pruned by any endpoint. `grep` for `reports/full-autocal` yields only two sites: the writer at `webui.pm:5958` and the diagnostics reader at `webui.pm:10514`.
- The diagnostics bundle inlines **only the newest** report file: `webui.pm:10512-10521`.
- There is no delete or retention policy for `/var/lib/PGenerator/reports/full-autocal/`.

---

## 3. Quality thresholds, pass/fail limits, dE targets

### 3.1 In the UI: no pass/fail gate anywhere

What exists is presentation only.

| Concern | Location | Behaviour |
|---|---|---|
| dE colour bands | `webui-workspace.js:15396`, `webui-workspace.js:15514`, `webui-app.js:14216` | `dE<1` green `#4caf50`, `dE<3` amber `#ff9800`, else red |
| Target dE input | `webui-workspace.js:4866-4873` (`meterAutoCalTargetDeltaValue`) | default `0.5`, clamped `[0.1, 10]`, rounded to 1 dp |
| Target luminance | `webui-workspace.js:4875-4885` | clamped `[10, 10000]`, default 100 |
| Greyscale completion summary | `webui-workspace.js:4514-4520` | prints reading count, average dE, max dE with its label, target dE, then the five worst points |
| 3D LUT completion summary | `webui-workspace.js:4497-4506` | prints `post_check_summary.mean_delta_e_2000` and `max_delta_e_2000` as text |
| Report summary cards | `webui-workspace.js:18521-18557` | average dE, peak luminance, black level, contrast ratio, average CCT (greyscale); average dE, peak, average luminance, reading count (colour). No thresholds applied |

No banner, badge, or state anywhere reads "pass" or "fail" against a dE limit, and nothing blocks progression on a dE result.

### 3.2 Warning banners that do exist

- Skipped reset: `webui-workspace.js:5859-5861` sets `meterAutoCalResetNotice` ("… was skipped — Auto Cal is continuing, but the calibration may build on prior data.").
- Missing pre-cal data in the report: `webui-workspace.js:7996` and `8003` push explanatory notice sections.
- Simulated meter: `webui-app.js:16955-16959` toasts and blocks.

### 3.3 In the workers: real thresholds

- `usr/bin/meter_lg_autocal.pl:2676-2705` — `autocal_solver_target_delta_e($config,$override_key,$fallback)`: reads `$config->{$override_key}`, else `target_delta_e`, else fallback `0.5`; clamps to `[0.1, 10.0]`.
  - HDR20 1D DPG override key `lg_autocal_hdr20_dpg_target_de`, used at `meter_lg_autocal.pl:14658`.
  - SDR26 override key `lg_autocal_sdr26_dpg_target_de`, used at `:16415` and `:17375`.
  - Generic ladder solver, no override key, at `:21979`.
- Per-IRE relaxation via `effective_de_limits_for_ire`, `usr/share/PGenerator/PGCalibrationMath.pm:96-129`:
  - HDR20: low-IRE threshold `5.0` (`:14581`), very-low `2.0` (`:14590`), multipliers `1.5` (`:14661`) and `2.0` (`:14664`).
  - SDR26: low-IRE threshold `5.0` (`:16248`, `:16367`), multipliers `1.5` (`:16418`) and `2.0` (`:16421`).
- Iteration caps (HDR20 1D DPG): `_inner_iters` 8 clamp `[1,12]` (`:14553`), `_inner_iters_low` 12 clamp `[1,24]` (`:14565`), `_inner_iters_very_low` 14 clamp `[1,24]` (`:14574`), `_white_iters` 16 clamp `[1,16]` (`:14655`), revert budgets 4 (`:14593`) and 3 clamp `[1,8]` (`:14610`).
- `headroom_max_iterations` read at `meter_lg_autocal.pl:1823`.
- HDR20 post-cal shadow correction, `usr/bin/meter_lg_3d_autocal.pl:4409-4420`: tolerance `0.05`, max passes `6`, damp `0.5`, band top 25 IRE, taper top 30 IRE.

---

## 4. Stop / abort, retry, checkpoint

### 4.1 Stop is a flag file followed by SIGKILL

Client:
- `webui-workspace.js:10153` — `meterStopAutoCal()`; posts `/api/meter/lg-autocal/stop` at `:10189` (10 s timeout).
- `webui-workspace.js:11609` — 3D stop posts `/api/meter/lg-3d-autocal/stop`.
- `webui-workspace.js:4280` — `/api/meter/stop` for plain meter reads.
- Every abort path also posts `/api/lg/autocal/run/end` with an `aborted` payload: `:7507`, `:8761`, `:10194`, `:11611`. Completion posts it with `complete`: `:4663`, `:9212`, `:11059`.

Routes: `usr/share/PGenerator/webui.pm:1983` (1D stop) and `:2008` (3D stop).

Server:
- `webui.pm:6194-6200` — `webui_meter_lg_autocal_kill()`: writes `time()` into `/tmp/meter_lg_autocal.stop`, `chmod 0666`, then `sudo pkill -9 -f '[m]eter_lg_autocal\.pl'` if still running, then optionally marks the state cancelled.
- `webui.pm:6746-6752` — the 3D equivalent for `/tmp/meter_lg_3d_autocal.stop`.
- `webui.pm:6689` — `webui_meter_lg_autocal_stop()`.
- Stop files are cleared before a new start: `webui.pm:6388-6391` and `:6823-6826`.

There is **no SIGTERM step from the UI**; the escalation goes straight to `-9`.

Worker side:
- Stop-file defaults: `usr/bin/meter_lg_autocal.pl:33`, `usr/bin/meter_lg_3d_autocal.pl:36`.
- Signal handlers `$SIG{TERM}` / `$SIG{INT}` setting `$cancelled`: `meter_lg_autocal.pl:75-76`, `meter_lg_3d_autocal.pl:42-43`.
- `sub cancelled` (in-process flag **or** stop file present): `meter_lg_autocal.pl:393-395`, `meter_lg_3d_autocal.pl:171-173`.
- Polled at hundreds of loop sites in the 1D worker (examples: `:10838`, `:12907`, `:14810`, `:15206`, `:15977`, `:16563`, `:18658`, `:19333`, `:20925`, `:21046`).
- The 3D worker uses `die "cancelled\n" if(cancelled())` (e.g. `:1053`, `:3961`, `:4724`, `:5265`, `:5773`), caught by the top-level eval which writes `status => "cancelled"` at `:5948-5951`.
- Both unlink their own stop file on exit: `meter_lg_autocal.pl:22030-22036`, `meter_lg_3d_autocal.pl:5081`.

Other stop sentinels: `/tmp/meter_lg_dv_profile.stop` (`usr/share/PGenerator/lg.pm:2460`), `/tmp/lut_solve_stop.signal` (`webui.pm:7557`).

Process detection uses `pgrep` (`webui.pm:6003`), with a `.misses` debounce counter file at `webui.pm:6588` so a momentarily-absent process is not read as a completed run. A handoff guard that distinguishes "still running" from "finishing" is at `webui.pm:6010-6040`.

### 4.2 Retries

**1D DPG upload — real in-worker retry.** Three near-identical closures, each `my $tries=4;` with `select(undef,undef,undef,0.6*$t)` backoff, all wrapping `POST /api/lg/1d-dpg/upload`:
`usr/bin/meter_lg_autocal.pl:14806-14833` (HDR20), `:16559-16587` and `:17765-17792` (SDR26).

**3D LUT upload — no automatic retry.** The single `api_json("POST","/api/lg/3d-lut/upload",…)` at `usr/bin/meter_lg_3d_autocal.pl:5527` is one-shot. `transport_attempt_count` / `transport_retry_count` / `retry_exhausted` are read back at `:5544-5546` but nothing in the repo ever sets them. Instead the worker sets `upload_retry_available` at `:5955-5960`, true only when the exact `.cube`/`.bin` payload files still exist and the commit was not verified. The operator then triggers `POST /api/meter/lg-3d-autocal/retry-upload` (route `webui.pm:2004`, handler `webui.pm:6961`), which relaunches the worker with `retry_upload_only=1` at `webui.pm:7094`, replaying a byte-identical payload (`meter_lg_3d_autocal.pl:2976-2980`, `:5158-5188`).

**Meter-read retries.** 1D: `read_attempts` default 5, clamp `[1,5]`, at `meter_lg_autocal.pl:21419-21421`, loop `:21465-21497`, backoff `1.0+$attempt` s. 3D: 3 attempts at `meter_lg_3d_autocal.pl:3655`, plus `max_null_discards=3` at `:3657`.

**Other retry counts (1D worker).** Implausible reading 3 (`:21516`), LG picture-settings read 3 (`:21542`), factory level restore 3 (`:21602`), HDR luminance/DDC baseline resets 3 each (`:21660`, `:21727`), TV write "connection missed" 4 (`:12856`). Transient meter-session teardown threshold 2 (`meter_lg_autocal.pl:4946`, `meter_lg_3d_autocal.pl:3491`).

**Client-side start retries.** 3D start loop of 5 attempts at `webui-workspace.js:11507`; greyscale-to-3D start one re-attempt after a status refresh and 4 s wait at `webui-workspace.js:8415-8425`.

### 4.3 Checkpoint and resume

**No true resume exists.**

- Both workers write state atomically (tmp + `rename`): `meter_lg_autocal.pl:219-231`, `meter_lg_3d_autocal.pl:125-136`. State carries `phase`, `status`, `current_step`, `total_steps`.
- Nothing reads that state back to restart a run mid-sequence. There is no `resume_from`, `start_step`, or checkpoint option in either worker or in the launch sites.
- The only partial exception is the upload-only replay described above, which skips remeasurement but does not resume the measurement phase.
- "Resume"/"adopt" elsewhere means a **browser tab re-attaching to an already-running worker** by matching `full_autocal_run_id` / `run_id`: `webui-workspace.js:7431-7484`, `webui.pm:3834-3863`, `webui.pm:6810-6938`, `lg.pm:2530-2647`.
- `/api/meter/series/ready` (`webui.pm:5982`) and `/api/meter/read/ready` (`webui.pm:3091`) are meter-readiness continue signals for a paused measurement, not worker resume.

### 4.4 Run records — `usr/share/PGenerator/PGAutoCalRun.pm`

- `:12` — `$BASE_DIR = $ENV{'PGEN_AUTOCAL_RUNS_DIR'} || '/var/lib/PGenerator/lg/autocal-runs'`.
- `:13` — `$KEEP = 10`.
- `:77-82` — run id format `YYYYMMDD-HHMMSS-<pidhex><seqhex>`.
- `:110-136` — `run_begin($manifest)`: supersedes a prior run lacking `summary.json`, creates the directory, writes `manifest.json` atomically, updates the `current` pointer file (`:61`, `:72-75`), prunes.
- `:91-108` — `_prune()`: keeps the current run always, retains at most 10 others, `remove_tree`s the rest.
- `:146-164` — `run_stage()` appends to `stages.ndjson` under `flock(LOCK_EX)`, stamping `stage` and `ts`.
- `:187-200` — `run_merge_manifest()`.
- `:202-234` — `run_end()` writes `summary.json` under `.summary.lock` with terminal-state precedence (`complete` wins over `superseded`/`error`/`aborted`).
- `:2-4` — header: every public sub is wrapped in `eval`; a record failure can never disturb a calibration run.

Files per run directory: `manifest.json`, `stages.ndjson`, `grey-state.json`, `grey-log.txt`, `3d-state.json`, `3d-log.txt`, `summary.json`, and for DV `dv-profile-measurements.json` / `colour-series.json` (names enumerated at `webui.pm:10501`).

Writers: 1D stage `1d_generate` at `meter_lg_autocal.pl:26934` with snapshots at `:26932-26933`; 3D stage `3d_generate` at `meter_lg_3d_autocal.pl:5930` and `:5985`, snapshots `:5928-5929` and `:5983-5984`, emitted-LUT metadata (`lut_grid 33`, `lut_data_count 35937`, `lut_bit_depth 12`) at `:5935`. Run begin/end from `lg.pm:3485` and `lg.pm:3503-3528`, guarded by `client_run_token` matching so a stale callback cannot overwrite `summary.json`.

### 4.5 Worker invocation

1D: positional args `$config_file`, `$state_file`, `$stop_file` with defaults at `meter_lg_autocal.pl:31-33`. Launched at `webui.pm:6512`:

```
setsid /usr/bin/perl /usr/bin/meter_lg_autocal.pl '<config>' '<state>' '<stop>' </dev/null >'<log>' 2>&1 &
```

Config written at `webui.pm:6502-6505`; start handler `webui_meter_lg_autocal_start` at `webui.pm:6333`; log path from `webui_prepare_tmp_worker_log` at `webui.pm:470-485` (`/tmp/meter_lg_autocal.log`, else a timestamped fallback).

3D: defaults at `meter_lg_3d_autocal.pl:34-36`; three launch sites, all `setsid … &`:
- normal start `webui.pm:6947`
- upload-only retry `webui.pm:7094` (appends to the existing log)
- standalone `solve_only` LUT solve `webui.pm:7575`, using `/tmp/lut_solve_config.json`, `/tmp/lut_solve_state.json`, `/tmp/lut_solve_stop.signal`, `/tmp/lut_solve.log`, with no meter or TV interaction.

---

## 5. `README-webui-fragments.md` and the golden-hash rule

File: `/Users/garry.casey/Desktop/personal/PGenerator-Plus/usr/share/PGenerator/README-webui-fragments.md`.

Documented rules:
- Ten byte-sensitive fragments; never run Prettier, ESLint `--fix`, format-on-save, or tab conversion over them.
- `icc_profile.html` is spliced into the same hashed page and is equally byte-sensitive; `icc_profile.css`, `icc_profile.js`, `hcfr_chc.js` are served verbatim from `/assets/`.
- `webui-colour-math.js` opens with `'use strict';` and shares one inline `<script>` with `webui-app.js` and `webui-workspace.js`, so all three must be strict-mode clean.
- Fragments are read with Perl's `<:raw>` layer: keep UTF-8 bytes and LF endings, no banner comments inside fragments.
- After an intentional change: run `prove -v t/webui_html_golden.t`, copy the printed `got:` hash into `t/webui_html_golden.sha256` (single line, no trailing spaces), re-run.
- Before publishing an OTA archive: `perl t/check_webui_package.pl <release>.tar.gz`.

Assembly implementation:
- `usr/share/PGenerator/webui.pm:12772-12782` — the ten-name allow-list.
- `webui.pm:12787-12800` — `_webui_asset_path` / `webui_asset`; a non-whitelisted name is logged and rejected.
- `webui.pm:12931-12975` — `webui_html()`. Seven marker substitutions in a load-bearing order at `:12939-12945` (`__PG_CSS_THEME__`, `__PG_CSS_LAYOUT__`, `__PG_BODY__`, `__PG_LOGO_DARK__`, `__PG_JS_COLOUR_MATH__`, `__PG_JS_APP__`, `__PG_JS_WORKSPACE__`), because a marker can live inside an earlier fragment. Then five builder splices at `:12959-12963` (`__PG_LG_CARD__`, `__PG_LG_JS__`, `__PG_LG_LOAD_INFO__`, `__PG_LG_INIT__`, `__PG_GAMUT_PRESETS__`), each counted explicitly. Then the ICC splice at `:12972+` and a residual `__PG_` check. Any failure returns `webui_recovery_html`. Result cached in `$_webui_html_cache` (`:12786`, `:12932`).

### 5.1 The documented rule cannot be followed on this tree

Commit `adcd80a9e16a79be8716f2245290a567dfb93a83`, "Keep regression tests local", 29 August 2026, author Jordan, deleted 30 test files and moved the packaging checker:

- `t/webui_html_golden.t` — **deleted**
- `t/webui_html_golden.sha256` — **deleted**
- `t/slice_webui.pl` — deleted
- `t/check_webui_package.pl` — **moved to `tools/check_webui_package.pl`**

Neither `t/webui_html_golden.*` nor any `tools/` directory exists in this checkout (`git ls-files tools/` is empty; `ls tools` reports no such directory). `git show HEAD:t/webui_html_golden.sha256` fails. So the README's two verification commands both refer to files that are absent, and there is currently **no automated guard on fragment bytes**.

Also deleted in the same commit and relevant to any executor work: `t/lg_3d_lut_upload_retry.t`, `t/lg_3d_retry_endpoint.t`, `t/lg_3d_lut_fail_closed.t`, `t/lg_autocal_handoff.t`, `t/lg_autocal_handoff_guard.t`, `t/lg_autocal_reliability.t`, `t/lg_autocal_run_end.t`, `t/lg_autocal_state_write.t`, `t/lg_calibration_mode_recovery.t` (611 lines), `t/pg_autocal_run.t`, `t/webui_fullautocal_owner.t`, `t/webui_recovery.t`, `t/webui_watchdog.t`, `t/simulated_meter_state_path.t`, `t/dv_absolute_wrgb_primary_math.js`. They are recoverable from that commit's parent.

---

## 6. Test infrastructure

### 6.1 What runs today

```
$ prove t/
t/lg_3d_autocal_worker_load.t .......... ok
t/lg_autocal_dv_map_mode.t ............. ok
t/lg_autocal_picture_mode_guard.t ...... ok
t/lg_autocal_worker_load.t ............. ok
t/lg_dv_final_dpg_archive.t ............ ok
t/lg_picture_mode_persistence_guard.t .. ok
t/lg_picture_mode_tokens_agree.t ....... ok
t/pgmath_delta_e_itp.t ................. ok
All tests successful.
Files=8, Tests=88,  1 wallclock secs
Result: PASS
```

Perl 5.34.1 on this machine. Runtime about one second; no hardware touched.

Files (all under `/Users/garry.casey/Desktop/personal/PGenerator-Plus/t/`):

| File | What it guards |
|---|---|
| `lg_autocal_worker_load.t` | 1D worker loads via `do` without running main (4 tests) |
| `lg_3d_autocal_worker_load.t` | same for the 3D worker, separate interpreter to avoid sub-name collisions (3 tests) |
| `lg_autocal_dv_map_mode.t` | a DV AutoCal must be in Relative map mode; guards a direct `POST /api/meter/lg-autocal` caller |
| `lg_autocal_picture_mode_guard.t` | structure guard over `meterAutoCalRunPreflightReset` branch ordering in `webui-workspace.js` |
| `lg_picture_mode_persistence_guard.t` | three persistence sites in `webui-lg.js` must gate on `virtual_picture_settings` |
| `lg_picture_mode_tokens_agree.t` | `lg_picture_mode_tokens_agree` edge cases |
| `lg_dv_final_dpg_archive.t` | DV full workflow must not defer smoothing/archive to a 3D stage that never runs |
| `pgmath_delta_e_itp.t` | pins `PGMath::delta_e_itp_xyz` against an independent BT.2100 ICtCp implementation (5 tests) |

Style note: four of the eight are **structure guards that regex the JavaScript source**, not executing tests. Two are load smoke tests that exploit the workers' trailing `unless(caller()) { … }` so `do` defines the subs without starting a calibration. That guard is the mechanism any future worker-level unit test would build on.

### 6.2 CI

`/Users/garry.casey/Desktop/personal/PGenerator-Plus/.github/workflows/tests.yml`, triggers on `push` and `pull_request`, `ubuntu-latest`:

1. install `libio-socket-ssl-perl` (needed by `pgenerator-lg` for the TV WebSocket TLS)
2. `perl -c usr/bin/meter_lg_autocal.pl` and `perl -c usr/bin/meter_lg_3d_autocal.pl`
3. `perl -c` on `usr/sbin/pgenerator-lg`, `usr/share/PGenerator/lg.pm`, `usr/share/PGenerator/webui.pm`
4. `prove -v t/`

### 6.3 Mocks

- **Simulated meter exists**: `/Users/garry.casey/Desktop/personal/PGenerator-Plus/usr/bin/spotread_sim`, a Perl program speaking the spotread console protocol as port 99, driven by `meter_session.sh` / `meter_series.sh` under `script -qfc` exactly like real ArgyllCMS spotread. It synthesises readings from the pattern the generator is actually showing, recorded by `webui.pm` into `/var/lib/PGenerator/pgen_sim_pattern.json` (fallback `/tmp/pgen_sim_pattern.json`), through a deliberately imperfect display model (warm white point, per-channel gamma error, off-target primaries, raised black floor, read noise).
- **No mock LG TV** anywhere in the tree. No `lg_sim`, no fake WebSocket TV, no recorded-response fixture.
- **AutoCal is explicitly blocked under the simulated meter**: `webui-app.js:16955-16959` (`meterBlockAutoCalForSimulation`), and it is the very first statement of `meterStartFullAutoCal` (`webui-workspace.js:8201`). Simulated mode mirrors `/api/meter/status` `simulated:true` (`webui-app.js:16963`).

So a headless executor cannot be exercised end to end today without (a) relaxing that guard and (b) supplying a TV stand-in that does not exist.

### 6.4 Python and Node harnesses

- **No `scalar_reference.py`** in this tree (memory of it refers to a different branch/fork state).
- No `package.json` outside vendored code; no JavaScript test runner; the only JS test, `t/dv_absolute_wrgb_primary_math.js`, was removed in `adcd80a9`.
- The only Python test-shaped file is vendored: `vendor/ArgyllCMS_ICC4.4/contrib/test_icc44.py`.
- Project Python under `usr/bin/` (`icc_profile_builder.py`, `icc_finetune.py`, `pgen_colour_math.py`, `ccss_create.py`, `spotread_measure.py`, etc.) has no accompanying test harness in the repo.

---

## 7. Is the Full AutoCal entry point reusable from Perl?

**No. All orchestration is browser-only.**

- `meterStartFullAutoCal` is a plain function declared at `webui-workspace.js:8200`. It is never assigned to `window`, never exported, and has exactly one caller: an inline `onclick` at `usr/share/PGenerator/webui-body.html:664`.

```html
<button class="btn btn-sm btn-secondary" id="meterFullAutoCalBtn" onclick="meterStartFullAutoCal()" style="display:none">&#9654; Full Auto Cal</button>
```

- There is no HTTP endpoint that starts a Full AutoCal. The routes at `webui.pm:1973`, `1994`, `2008` start or stop the **individual workers** only.
- What is browser-only, and would have to be re-implemented by a Pi-side executor:
  - stage ordering and transitions (`webui-app.js:15338`, phase assignments throughout `webui-workspace.js`)
  - the operator dialogs and their effect on config (`webui-workspace.js:8219`, `8245`)
  - preflight reset, its recovery dialog, and the picture-mode guard (`webui-workspace.js:5708`, `5739`, `5800-5823`)
  - greyscale ladder construction and the whole `/api/meter/lg-autocal` payload (`webui-workspace.js:10019-10090`)
  - profiling-choice resolution, HDR matrix-only forcing, lattice series id resolution (`webui-workspace.js:8236-8245`, `8391-8397`)
  - start retries, adoption after a lost response, transition-busy backoff (`webui-workspace.js:8415-8425`, `11507-11541`)
  - Dolby Vision map-mode and target-gamma sequencing (`webui-workspace.js:8261-8289`, `8341-8348`, `8578`)
  - calibration-mode teardown before the post-cal read (`webui-workspace.js:8023-8078`)
  - report capture, replay, and HTML generation, which need a live DOM (`webui-workspace.js:7863`, `7936`, `18644`)
  - the lease/adoption model in localStorage (`webui-workspace.js:7159-7218`)
- The Perl side knows Full AutoCal only as opaque metadata it stamps, matches, and clears:
  - `webui.pm:6123-6138` — `webui_meter_lg_autocal_clear_full_workflow_state` lists the exact keys it strips
  - `webui.pm:3834-3863`, `webui.pm:4312-4369` — run-id matching for same-run guards
  - `lg.pm:2473-2478`, `lg.pm:2599-2647` — DV profile helper run-id plumbing
  - `webui.pm:2659-2683` — a heuristic that recognises a completed 1D state still carrying `full_workflow` and `full_autocal_phase:"first-greyscale"`, i.e. the handoff window before the browser launches the 3D stage

The one genuinely server-side artefact of a full run is the `PGAutoCalRun` record, and even that is opened and closed by browser-issued calls to `/api/lg/autocal/run/begin` and `/api/lg/autocal/run/end`.

---

## Key files

- `/Users/garry.casey/Desktop/personal/PGenerator-Plus/usr/share/PGenerator/webui-workspace.js` — wizard, phases, report capture and rendering
- `/Users/garry.casey/Desktop/personal/PGenerator-Plus/usr/share/PGenerator/webui-app.js` — state keys, report series, stage order, progress weighting
- `/Users/garry.casey/Desktop/personal/PGenerator-Plus/usr/share/PGenerator/webui-body.html` — the only Full AutoCal entry point (line 664)
- `/Users/garry.casey/Desktop/personal/PGenerator-Plus/usr/share/PGenerator/webui.pm` — API routes, worker launch and kill, report-state handler, fragment assembler
- `/Users/garry.casey/Desktop/personal/PGenerator-Plus/usr/share/PGenerator/lg.pm` — TV transport, DV profile helper, run begin/end
- `/Users/garry.casey/Desktop/personal/PGenerator-Plus/usr/share/PGenerator/PGAutoCalRun.pm` — per-run record store
- `/Users/garry.casey/Desktop/personal/PGenerator-Plus/usr/share/PGenerator/README-webui-fragments.md` — fragment rules (golden-hash instructions now stale)
- `/Users/garry.casey/Desktop/personal/PGenerator-Plus/usr/bin/meter_lg_autocal.pl` — greyscale worker
- `/Users/garry.casey/Desktop/personal/PGenerator-Plus/usr/bin/meter_lg_3d_autocal.pl` — 3D LUT worker
- `/Users/garry.casey/Desktop/personal/PGenerator-Plus/usr/bin/spotread_sim` — simulated meter (port 99)
- `/Users/garry.casey/Desktop/personal/PGenerator-Plus/.github/workflows/tests.yml` — CI
- `/Users/garry.casey/Desktop/personal/PGenerator-Plus/t/` — 8 test files, 88 assertions
