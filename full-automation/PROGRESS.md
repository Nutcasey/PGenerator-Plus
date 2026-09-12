# Full automation progress

Status: implementation and live proof are in progress on `feature/full-automation`. No full-length proof has been run yet, and no pull request has been opened.

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

1. Deploy and live-test the meter-session cleanup patch. The runner now posts `/api/meter/session/stop` from both `_stop_active` and `_finish`. Readiness treats a persistent session as reusable when no guided worker or meter series is active.
2. Let the active SDR Filmmaker calibration smoke finish without intervention. If the G3 repeats the exact-zero low-shadow readings, record the recurrence as FAB-107 and treat calibration completion as blocked while proving the remaining examples around it.
3. Prove the remaining short examples: calibration-only and apply-all, fault and resume, consecutive same-mode items, browser-closed execution, rerun history, warning or unverified history, mutual locks, daemon restart, and target panel-light settling.
4. Announce the full-length proof before starting it. Run exactly SDR Filmmaker, HDR10 Filmmaker, and Dolby Vision Filmmaker in that order, with pre-readings, calibration, apply-to-all, post-readings, and default sweeps on every item; enable quality limits on at least one item. Include one complete item with the browser closed. Capture the bundle before any restart and obtain the owner's history review.
5. Run the repository checks, review the complete diff and history, commit milestones, push `feature/full-automation`, and open exactly one PR to `origin/main`. Do not merge it.

## Known bug and open items

The failed run `20260912-210733-972f3e` recorded FAB-107: repeated exact-zero XYZ reads at SDR26 7% from 21:22:45 through 21:36, followed by Y=`7.425821` at 21:37:45 and restoration to best dE=`98.240897`. The observed effect was a black TV period and a fail-open calibration result. The worker behaviour is out of scope; the FAB, timestamps, effect, and logs are recorded in that run's `run.json` and `NOTES.md`.

Runs `20260912-205309-c46858` and `20260912-210152-e4d509` remain unsuccessful smoke evidence for the LG WebSocket drop and pre-token worker guard failure. Their `NOTES.md` files now state the target and exact failure.

At 22:52, the browser could not render the active run because `runs/current` returned about 429 KB in 3.3–4.9 seconds and `runs` returned about 429 KB in 22.7–23.6 seconds, exceeding the WebUI's 5-second read timeout. The local fix is ready but deployment is held until the active run finishes: current state will expose only the run summary and integer active-item index, the history endpoint will return listing rows, full detail will be loaded from `runs/<id>`, and series files will be fetched through the artefact route when a history entry opens. The runner will persist only the six-field worker summary in `run.json`; full worker state remains under the item calibration directory.

Goal section 4.3 specifies the automation endpoints on the `tv` lane. The read-only `GET` routes for runs, current state, run detail, and artefacts now route on the general lane as an explicit deviation. They only read automation files, and moving them prevents a slow LG command from blocking live status and history; readiness and all writes remain on the `tv` lane.

Open work is the meter-session live proof, a calibration smoke that reaches c6-c11, the unproved acceptance examples listed above, the full-length run and owner history review, final CI, and the single PR.
