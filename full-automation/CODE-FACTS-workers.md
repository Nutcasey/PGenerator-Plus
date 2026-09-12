> Code facts gathered 12 September 2026 against commit 42a6f3e8 for FULL_AUTOMATION_GOAL.md. Line numbers drift; re-grep before relying on one. Read-only survey, no design proposals.

# Worker process lifecycle — PGenerator-Plus

Repo root: `/Users/garry.casey/Desktop/personal/PGenerator-Plus`

**Headline: there is no Pi-side persistent job queue.** The only queue abstraction in
the Perl tree is the WebUI's in-process HTTP request dispatcher. Long-running
calibration work is a detached `setsid` process tracked by three files in `/tmp`,
and multi-stage workflows are sequenced by the browser, not the server.

---

## 1. How webui.pm launches meter workers

Every long-running worker is a detached background process started by `system()`
with a shell `&`. There is no fork/exec bookkeeping, no job table, no `wait`.

| Worker | Launch site | Command shape |
|---|---|---|
| 1D greyscale AutoCal | `usr/share/PGenerator/webui.pm:6512-6513` | `setsid /usr/bin/perl /usr/bin/meter_lg_autocal.pl '<config>' '<state>' '<stop>' </dev/null >'<log>' 2>&1 &` |
| 3D LUT AutoCal | `usr/share/PGenerator/webui.pm:6947-6948` | same shape, `meter_lg_3d_autocal.pl` |
| 3D commit retry | `usr/share/PGenerator/webui.pm:7094` | same binary, appends (`>>`) to the existing log |
| Standalone LUT solve | `usr/share/PGenerator/webui.pm:7575` | same binary, `/tmp/lut_solve_*` file triple |
| Measurement series | `usr/share/PGenerator/webui.pm:5880`, `system()` at `:5892` | `setsid sudo /bin/bash /usr/bin/meter_series.sh <38 positional args> </dev/null >/dev/null 2>&1 &` |
| Meter session (interactive reads) | `usr/share/PGenerator/webui.pm:3233` | `setsid sudo /bin/bash /usr/bin/meter_session.sh ... &` |
| DV profile measure | `usr/share/PGenerator/lg.pm:2605` | `setsid /usr/bin/perl /usr/bin/meter_lg_dv_profile.pl ... &` |
| CCSS create | `usr/share/PGenerator/webui.pm:8869` | `setsid sudo <python> /usr/bin/ccss_create.py --state-file ... --pid-file ... &` |

The only place the daemon forks for itself is the renderer restart after
`POST /api/config`: a double-fork so the actual worker reparents to init, at
`usr/share/PGenerator/webui.pm:1515-1574`. The comment there records why no
`$SIG{CHLD}` reaper may ever be installed — it would steal exit statuses from the
`system()`/backtick calls that `command.pm` checks `$?` on.

### The tracking mechanism: a file triple per worker

Declared at `usr/share/PGenerator/webui.pm:391-402`:

```
/tmp/meter_lg_autocal.json          state   (webui.pm:391)
/tmp/meter_lg_autocal_config.json   config  (webui.pm:392)
/tmp/meter_lg_autocal.stop          stop    (webui.pm:393)
/tmp/meter_lg_autocal.log           log     (webui.pm:394)
/tmp/meter_lg_3d_autocal.json       state   (webui.pm:395)
/tmp/meter_lg_3d_autocal_config.json        (webui.pm:396)
/tmp/meter_lg_3d_autocal.stop               (webui.pm:400)
/tmp/meter_lg_3d_autocal.log                (webui.pm:401)
/tmp/meter_series.json              state   (webui.pm:390)
/tmp/meter_read.json                state   (webui.pm:406)
/tmp/meter_session.pid              PID     (webui.pm:407)
/tmp/meter_session.cmd              FIFO    (webui.pm:408)
```

DV profile equivalents are in `usr/share/PGenerator/lg.pm:2458-2461`
(`/tmp/meter_lg_dv_profile.json`, `_config.json`, `.stop`, `.log`).
Standalone LUT solve: `/tmp/lut_solve_state.json` and `/tmp/lut_solve_stop.signal`
(`usr/share/PGenerator/webui.pm:7556-7557`).

**No PID file exists for the autocal workers.** Liveness is a `pgrep` on the script
name:

