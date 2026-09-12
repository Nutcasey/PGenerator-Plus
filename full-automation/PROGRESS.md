# Full automation progress

Status: implementation and live proof are in progress on `feature/full-automation`. No full-length proof has been run yet, and no pull request has been opened.

The live target is the owner's LG `OLED55G36LA` G3, webOS 23, software/firmware `23.25.55`, webOS release `9.2.2`, with a physical Calibrite/X-Rite i1Display Pro Plus. The G3 exposes `backlight`, `energySaving`, and `pictureMode` through the current control API. It does not expose the original G5 `oledPixelBrightness` key.

## Proved examples

- **A3 measurement-only:** run `20260912-202614-c14ff8` completed with 21 physical SDR greyscale readings. The item applied and verified its settings, performed no calibration reset, and stored `pre/greyscale-21.json`. Evidence: `/Users/garry.casey/PGenerator-automation-evidence/20260912-2027-smoke-measure-g3/`.
- **A1 half:** run `20260912-203842-bf30b8` completed with 21 physical HDR10 greyscale readings using the G3-supported fixed `backlight=100` and `energySaving=off`. Settings setup and readings passed; a successful HDR calibration reset and reapply proof remains open. Evidence: `/Users/garry.casey/PGenerator-automation-evidence/20260912-2040-smoke-settings-hdr-g3/`.
- **A10 stop:** run `20260912-215737-194374` stopped during greyscale. The run and item are `stopped`, `greyscale-done` is `interrupted` with `verified=false`, the worker exited after the graceful stop path, calibration mode was closed, and the visible pattern was restored to gray50. Evidence: `/Users/garry.casey/PGenerator-automation-evidence/20260912-2157-stop-path-proof-g3/`.
- **Readiness and identity:** live readiness names the G3 model, firmware, generation, and supported picture keys. The hazard probes report the controls that the TV does not expose.

## Current plan

1. Deploy and live-test the meter-session cleanup patch. The runner now posts `/api/meter/session/stop` from both `_stop_active` and `_finish`. Readiness treats a persistent session as reusable when no guided worker or meter series is active.
2. Run one short SDR calibration smoke through c6 to c11, capturing every checkpoint and worker artefact. If the G3 repeats the exact-zero low-shadow readings, record the recurrence as FAB-107 and treat calibration completion as blocked while proving the remaining examples around it.
3. Prove the remaining short examples: calibration-only and apply-all, fault and resume, consecutive same-mode items, browser-closed execution, rerun history, warning or unverified history, mutual locks, daemon restart, and target panel-light settling.
4. Announce the full-length proof before starting it. Run at least three SDR items followed by at least two HDR items, with pre-readings, calibration, apply-to-all, and post-readings, including one complete item with the browser closed. Capture the bundle before any restart and obtain the owner's history review.
5. Run the repository checks, review the complete diff and history, commit milestones, push `feature/full-automation`, and open exactly one PR to `origin/main`. Do not merge it.

## Known bug and open items

The failed run `20260912-210733-972f3e` recorded FAB-107: repeated exact-zero XYZ reads at SDR26 7% from 21:22:45 through 21:36, followed by Y=`7.425821` at 21:37:45 and restoration to best dE=`98.240897`. The observed effect was a black TV period and a fail-open calibration result. The worker behaviour is out of scope; the FAB, timestamps, effect, and logs are recorded in that run's `run.json` and `NOTES.md`.

Runs `20260912-205309-c46858` and `20260912-210152-e4d509` remain unsuccessful smoke evidence for the LG WebSocket drop and pre-token worker guard failure. Their `NOTES.md` files now state the target and exact failure.

Open work is the meter-session live proof, a calibration smoke that reaches c6-c11, the unproved acceptance examples listed above, the full-length run and owner history review, final CI, and the single PR.
