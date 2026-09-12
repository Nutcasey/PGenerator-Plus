# Live proof results

Status: in progress. Evidence is stored outside the repository at `/Users/garry.casey/PGenerator-automation-evidence/` and is never committed.

The live target is an LG `OLED55G36LA` (G3), firmware `23.25.55`, webOS 23, webOS release `9.2.2`, generation `lg2022plus_oled`. The attached physical meter is a Calibrite/X-Rite i1Display Pro Plus (`0765:5020`).

| Acceptance | Result so far | Evidence |
|---|---|---|
| A1 | Partial: HDR Filmmaker settings setup and physical greyscale readings passed. The G3 does not expose the original G5 `oledPixelBrightness` key; the live recipe used supported `backlight` and `energySaving`. Reset reapply still needs a dedicated successful HDR calibration proof. | `20260912-2030-smoke-settings-hdr-g3-failed/`, `20260912-2035-smoke-settings-hdr-g3-meter-failed/`, `20260912-2040-smoke-settings-hdr-g3/` |
| A2 | Pending: calibration-only run must complete and render stored calibration graphs with apply-to-all. | — |
| A3 | Passed by a complete SDR measure-only run with 21 physical readings and no calibration reset. | `20260912-2027-smoke-measure-g3/` |
| A4 | Pending: live apply-all fault injection and resume proof. | — |
| A5 | Pending: two same-mode items in one queue. | — |
| A6 | Partial: server-side runner and checkpoint persistence are live; a whole-item browser-closed proof remains. | `20260912-2027-smoke-measure-g3/`, `20260912-2040-smoke-settings-hdr-g3/` |
| A7 | Pending: rerun history preservation proof. | — |
| A8 | Pending: live warning or unverified apply-all history proof. | — |
| A9 | Pending: both queue/guided mutual refusal paths. | — |
| A10 | Stop portion passed on the live G3. Stop during greyscale produced run `stopped`, item `stopped`, `greyscale-done` `interrupted`, worker exit evidence, calibration mode off, and visible gray50 cleanup. | `20260912-2157-stop-path-proof-g3/` |
| A11 | Pending: daemon restart and killed-runner interrupted/resume proof. Pi reboot remains owner-authorized only. | — |
| A12 | Pending: SDR target panel-light convergence and post-reset enforcement proof. | — |
| A13 | Pending: announced full-length queue of at least three SDR then two HDR10 items, owner history review. | — |

## Stalled black-screen run

Run `20260912-210733-972f3e` is deliberately not counted as a successful calibration. The worker received repeated exact-zero XYZ values at the SDR26 7% low-shadow patch, later saw Y=7.425821, and restored best dE=98.240897. FAB-107 and the black-screen effect are recorded in that run's `run.json` and `NOTES.md`. The original stop race left the item falsely failed and is preserved as regression evidence; the corrected stop path is the A10 evidence above.