- `webui_meter_lg_autocal_running` — `usr/share/PGenerator/webui.pm:6003-6006`,
  runs `pgrep -f '[m]eter_lg_autocal\.pl'`.
- Same pattern for the 3D worker in `webui_meter_status`,
  `usr/share/PGenerator/webui.pm:2672-2673`.

Only the CCSS worker uses a real PID file, `/tmp/ccss_create.pid`
(`usr/share/PGenerator/webui.pm:417`, liveness check at `:8715-8720`), and the
meter session uses `/tmp/meter_session.pid` with a `/proc/<pid>/cmdline` confirm
(`usr/share/PGenerator/webui.pm:2818-2830`).

Stop is a stop-file write followed by escalating pkill:
`webui_meter_lg_autocal_kill` at `usr/share/PGenerator/webui.pm:6194-6200` writes
the stop file, then `pkill -TERM -f '[m]eter_lg_autocal\.pl'`, then `pkill -9` if
still running. The worker polls the stop file at `usr/bin/meter_lg_autocal.pl:395`
(`return 1 if(-f $stop_file)`) and removes it on exit at
`usr/bin/meter_lg_autocal.pl:22030-22036`, warning in the log if a root-owned
leftover cannot be unlinked (a stale stop file aborts the next run instantly).

### HTTP endpoints

Dispatch block `usr/share/PGenerator/webui.pm:1957-2012`:

| Endpoint | Method | Handler |
|---|---|---|
| `/api/meter/lg-autocal` | POST | `webui_meter_lg_autocal_start` (`:1974`) |
| `/api/meter/lg-autocal/status` | GET | `webui_meter_lg_autocal_status` (`:1979`) |
| `/api/meter/lg-autocal/stop` | POST | `webui_meter_lg_autocal_stop` (`:1984`) |
| `/api/meter/lg-autocal/clear-tonemap-pending` | POST | `:1989` |
| `/api/meter/lg-3d-autocal/start` | POST | `webui_meter_lg_3d_autocal_start` (`:1994`) |
| `/api/meter/lg-3d-autocal/status` | GET | `:1999` |
| `/api/meter/lg-3d-autocal/retry-upload` | POST | `:2004` |
| `/api/meter/lg-3d-autocal/stop` | POST | `:2009` |
| `/api/meter/series` | POST | `webui_meter_series_start` (`:1957`) |
| `/api/meter/series/status` | GET | `:1962` (accepts `?summary=1`) |
| `/api/meter/series/ready` | POST | `webui_meter_series_ready` (`:2013`) |
| `/api/meter/full-autocal/report-state` | POST | `:1968` |
| `/api/meter/stop`, `/stop/status`, `/clear`, `/reset` | — | `:2018`, `:2023`, `:2028`, `:2033` |
| `/api/lg/dv-profile/start` \| `/status` \| `/stop` | — | `usr/share/PGenerator/lg.pm:3408-3414` |
| `/api/lg/autocal/run/begin` \| `/run/end` | POST | `usr/share/PGenerator/lg.pm:3450-3451` |
| `/api/3d-lut/solve` \| `/solve/status` | — | `usr/share/PGenerator/webui.pm:2209`, `:2214` |
| `/api/ccss/create/start` \| `/status` \| `/stop` \| `/continue` | — | `usr/share/PGenerator/webui.pm:2270-2295` |

Status endpoints simply read the `/tmp` state JSON and lightly rewrite stale flags.
The worker writes that file atomically (tmp + `rename`) —
`usr/bin/meter_lg_autocal.pl:219-231`, called from `write_state` at
`usr/bin/meter_lg_autocal.pl:12654-12658`. The comment at `:220-223` states the
reason: the WebUI regex/decode-reads the file concurrently from the hand-off
guard, the status route and the same-run check.

### Start-time guards

`webui_meter_lg_autocal_start` (`usr/share/PGenerator/webui.pm:~6340-6521`) and
`webui_meter_lg_3d_autocal_start` (`:6797-6955`) both:

1. Take a process-wide guard — the 3D path holds `lock($_meter_lg_3d_autocal_start_lock)`,
   a `:shared` scalar declared at `:402`, taken at `:6799` and `:6963`.
   The 1D path has no equivalent lock.
