# Calibration blackout / cached observer fix

## Incident and evidence

Failed job: `20260914-091714-cb81c9`, Test Queue, SDR Filmmaker.
The worker measured provisional white at 432.523725 cd/m², successfully uploaded
the identity 1D curve, then received three all-zero reads of the same white patch.
It aborted before lower anchors. The error wrapper incorrectly called this an
upload failure (`white_no_reading`); a summary also printed a committed dE of zero.

Two `/api/pattern` requests arrived at epoch 1789370786, immediately before the
blackout, while only one white patch was recorded. The old debug log did not
record stop commands or request origins, so the second request's historical body
cannot be proven. This is strong circumstantial evidence, not a captured stop body.

The browser bug was reproduced against the unmodified deployed UI: recovering a
cached `running` snapshot without a series ID sets `meterSeriesRunning` and starts
`meterPollSeries`. It can consume a previous completed series, whose completion
handler unconditionally clears the display. Graph/report cache restoration uses
this no-ID recovery path. This affects normal calibration observers as well as
the automation detail panel.

A controlled test used the same normal `/api/lg/1d-dpg/upload` endpoint, SDR
Filmmaker, 3072-value identity curve and held calibration mode. Two immediately
subsequent 940/1023 white reads returned 442.570262 and 443.036395 cd/m².
CAL_END was acknowledged, followed by complete meter cleanup. This did not
reproduce an upload-induced blackout. An earlier diagnostic used incorrect RGB
request fields and is explicitly excluded from white-read evidence.

Failed-run evidence was copied before testing to
`/tmp/pgen-white-failure-xvtoMY/`, including the run directory, worker state/log,
meter session log, pattern log and worker configuration. Pairing/ownership
credentials must not be published from these private diagnostic files.

## Changes

- Cached/report snapshots without a server series ID no longer start live polls.
  Terminal/cache recovery also clears old polling timers.
- Background completion clears carry `only_if_unowned`.
- Both local-renderer and companion HTTP routes reject external pattern changes
  during automation, 1D/3D calibration, Dolby Vision profiling, series or an
  active individual read. Local workers keep using the same renderer. Explicit
  Stop still uses the full worker cancellation and calibration-exit path.
- Session and series workers share `pgen_meter_pattern.sh`: bounded transport,
  valid JSON and an explicit accepted patch are required before measuring.
  Failures preserve a specific pattern error, not a timeout or black measurement.
- SDR and HDR DPG anchor read failures stop through the normal error-cleanup
  path, retaining the actual meter reason and previously measured evidence.
  They cannot proceed with stale readings or invent a final dE / completed LUT.
- Error cleanup only clears calibration mode after an explicit acknowledgement.
  An unconfirmed exit stays visible with recovery instructions. The malformed
  error-log expression now prints the real error and cancellation status.
- Pattern debug logging now includes accepted non-patch controls such as Stop;
  rejected external controls identify the operation holding the display.

The existing 1D upload implementation, solver targets, LUT math and queue settings
are unchanged. No alternative automation-specific uploader was introduced.

## Validation / deployment

- 38 Perl suites, 1,488 assertions passed.
- Browser observer regression fails against the old deployed code and passes
  against the patch; server-identified live recovery still works.
- Automation job-detail browser regression passed.
- Shared renderer acknowledgement tests cover success, HTTP failure, timeout,
  JSON failure, malformed response, replacement/unchanged patch and quoted errors.
- Worker and backend syntax checks passed on the Pi.
- No running calibration/meter workers before deployment.
- Seven runtime files installed; backup: `/root/pgen-pattern-ownership-1DFs5j/`.
- All 607 packaged files matched SHA-256 before reboot (device configuration and
  runtime exclusions unchanged). A new shared shell helper accounts for +1 file.

The original failed result remains in history. The bounded diagnostic cleanup
left that execution stopped. No replacement full calibration has been claimed.

## Post-reboot proof

- Boot ID changed from `d5ed2b93-d876-46a9-b5d8-e1b3f340fd09` to
  `2d417a00-10a5-4e57-955f-03ba781241f7`; `/api/ping` succeeded.
- All 607 packaged files matched again after reboot. Early audit connections
  during startup were incomplete; only the complete successful audit is counted.
- The observer browser regression passed against served code, with no local
  replacement JavaScript. Its write interception prevents test pages controlling
  the TV.
- Live hardware test: during an 8-second-settle white read, an automatic Stop,
  a plain external Stop pattern and an external black patch all returned
  `pattern-owned`. The worker's own local patch request was accepted and the
  physical meter read Y=442.999102 cd/m², RGB code 940.
- The explicit full Stop API then returned `status: ok` and
  `calibration_mode: false` with an exit acknowledgement. A process audit found
  no remaining calibration or meter workers.
- Reconnected using the saved TV pairing after reboot/cleanup: `connected: true`,
  `disconnected: false`, `calibration_mode: false`.

Browser inspection limitation for the wider review: the existing cmux WKWebView
stayed in `document.readyState: loading` at the external `hcfr_chc.js` script, even
after reload. That asset returned HTTP 200 / 26,004 bytes in a direct request, and
the complete served UI loaded and passed the regression in Chrome. cmux network
inspection reports unsupported for WKWebView. No cmux visual-success claim is
included in the validation above; this observation needs separate reproduction.

These checks validate the failing boundary and interference protection, not a
new end-to-end six-job calibration. No long batch was started while the user's
separate agent performs the full branch PR review.
