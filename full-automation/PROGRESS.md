# Full automation progress

Status: preparation review and fixes are deployed on `feature/full-automation`. The owner has switched the TV off and explicitly limited further work to preparation. No full-length proof has been run, and no pull request has been opened.

The live target is the owner's LG `OLED55G36LA` G3, webOS 23, software/firmware `23.25.55`, webOS release `9.2.2`, with a physical Calibrite/X-Rite i1Display Pro Plus. The G3 exposes `backlight`, `energySaving`, and `pictureMode` through the current control API. It does not expose the original G5 `oledPixelBrightness` key.

## Proved examples

- **A3 measurement-only:** run `20260912-202614-c14ff8` completed with 21 physical SDR greyscale readings. The item applied and verified its settings, performed no calibration reset, and stored `pre/greyscale-21.json`. Evidence: `/Users/garry.casey/PGenerator-automation-evidence/20260912-2027-smoke-measure-g3/`.
- **A1 half:** run `20260912-203842-bf30b8` completed with 21 physical HDR10 greyscale readings using the G3-supported fixed `backlight=100` and `energySaving=off`. Settings setup and readings passed; a successful HDR calibration reset and reapply proof remains open. Evidence: `/Users/garry.casey/PGenerator-automation-evidence/20260912-2040-smoke-settings-hdr-g3/`.
- **A10 stop:** run `20260912-215737-194374` stopped during greyscale. The run and item are `stopped`, `greyscale-done` is `interrupted` with `verified=false`, the worker exited after the graceful stop path, calibration mode was closed, and the visible pattern was restored to gray50. Evidence: `/Users/garry.casey/PGenerator-automation-evidence/20260912-2157-stop-path-proof-g3/`.
- **A9 queue-side lock:** while run `20260912-222523-2ae30e` was active, the live 1D, 3D, series, DV-profile, and single-read starts returned `error_code=automation-active` without an automation token. Evidence is being held in `/Users/garry.casey/PGenerator-automation-evidence/20260912-2225-smoke-cal-sdr-filmmaker/checks/A9-lock-responses.json`; the reverse guided-worker-to-queue refusal remains open.
- **Readiness and identity:** live readiness names the G3 model, firmware, generation, and supported picture keys. The hazard probes report the controls that the TV does not expose.

## Prepared proof inputs

- Saved on the Pi: `smoke-cal-hdr10-filmmaker` recipe `20260912-224645-2a7597` and `smoke-cal-dv-filmmaker` recipe `20260912-224645-46813f`. Both use Filmmaker mode, fixed G3-supported `backlight`, calibration, and apply-to-all; the short versions skip pre/post sweeps.
- A4 fault step: before a calibration item reaches c9, write `/var/lib/PGenerator/automation/fault.json` as `{"stage":"apply-all","mode":"error"}`. Let the runner stop, remove the fault file, resume the same run, and verify c9 reruns while c4–c8 timestamps and artefacts remain unchanged.

## Current plan

1. Leave the Pi idle for the owner's batch test. No TV connection, settings write, measurement, or calibration is required for further preparation.
2. When live testing is authorized again, prove the remaining short examples: calibration-only and apply-all, fault and resume, consecutive same-mode items, browser-closed execution, rerun history, warning or unverified history, mutual locks, daemon restart, and target panel-light settling. Meter-session cleanup is deployed but still needs the live success-path proof. An unrelated persistent meter session now correctly blocks a new queue; only the owning automation token may reuse it.
3. Announce the full-length proof before starting it. Run exactly SDR Filmmaker, HDR10 Filmmaker, and Dolby Vision Filmmaker in that order, with pre-readings, calibration, apply-to-all, post-readings, and default sweeps on every item; enable quality limits on at least one item. Include one complete item with the browser closed. Capture the bundle before any restart and obtain the owner's history review.
4. Open exactly one PR to `origin/main` after the required live evidence and owner review. Do not merge it. Local preparation checks do not satisfy the live acceptance criteria.

## Preparation review