2. Call `webui_meter_lg_autocal_handoff_guard` (`:6012-6035`), which distinguishes a
   genuinely-running worker (`error_code: lg-autocal-active`, `retryable:false`)
   from one that is finishing cleanup (`error_code: lg-autocal-finishing`,
   `retryable:true`, `retry_after_ms:600`). It decodes only the top-level
   `status`/`phase`; an undecodable document is treated as active, not finishing.
3. Call `webui_meter_stop()` to clear any live meter session.
4. Force-remove a stale stop file, escalating to `sudo rm -f` because a root-owned
   leftover in sticky `/tmp` cannot be unlinked by the pgenerator user
   (`:6388-6392`, `:6824-6828`).
5. Write the config file, write a seed state document with `"status":"running"`,
   then `system()` the `setsid` command and return immediately.

---

## 2. Does a worker survive the browser closing?

### The process: yes

The worker is `setsid`-detached with stdin from `/dev/null`, so it has no
controlling terminal and no parent link to the daemon thread that spawned it.

It also survives a **daemon restart**. `/etc/init.d/PGenerator stop` pkills only
`/usr/sbin/PGeneratord.pl`, `/usr/sbin/PGeneratord`, `/usr/bin/PGenerator_cmd.pl`
and `/usr/bin/PGenerator_serial.pl` (see the `stop)` case in `etc/init.d/PGenerator`).
None of those patterns match a `meter_*` worker. So the every-minute watchdog can
restart the whole daemon mid-calibration and the worker keeps measuring.

### The workflow: no

Stage sequencing for Full AutoCal lives entirely in the browser. JavaScript posts
stage 1, polls to completion, then posts stage 2:

- greyscale stage starts — `usr/share/PGenerator/webui-workspace.js:8919`, `:9093`, `:10019`
- 3D stage start — `usr/share/PGenerator/webui-workspace.js:11509`
- terminal `run/end` posts — `usr/share/PGenerator/webui-workspace.js:9212`, `:11059`, `:4663`
- abort `run/end` posts — `:7507`, `:8761`, `:10194`, `:11611`

Close the tab mid-run and the **current** worker finishes and writes its results,
but nothing starts the next stage. There is no server-side resume.

What exists instead is a **client-side lease** so another tab can adopt the run:

- The controller id lives in `sessionStorage` and therefore dies with the tab —
  `meterFullAutoCalControllerId`, `usr/share/PGenerator/webui-workspace.js:7194-7204`.
- The run record lives in `localStorage` with a 30-second heartbeat —
  `meterFullAutoCalSaveState` at `:7160-7187`, `setInterval(...,30000)` at `:7192`.
- `METER_FULL_AUTOCAL_LEASE_MS = 3*60*1000` — `:7214`.
  `meterFullAutoCalSavedStateAbandoned` at `:7216-7220`.
- The adoption probe only adopts a worker whose run id matches —
  `:11529-11539`; a full-workflow start never adopts a standalone worker and
  vice versa.
- Server side, `webui_meter_lg_autocal_same_run_running`
  (`usr/share/PGenerator/webui.pm:6037-6050`) makes a duplicate start for the
  same run idempotent (`{"status":"started", ...already running}`).

### What happens to results when nobody polls

The worker still writes its own state file and its own durable artefacts. What is
lost is everything the **browser** owns:

- Pre-cal and post-cal chart data live in `localStorage` under
  `METER_FULL_AUTOCAL_REPORT_KEY` —
  `meterFullAutoCalLoadReportData`/`SaveReportData`,
  `usr/share/PGenerator/webui-workspace.js:6305-6335`.
- They reach the Pi only when the browser posts
  `/api/meter/full-autocal/report-state` from `meterFullAutoCalArchiveReportData`
  (`usr/share/PGenerator/webui-workspace.js:6380-6404`). The server never
  generates that payload itself.
- The UI itself warns about this: the report notice at
  `usr/share/PGenerator/webui-workspace.js:8006` says a run that was "resumed or
  adopted after a page reload" has no Pre-Cal charts.

Secondary consequence of an unattended death: a worker killed without writing a
terminal state leaves `"status":"running"` in the file forever, which would pin
the meter "Busy" with no tab open to clear it. That is guarded by requiring
either a live `pgrep` **or** a state file younger than 15 s —
`usr/share/PGenerator/webui.pm:2662-2681`.

