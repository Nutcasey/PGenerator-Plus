# Dolby Vision shadow stall and graph feedback

## Evidence

Run `20260914-155240-8e9c40`, Dolby Vision Filmmaker, stalled at 5%.
The meter repeatedly returned Y=0 rather than the approximately 1.88 cd/m²
target. Browser job requests continued, but all five chart images stayed the
same because the worker produced unchanged measurements.

The runner authored 5% as code 13 / input_max 255. The deployed pattern log
showed that becoming code 208 in the 12-bit source domain, with
SOURCE_RANGE=LIMITED. DV black is 256 in that domain. The manual chart/wizard
policy already authored 12-bit Limited values independently of the Full,
8-bit HDMI transport; the automation greyscale builder incorrectly reused
the transport settings as the source-code policy.

The shadow sampler discarded four invalid samples, then fell through to a
regular read which accepted another zero. Solver iterations therefore
continued without useful measurements. Probe and restoration reads also had
paths which ignored exhausted measurement errors.

## Fixes

- Automation DV greyscale uses the shared signal-code policy with 12-bit
  Limited source values, matching the manual wizard. 5% is now 431 / 4095;
  black is 256 and nominal white 3760. HDMI settings are not rewritten.
- Exhausted shadow samples return a terminal measurement error rather than
  falling through. Disabled median/application-averaging paths also reject
  unusable shadow readings. True black, valid very dim readings and the
  existing valid-sample median/fallback behavior are retained.
- HDR/DV probe and restoration failures, and SDR restoration failures,
  propagate through the existing measurement-error/calibration-exit path.
- Live job details carry retry state and activity. An amber notice explains
  invalid-measurement retries and unchanged graphs. Normal activity shows
  the last valid measurement time; successful recovery clears the warning.

Targets, convergence math, LUT construction and valid low-light probe-up
behavior are unchanged. Historical measurements have not been rewritten.

## Verification

- 48 backend suites / 2,085 assertions passed.
- DV encoding covers all configured anchors and Dark Detail fillers across
  transport bit depths/ranges. SDR and HDR10 encoding regressions pass.
- Tests cover exhausted zeros, recovery, valid sub-floor values, true black,
  application averaging, cancellation and real HDR/DV initial-probe failure.
- Activity, history, refresh, editor, job-detail and Calibration observer
  browser regressions passed.
- Real shared-renderer browser replay passed successive image changes via
  normal polling in Automation and Calibration, plus gamma, high-DPI,
  resize/aspect-ratio and mobile checks. This is explicitly a browser-only
  replay of measurements, not a completed physical TV calibration.

## Deployment

The affected run was stopped through the automation Stop endpoint. Saved
cleanup evidence confirms worker exit, meter release and acknowledged TV
calibration-mode exit; separate process and LG status checks agreed.

Four runtime files changed: `meter_lg_autocal.pl`,
`pgen_automation_runner.pl`, `webui-automation.js`, `webui.pm`.
Backup on Pi: `/root/pgen-dv-graphs-y1A0uX/before/`.
All 608 packaged files matched local SHA-256 before reboot; device-specific
configuration and runtime data were preserved. No new calibration was started.

Post-reboot boot ID: `9b941f4b-b07f-4024-ac4d-ea33c0876881`.
All 608 packaged SHA-256 hashes still match. Deployed runner code generation
returns DV black/5%/white as 256/431/3760, all with input_max 4095.
Native fresh-page loading shows five saved graphs with no automation request
failures or JavaScript errors. Deployed (no local overlays) browser replay
also passed successive graph updates in both views. Stored TV pairing
reconnected successfully; calibration mode is off and worker audit is empty.
