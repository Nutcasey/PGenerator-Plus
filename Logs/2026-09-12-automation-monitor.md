# Full-automation goal: monitor log (Claude, cmux workspace:22 surface:115)

Codex goal runner: cmux workspace:22 surface:112, gpt-5.6-luna, branch feature/full-automation, "Pursuing goal" since ~17:50.
Pi: 192.168.50.110 (pgenerator.local; SSH host key changed since 31 Aug, `pgen` alias needs known_hosts line 32 replaced). TV: OLED55G36LA (G3, webOS 23) at 192.168.50.28.

## 21:40 check-up (first)
State: 8 runs since 20:26. Measure-only SDR (202614) and HDR settings (203842) complete. Calibration smoke (smoke-cal-sdr-g3, Cinema, matrix, 1 iteration) failed 5x: mode switch before format settled, renderer not settling, TV unreachable, then greyscale failure.
Owner reported TV completely black at 21:36. Cause: worker read exact-zero XYZ on sdr26_7% 21:22:45-21:36 (72 null-reading events), light returned 21:37:45; worker restored "best" dE=98 (known fail-open zero-reading behaviour).
Run 210733-972f3e marked stopped, lock released, but worker PID 8551 orphaned and TV left in calibration mode. Stop path bug: STOP_REQUESTED during _wait_worker turns into a failed stage instead of interrupted; worker stop file never written.
Local checks: perl -c clean on all changed files; prove t/ 88/88 pass; deployed hashes match working tree.
Steer sent 21:39 (queued behind Codex's next tool call): stop orphan worker + close session before any new run; fix stop path per goal 4.1; record FAB effect not fix; commit now (0 commits so far); bundle evidence before restarts (Codex had just started ~/PGenerator-automation-evidence/20260912-2107-smoke-cal-sdr-worker-failed); log checkpoint transitions in runner.log; readiness should state model/firmware/generation.

## 22:05 check-up
Since 21:40: Codex stopped the orphan worker within a minute of the steer (21:39:40), fixed the stop path and proved it live (run 215737 stop-path-proof: item stopped, greyscale-done interrupted, calibration mode off), redeployed (daemon restart ~21:55), committed everything as c140a653 (7342 lines; docs and full-automation/ in; no Bugs/ or Logs/). Evidence bundles exist for all ten runs; NOTES.md missing in 2053-lg-drop and 2101-worker-failed. Readiness now states model/firmware/generation (OLED55G36LA, fw 23.25.55, lg2022plus_oled, webOS 9.2.2) and probes hazard keys (none exposed on G3 -> manual preconditions).
New problem: meter_session.sh PID 2218 (started 21:59:35 by the daemon for the proof run) survives the run; readiness now ready:0 meter-idle. Runner never calls /api/meter/session/stop. Steered: close the session at _finish/_stop_active, make meter-idle ignore runner-owned sessions; stop analysing the 7% null readings (record FAB, move on); write full-automation/PROGRESS.md before compaction (context 29% left); add missing NOTES.md.
Local: prove t/ 88/88 pass; deployed hashes match c140a653 working tree. Acceptance status: A3 proved (202614), A1 first half (203842), A10 stop half (215737). Calibration smoke (c6-c11) still never completed. Not yet: A2, A4, A5, A6, A7, A8, A9, A10 pause/resume, A11, A12, A13, UI/history view.

## 22:09 owner decision relayed
Owner: the ideal test is one SDR, one HDR and one Dolby Vision run, all in Filmmaker mode. Relayed to Codex as the full-length proof queue (replaces the 3 SDR + 2 HDR minimum in goal 1.4); asked it to record the decision in the goal file and commit, keep the section 8 announcement, and aim the smoke recipes at SDR/HDR10/DV Filmmaker.

## 22:24 check-up
Codex committed 44959fd4 "fix: close automation meter sessions" and deployed it (hashes match); wrote full-automation/PROGRESS.md; context recovered to 52% (compaction). It started Cinema calibration smoke 221516 at 22:15, which for the first time progressed through the greyscale (step 10/28, dE 3.3 at 75%), then stopped it at c6 on reading my Filmmaker steer, to avoid confusing it with the Filmmaker proof. The stop proved the new meter-session cleanup live (stop cleanup meter session=ok, PID file gone). No orphans; calibration mode off; tests 88/88; perl -c clean on all Perl files. Owner decision not yet written into the goal file.
Steered: smoke runs may use any mode (goal section 2); do not stop, restart or redeploy during the next calibration smoke; let it complete to close c6-c11, A2, A5; write the owner decision into the goal file and commit; then run the SDR Filmmaker calibration smoke to completion.
Acceptance: A3, A1-half, A10-stop proved. Still open: full calibration path, A2, A4, A5, A6, A7, A8, A9, A10 pause/resume, A11, A12, A13, UI/history.

## 22:45 check-up
Codex committed 3ebb1c1a "docs: set filmmaker proof queue" (owner decision in goal 1.4, 2, A13, Appendix A). Run 222523 smoke-cal-sdr-filmmaker started 22:25 and reached greyscale step 24/28 (sdr26_7%) at 22:40, where the FAB-107 exact-zero XYZ readings recurred; worker in the reread loop, runner heartbeat fresh, TV on in calibration mode. Codex is leaving it to finish naturally and recording FAB-107. Tests 88/88, perl -c clean, deployed hashes match HEAD. Context 27%.
Steered: prove A9 now while the run is active (all guided starts must refuse with automation-active); poll less often; pre-write HDR10/DV Filmmaker recipes and the A4 fault step. I am checking the web UI Live view in Chrome (viewer only).

## 22:52 browser check (viewer side, A6)
Opened http://192.168.50.110/ in Chrome during run 222523. Automation card renders and fetches, but shows idle / No active run / No automation history. Cause measured: GET runs/current 429 KB in 3.3-4.9 s, GET runs 429 KB in 22.7-23.6 s (Mac), UI fetch timeout 5 s -> both abort silently. run.json 96 KB per heartbeat because full worker_status is embedded. Steered: small summary for runs/current, listing-only for runs, lazy full run + artefacts, trimmed worker summary in run.json, read-only GETs on the general lane (note deviation from goal 4.3), verify in a browser after the run finishes. Run 222523 still at sdr26_7% zero-reading loop (22:48).

## 23:05 check-up
Codex committed 0c258d3a "docs: prepare format proof inputs" and has the endpoint/UI slimming edited but uncommitted (runs/current summary now 490 bytes, listing-only runs, lazy series, six-field worker summary in run.json, read-only GETs on the general lane with the deviation documented); node --check, git diff --check, perl -c and prove all pass; not deployed (run still active). Run 222523: greyscale at sdr26_5% (25/28); FAB-107 zero readings recurred at 5% after 7% took ~20 min. No orphans; TV on, calibration mode on (expected). Evidence bundle 2225-smoke-cal-sdr-filmmaker started.
Steered: commit now, deploy after the run; ~20 min per near-black point so plan timing; my Chrome tab was open 22:47-23:04 so 222523 cannot count for A6 (tab closed; I will stay out of the UI until asked).
Acceptance unchanged: A3, A1-half, A10-stop proved. Waiting on first complete calibration item.

## 23:24 check-up
Codex committed 2229876c "fix: keep automation live responses small" (tree clean, tests 88/88, perl -c clean); deploy gated until run 222523 ends. Run 222523 at sdr26_4% (26/28); FAB-107 zero readings at 7%, 5% and now 4%, ~20 min each. Runner heartbeat fresh, no orphans, calibration mode on as expected. Codex context 39% (was 48%) from 40 s narrated sleeps.
Steered: use one blocking wait per tool call instead of narrated 40 s sleeps; projected greyscale end ~00:05, item ~00:30; budget 1.5-2 h per Filmmaker item (5-6 h for the three-item proof) for the section 8 announcement.
Acceptance unchanged.