### Where results are written

Transient (`/tmp`, survives reboot on this image but is cleared of meter logs at
startup):

```
/tmp/meter_lg_autocal.json      /tmp/meter_lg_3d_autocal.json
/tmp/meter_series.json          /tmp/meter_read.json
/tmp/lut_solve_state.json       /tmp/meter_lg_dv_profile.json
```

Durable (`/var/lib/PGenerator`):

```
/var/lib/PGenerator/lg/luts/                    *.cube *.3dl *.bin *.json
/var/lib/PGenerator/lg/autocal-runs/<run-id>/   per-run diagnostics record
/var/lib/PGenerator/lg/calibration-history/1d/  reuploadable 1D snapshots
/var/lib/PGenerator/lg/calibration-history/dv/  reuploadable DV snapshots
/var/lib/PGenerator/reports/full-autocal/       browser-posted before/after JSON
/tmp/PGenerator_full_autocal_reports/           fallback for the above
/var/lib/PGenerator/icc/  /var/lib/PGenerator/icc-companion/
```

---

## 3. PGAutoCalRun.pm

File: `usr/share/PGenerator/PGAutoCalRun.pm`. Core Perl only, JSON::PP,
`File::Path`, `Fcntl qw(:flock)`. Every public sub swallows its own errors so a
record failure can never disturb a calibration run (stated at lines 2-3).

### Configuration

- `$BASE_DIR = $ENV{'PGEN_AUTOCAL_RUNS_DIR'} || '/var/lib/PGenerator/lg/autocal-runs'` — line 12.
- `$KEEP = 10` — line 13.

### Directory layout

- One directory per run, id `YYYYMMDD-HHMMSS-<pid3hex><seq3hex>` — `_gen_run_id`, lines 73-78.
  The timestamp+seq prefix makes lexical order chronological.
- `$BASE_DIR/current` — a plain text file holding the active run id;
  `_current_path` line 61, `current()` lines 63-71, `_set_current` line 82.

### Files saved per run

Enumerated by the diagnostic bundle at `usr/share/PGenerator/webui.pm:10500`:

```
manifest.json                 run identity + config + TV info    (run_begin, line 120)
summary.json                  terminal status + note             (run_end,   line 191)
stages.ndjson                 append-only stage log              (run_stage, line 136)
grey-state.json               snapshot of /tmp/meter_lg_autocal.json
3d-state.json                 snapshot of /tmp/meter_lg_3d_autocal.json
dv-profile-measurements.json  written by lg.pm:2926
colour-series.json
grey-log.txt                  snapshot of /tmp/meter_lg_autocal.log
3d-log.txt                    snapshot of /tmp/meter_lg_3d_autocal.log
.summary.lock                 flock target for run_end
```

Snapshot callers:
`usr/bin/meter_lg_autocal.pl:26930-26934` (grey state, grey log, `1d_generate` stage)
and `usr/bin/meter_lg_3d_autocal.pl:5926-5935` and `:5981-5985`
(3D state, 3D log, `3d_generate` stage, `run_merge_manifest` with `emitted_lut`).

### API

- `run_begin($manifest)` — lines 105-130. Ensures the base dir; if `current`
  points at a run with no `summary.json` it closes that run through `run_end`
  with `status => 'superseded'` (routed through the locked path so a real
  `run_end` racing it wins); generates the id; writes `manifest.json` with
  `run_id` and `started_at` stamped; sets `current`; prunes.
- `run_manifest($run_id)` — lines 132-138, returns a copy.
- `run_stage($run_id,$stage,$record)` — lines 136-156. Appends one JSON line to
  `stages.ndjson` under `flock(LOCK_EX)`, stamping `stage` and `ts`.
- `run_snapshot($run_id,$label,$src,$tail_lines)` — lines 158-177. Copies a file
  into the run dir under `$label`, optionally keeping only the last N lines.
  `$label` is passed through `_safe_id` (line 20, rejects anything outside
  `[A-Za-z0-9._-]`, so no path traversal).
- `run_merge_manifest($run_id,$partial)` — lines 179-190.
- `run_end($run_id,$summary)` — lines 191-222. Serialised on `.summary.lock`
  with `flock(LOCK_EX)`. Status ladder: an existing `complete` is final and
  wins; `superseded` is only provisional and any real terminal status
  (complete/aborted/error) replaces it; a non-complete prior status is only
  upgraded by `complete`.
