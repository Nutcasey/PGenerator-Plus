# Chart targets, resolution and log severity

## Fixes

- Shared snapshot reports temporarily use each snapshot's gamma selector,
  restoring the manual selection even after a rendering failure. Gamma labels
  use the same resolved target as the chart instead of an unrelated selector.
  A report-scoped target also prevents asynchronous startup restoration from
  changing the target between animation frames while a snapshot is rendered.
- Automation chart images render at the destination width and screen pixel
  density. Window resizing rebuilds images from cached measurements without
  requesting measurements or changing the TV. EOTF and luminance use full-width
  panels in the read-only Calibration workspace.
- Numeric luminance/gamma/chromaticity residuals do not imply execution errors.
  Active retries and reconnect attempts are warnings; exhausted retries and
  cleanup failures remain errors. Normal Stop requests are informational.
- Successful pending-queue edits with warnings use amber rather than the
  blocking-error path. A stopped job's stage-only interruption record is
  neutral; an accompanying actual failure message remains red.

Calibration algorithms, targets and convergence tolerances were not changed.
Historical logs were not rewritten: classification happens when they are read.

## Verification

- 46 backend suites, 1,830 assertions passed.
- Offline activity, editor, job detail, history and observer browser tests passed.
- Deployed shared-renderer test used the saved SDR Cinema 1D measurements from
  `20260914-143401-8abd68`, freezing them in a read-only browser view. Its
  simulated running status was for rendering only; no calibration was started.
- Gamma 2.2 was shown while the manual selector remained BT.1886 afterward.
- At DPR 2, a 1,312px panel used 2,644px images; after resizing to 1,912px,
  images were 3,844px. Aspect ratios, full-width charts and mobile fit passed.
- The exact reported 2.3% / attempt 7 log line now has severity `info`. All 77
  numeric luminance-error lines in the inspected recent log window were `info`.
- Regressions retain red for actual upload failure, exhausted retries, failed
  cleanup, artifact failures and failed operations suggesting a manual retry.

## Stop and deployment

Stopped run `20260914-143401-8abd68` during Job 1's 3D LUT stage. Saved cleanup
proof says all workers stopped, meter released and TV acknowledged calibration
exit. A separate process audit found no workers; LG status confirmed connected
and calibration mode false.

Five runtime files updated: webui-app.js, webui-workspace.js,
webui-automation.js, webui-automation.html and webui.pm.
Backup: `/root/pgen-chart-severity-ir4BNK/before/` on the Pi.
All 608 packaged files were checksum-verified after deployment/restart.
Final boot ID: `d8c1b0d6-70d9-4b24-a876-49805c9bad57`.
No new calibration was started. Refresh any browser tab opened before deployment.