- Merged `origin/main` through `65f49669`, including LG display-control support reasons, favicon assets, and deploy-console fixes. Both upstream and automation CI checks are retained.
- Rebuilt the setup as a queue with a per-item modal: signal and picture mode, before/after sweep selection, explicitly pinned TV settings, fixed/target panel light, luminance, white point, gamma/gamut, dE target/formula, 3D LUT method/export size, Dolby Vision profile explanation, and per-sweep quality limits. Measurement settings and advanced recipe fields stay in each snapshot. Picture pins can be prepared offline; readiness checks actual support before a run.
- Fixed queue draft persistence, saved-queue selection, safe pending-item edits under the run lock, stale editor rejection, and loss of edited pending items when the runner advances or completes.
- Corrected worker payloads, stop responsiveness during long HTTP calls, interrupted-run recovery, partial reading preservation, calibration closure verification, apply-all verification, and panel-light settling evidence. Missing verification is recorded as unverified, not success.
- Quality limits now calculate dE from saved measured XYZ and target metadata. Missing or unusable measurements cannot pass a quality check. Zero-valued quality limits, patch delays, settle delays, and optional polishing budgets are preserved.
- Fixed first-item artifact access (`items/0` was falsely rejected), Unicode storage, history deletion, and graph rendering from the otherwise hidden calibration workspace. History uses saved artifacts, not a fresh measurement.
- Backed up and stopped stale interrupted run `20260912-222523-2ae30e`. Its history remains. Because the TV was off, calibration closure was explicitly recorded as unverified. No batch is active.
- Local verification: 11 test files / 135 tests pass; all workflow Perl syntax checks and relevant JavaScript checks pass; `git diff --check` passes. Browser checks on the Pi cover workspace navigation, per-item editing and zero-value round trips, and saved-history rendering. Run `20260912-202614-c14ff8` renders 21 saved readings and five greyscale charts without browser errors. This is saved-data/UI proof, not a new physical calibration proof.
- Review evidence and screenshots: `/Users/garry.casey/PGenerator-automation-evidence/20260912-review/`. Existing user-owned untracked files and `Bugs/` were not changed or included.
- Final offline browser check built separate SDR/HDR10/Dolby Vision items with distinct dE targets, explicit energy-saving pins, SDR target luminance, and zero delays; duplication did not alias snapshots, reordering preserved them, and all three survived reload. No POST requests occurred. The item modal also fits a 390-pixel viewport without horizontal overflow.

## Known bug and open items

The failed run `20260912-210733-972f3e` recorded FAB-107: repeated exact-zero XYZ reads at SDR26 7% from 21:22:45 through 21:36, followed by Y=`7.425821` at 21:37:45 and restoration to best dE=`98.240897`. The observed effect was a black TV period and a fail-open calibration result. The worker behaviour is out of scope; the FAB, timestamps, effect, and logs are recorded in that run's `run.json` and `NOTES.md`.

Runs `20260912-205309-c46858` and `20260912-210152-e4d509` remain unsuccessful smoke evidence for the LG WebSocket drop and pre-token worker guard failure. Their `NOTES.md` files now state the target and exact failure.

At 22:52, the browser could not render the active run because `runs/current` returned about 429 KB in 3.3–4.9 seconds and `runs` returned about 429 KB in 22.7–23.6 seconds, exceeding the WebUI's 5-second read timeout. The fix is now deployed: current state exposes only the run summary and integer active-item index, the history endpoint returns listing rows, full detail loads from `runs/<id>`, and series files are fetched through the artefact route when a history entry opens. The runner persists only the six-field worker summary in `run.json`; full worker state remains under the item calibration directory.

Goal section 4.3 specifies the automation endpoints on the `tv` lane. The read-only `GET` routes for runs, current state, run detail, and artefacts now route on the general lane as an explicit deviation. They only read automation files, and moving them prevents a slow LG command from blocking live status and history; readiness and all writes remain on the `tv` lane.

Open work is the meter-session live proof, a calibration smoke that reaches c6-c11, the unproved acceptance examples listed above, the full-length run and owner history review, final CI, and the single PR.