- `latest_dir()` — lines 224-235, newest by mtime.

### Retention / pruning

`_prune`, lines 87-103. Runs on every `run_begin`.

- Lists directories matching `\A\d{8}-\d{6}-` only.
- Sorts lexically (chronological by construction).
- Returns early if `<= $KEEP` (10).
- **Always excludes the run named by `current` from the candidate list.** The
  comment at lines 94-98 records why: a Pi without a valid clock creates a
  `19700101` run beside retained 2026 runs, and lexical pruning used to delete
  that newly-created active directory immediately, leaving `current` pointing
  nowhere so the final greyscale state never reached Calibration History.
- `remove_tree`s the oldest `scalar(@dirs) - $KEEP` candidates.

### Who opens and closes a run

The **browser**, not the worker.

- `webui_lg_autocal_run_begin` — `usr/share/PGenerator/lg.pm:3455-3489`, calls
  `PGAutoCalRun::run_begin` at `:3485`. The manifest carries `workflow`,
  `controller_id`, `client_run_token`, `config`, `pgenerator_version` and `tv`.
- `webui_lg_autocal_run_end` — `usr/share/PGenerator/lg.pm:3492-3560`, calls
  `run_end` at `:3528`. It refuses to write a summary for a payload that cannot
  prove ownership: if the payload has no `run_id`, its `client_run_token` must
  match the manifest's, otherwise the callback is marked `unattributed` and
  neither writes the summary nor tears down workflow state (`:3510-3527`).
  A stale callback returns `stale_run_ignored: true` (`:3538-3544`).
- Endpoints: `POST /api/lg/autocal/run/begin` and `POST /api/lg/autocal/run/end`
  — `usr/share/PGenerator/lg.pm:3450-3451`.

### The separate Calibration History store

`/var/lib/PGenerator/lg/calibration-history` with `1d/` and `dv/` subdirectories —
`usr/share/PGenerator/lg.pm:2776-2778`.

- Writers: `_lg_cal_hist_archive_1d` (`:2882-2909`) and `_lg_cal_hist_archive_dv`
  (`:2911-2941`), called from `:2383` and `:2437`. Filenames are
  `<YYYYMMDD_HHMMSS>_<model>_<signal>_<picture>[_<variant>].json`.
- The DV archiver also mirrors a copy into the active PGAutoCalRun directory as
  `dv-profile-measurements.json` (`:2924-2933`).
- Listing merges the durable archive with live run directories and LUT files and
  sorts by mtime — `webui_lg_calibration_history_list`, `:2940-3137`.
- **No pruning and no delete endpoint. This store grows without bound.**

---

## 4. How the daemon runs on the Pi

**No systemd anywhere in the repo.** A `find` for `*.service` and `*.timer`
returns nothing. SysV init only.

### Boot path

1. `etc/init.d/PGenerator` `start)`:
   - Pins `PATH="/usr/sbin:/usr/bin:/sbin:/bin"` because cron's minimal PATH hides
     `setcap`, and without `cap_net_bind_service` the daemon silently falls back
     to port 8080 and the watchdog restarts it every minute forever (comment at
     the top of the file).
   - Self-heals sudoers ownership/modes, chmods helper binaries executable.
   - Creates and chowns `/var/lib/PGenerator/{tmp,images,video,ccss,updates}` and
     `/var/lib/PGenerator/lg/{ddc,luts,pin-sessions}` to `pgenerator:pgenerator`.
   - Mounts a 20 MB tmpfs at `/var/lib/PGenerator/running`.
   - Pre-sets the HDR connector property via `/usr/bin/pgsethdr`.
   - `setcap cap_net_bind_service=+ep /usr/bin/perl`, then
     `setsid sudo -u pgenerator env MALLOC_ARENA_MAX=1 /usr/sbin/PGeneratord.pl`,
     then `setcap ... -ep`.
2. `usr/sbin/PGeneratord.pl:39-44` — a `BEGIN` block re-execs the interpreter once
   if `MALLOC_ARENA_MAX` is unset, because glibc 2.21 on this image can deadlock
   when one thread forks while another creates a malloc arena (upstream bug 19182).
   Skipped under `perl -c`.
3. `usr/sbin/PGeneratord.pl:64-80` — `use lib "/usr/share/PGenerator"` then `do`
   each `.pm` (version, command, variables, conf, info, file, log, pattern, daemon, ...).
4. `usr/share/PGenerator/daemon.pm:23-42` — `fork_pattern_daemon` forks once, then
   in the child: `pattern_generator_start()`, and detached threads for
   `device_info`, `discovery_devicecontrol`, `discovery_lightspace`,
   `discovery_rpc`, `resolve_connection_thread`, `lg_startup_scan_worker`,
   `webui_http`, `webui_mdns`; then `pattern_daemon()` in the main thread.

### The HTTP server

`usr/share/PGenerator/webui.pm` uses `threads`, `threads::shared` and
`Thread::Queue` (lines 32-34). One accept thread feeds six queues:

| Lane | Queue created | Worker count |
|---|---|---|
| general | `:1098` | `$WEBUI_GENERAL_WORKER_COUNT`, threads at `:1105` |
| fast | `:1099` | threads at `:1108` |
| compute | `:1100` | 1 (`:774`), threads at `:1111` |
| tv | `:1101` | 1 (`:789`), threads at `:1114` |
| meter | `:1102` | 1 (`:791`), threads at `:1117` |
| renderer | `:1103` | 1 (`:793`), threads at `:1120` |

Routing: `webui_route_is_fast` (`:815-848`), `webui_route_is_compute` (`:851-857`),
`webui_route_is_loopback_pattern` (`:862-870`), `webui_route_device_lane`
(`:917-941`). **Every `/api/meter/*` path lands on the single meter worker**
(`:940`); `/api/lg/*` and `/api/cec/*` on the single tv worker (`:939`);
`POST /api/pattern` on the renderer worker (`:938`).

Queue caps at `:797-801`: general 128, fast 256, compute 1, tv 64. Priority
insertion and staleness expiry: `webui_route_enqueue` (`:874-888`),
`webui_priority_request_expired` (`:906-928`).

The comment at `:774-793` explains the lane split: a TV picture-settings read
legitimately holds a request for 11-12 s, and on a shared serialised lane that
starved calibration workers, which post `/api/pattern` with a 10 s budget and
`meter_series.sh` with 8 s.

### Watchdog

`etc/cron.d/pgenerator-webui-watchdog`:

```
* * * * * root /usr/sbin/pgenerator-webui-watchdog.sh >/dev/null 2>&1
```

`usr/sbin/pgenerator-webui-watchdog.sh`:

- Probes `http://127.0.0.1/api/ping` with `timeout 8 curl --connect-timeout 2
  --max-time 4`. The comment records why `wget -T` was replaced: wget's `-T` is
  per-operation and it retries up to 20 times, so against a wedged daemon it
  never returned and cron stacked instances (proven 3 September 2026).
- Single-instance guard via `/tmp/pgenerator-watchdog.pid`; a predecessor alive
  over 5 minutes is killed.
- On failure runs `/etc/init.d/PGenerator restart`, then polls up to 10 times at
  2 s intervals for recovery.
- Backoff: after 5 consecutive failed recoveries, retry only every 10 ticks.
- Observational root probe (`probe_webui_root`) checks for the
  `<!--PG_RECOVERY_PAGE-->` sentinel and a 64 KB minimum body; its result never
  enters the restart decision.
- Logs to `/tmp/pgenerator-watchdog.log`, trimmed at 200 lines / 256 KB.

`etc/cron.hourly/fake-hwclock` is the only other cron entry.

### No scheduler or queue abstraction exists

Grepping `Thread::Queue|->enqueue|->dequeue|job_queue|task_queue|scheduler|crontab|Schedule::`
across `usr/share/PGenerator/*.pm`, `usr/sbin/*.pl` and `usr/bin/*.pl` returns hits
only in `webui.pm` at lines 34, 885, 1095-1103 and 1280 — all the HTTP request
dispatcher. Nothing persists work across a daemon restart, and nothing can be
scheduled to run later.

---

## 5. Server-side config and settings persistence

### PGenerator.conf

`/etc/PGenerator/PGenerator.conf`, flat `key=value` text
(`usr/share/PGenerator/variables.pm:337-338`).

**Reads** go through `webui_reload_pgenerator_conf`,
`usr/share/PGenerator/webui.pm:9767-9800`. It parses into a private hash first,
then applies the delta under `lock(%pgenerator_conf)`. The comment at `:9768-9775`
records the bug this fixed: `%pgenerator_conf` is `share()`d, so the old
clear-then-refill published an EMPTY conf to every other thread for the duration
of the file read, and a plain `/api/config` poll could blank the conf out from
under a concurrent pattern request. If the file cannot be opened at all the live
hash is left untouched rather than half-published (`:9784-9789`).

The base loader is `get_pgenerator_conf` in `usr/share/PGenerator/conf.pm`
(bottom third of the file) — same regex, no locking, used at startup.

**Writes** never touch the file from the daemon process. The chain is:

1. `set_pgenerator_conf_runtime($key,$value)` —
   `usr/share/PGenerator/command.pm:90-94` — calls
   `&sudo("SET_PGENERATOR_CONF",$key,$value)` then updates the shared hash.
2. `usr/bin/PGenerator_cmd.pl:102` dispatches to `set_pgenerator_conf`.
3. `usr/bin/PGenerator_cmd.pl:1138-1167` reads the whole file, filters out the
   target key (and a paired key for the `dv_metadata`/`dv_map_mode` pair),
   appends `key=value`, and calls
   `&write_file("$pattern_conf.tmp","$pattern_conf","$content\n")`.

**There is no lock on that read-modify-write.** Two concurrent writers can lose an
update. The write itself is atomic (tmp + `rename`), so readers never see a torn
file, but a lost update is possible.

`webui_apply_config` — `usr/share/PGenerator/webui.pm:9829` onward — parses the
POST body with a regex, derives the coherent flag set for the requested
`signal_mode`, and routes each change through the same sudo path. It returns a
`$need_restart` flag that triggers the double-forked renderer restart described in
section 1.

### file.pm helpers

`usr/share/PGenerator/file.pm`:

- `write_file($tmp,$file,$content,$do_sync)` — lines 23-32. Writes the tmp file,
  `rename`s it, optionally `sync()`s. **No locking, no error checking on `open`.**
- `read_from_file($file)` — lines 37-45.
- `upload_file`, `get_destination`, `remove_files` — lines 50-90.

### Other persisted state

| What | Path | Format | Notes |
|---|---|---|---|
| Meter settings | `/tmp/meter_settings.json` | JSON | `webui.pm:7335`; does not survive a reboot |
| Worker configs | `/tmp/meter_lg_*_config.json` | JSON, verbatim request body | written chmod 0666, `webui.pm:6502-6508`, `:6934-6940` |
| ICC Companion pairing | `/var/lib/PGenerator/icc-companion/pairing.requests.json` | JSON | `webui.pm:453` |
| ICC Companion display/build | `.../display.json`, `.../build/*` | JSON + binary | `webui.pm:428-444` |
| Custom CCSS | `/var/lib/PGenerator/ccss/custom` | CCSS text | `webui.pm:468` |
| ICC profiles | `/var/lib/PGenerator/icc` | ICC | `webui.pm:426` |

No Storable, no SQLite, no database anywhere. Everything is JSON or flat text
written tmp-plus-rename.

### Concurrency guards that do exist

| Guard | Site | Protects |
|---|---|---|
| `flock` on `$var_dir/running/webui-apply.lock` | `webui.pm:1550-1558` | serialises renderer-restart workers; a failed retry ladder runs 30-40 s and a second apply would kill the renderer the first just started |
| `flock(LOCK_EX)` on `stages.ndjson` | `PGAutoCalRun.pm:148` | append-only stage log |
| `flock(LOCK_EX)` on `.summary.lock` | `PGAutoCalRun.pm:196` | `run_end` read-modify-write |
| `lock($_meter_lg_3d_autocal_start_lock)` | `webui.pm:402`, taken `:6799`, `:6963` | 3D autocal start/retry |
| `lock($_icc_pairing_lock)` | `webui.pm:455` | pairing store list read-modify-write |
| `lock($_webui_priority_sequence)` / `..._latest_dispatched` | `webui.pm:807-808`, `:878`, `:912` | priority request ordering |
| `lock($_meter_last_read_time)` | `webui.pm:466` | 0.25 s debounce on a physical meter read |
| `lock($_meter_stale_reap_last)` | `webui.pm:3707` | stale meter session reaping |
| `lock($resolve_disconnect_request)` | `webui.pm:11540-11567` | Resolve disconnect |
| `lock(%pgenerator_conf)` | `webui.pm:9791` | conf delta publication |
| `lg_helper_run` process-wide gate | referenced `webui.pm:929-931` | single-flight TV helper conversations |

**Not guarded:** the PGenerator.conf read-modify-write in `PGenerator_cmd.pl`, and
the 1D autocal start path (the 3D path has a lock, the 1D path does not).

---

## 6. Before/after report storage

### The one endpoint

`POST /api/meter/full-autocal/report-state` — dispatch
`usr/share/PGenerator/webui.pm:1968-1972`, handler
`webui_meter_full_autocal_report_state` at `usr/share/PGenerator/webui.pm:5950-5981`.

Behaviour:

1. Requires a non-empty body starting with `{` (`:5952`).
2. Extracts `run_id`, falling back to `runId`, then sanitises with
   `s/[^A-Za-z0-9_.-]/_/g` and defaults to `unknown` (`:5953-5957`).
3. Tries two directories in order (`:5958`):
   `/var/lib/PGenerator/reports/full-autocal`, then
   `/tmp/PGenerator_full_autocal_reports`.
   Creates each with `mkdir -p`, escalating to `sudo mkdir -p` plus
   `sudo chmod 0777` for the `/var/lib` path (`:5960-5966`).
4. Writes the **raw request body verbatim** to `<dir>/<run_id>.json` via tmp +
   `rename`, chmod 0666 (`:5968-5978`).
5. Returns `{"status":"ok","path":"<file>"}`.

### What the payload contains

Assembled client-side in `meterFullAutoCalArchiveReportData`,
`usr/share/PGenerator/webui-workspace.js:6380-6404`:

```json
{
  "run_id": "...", "stage": "started|...", "saved_at": 1234567890,
  "report":  { "pre": ..., "post": ..., "stages": {}, "reset": ...,
                "run_id": ..., "started_at": ..., "signal_mode": ...,
                "pre_cal_skipped": ... },
  "config":  { ...meterFullAutoCalConfig... },
  "results": { ...meterFullAutoCalResults... },
  "extra":   null
}
```

The `report` object shape is `meterFullAutoCalDefaultReportData` at
`usr/share/PGenerator/webui-workspace.js:6301-6303`. It lives in `localStorage`
between posts (`:6305-6335`) and is re-anchored to the correct run by
`meterFullAutoCalEnsureReportRun` (`:6361-6378`) — that function exists because a
resumed/adopted run reused a prior run's object, freezing `started_at` ~12 hours
before the actual calibration.

### No list, no read, no delete, no retention

Scanning the full endpoint table in `usr/share/PGenerator/webui.pm:1490-2311`,
`full-autocal` appears exactly once, as the POST above. There is:

- no `GET /api/meter/full-autocal/...` listing endpoint,
- no delete endpoint,
- no pruning code anywhere for either directory.

The files are only ever read back by the built-in diagnostic bundle, which globs
both directories, sorts by mtime descending and inlines **only the single newest
file** — `usr/share/PGenerator/webui.pm:10513-10521`.

### The adjacent Calibration History endpoints

`usr/share/PGenerator/lg.pm:3420-3427`:

- `GET /api/lg/calibration-history` — `webui_lg_calibration_history_list`
  (`lg.pm:2940-3137`). Merges durable `1d/` and `dv/` archives with live
  PGAutoCalRun directories and `/var/lib/PGenerator/lg/luts` entries, sorts by
  mtime, returns `{status:ok, items:[...]}`. No cap on the number of items.
- `POST /api/lg/calibration-history/download` — `lg.pm:3138` onward.
- `POST /api/lg/calibration-history/reupload` — `lg.pm:3426`.

**Still no delete.** The only automatic deletion anywhere in this area is
`PGAutoCalRun::_prune` keeping 10 run directories.

Related report surfaces: `/api/3d-lut/luts` and `/api/3d-lut/delete`
(`usr/share/PGenerator/webui.pm:2194`, `:2199`) do have a delete, but that is for
LUT files, not reports.
