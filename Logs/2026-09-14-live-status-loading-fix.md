# Live status loading fix

The missing-graphs report reproduced on an unmodified fresh browser session.
Startup launched duplicate current-status requests alongside bulk history.
Both current-status requests were aborted at their five/eight-second deadlines.
A direct request completed in 9,999ms; delivering that response to the same
page immediately enabled all five Dolby Vision graphs. Worker measurements
were intact, and there were no JavaScript exceptions.

## Changes

- GET current status and GET one-job graph data use the existing fast request
  workers, separate from bulk history, TV commands and other serialized work.
- Bulk history and all control/write endpoints remain on their existing lanes.
- Existing dead-worker recovery remains enabled. It rechecks the process under
  the manifest lock; concurrent recovery is tested to avoid duplicate checkpoints.
- The browser's live poll exclusively owns current run state. History no longer
  blocks its rendering or overwrites a newer poll result with an old response.
- Concurrent bulk refreshes share one request set. History failures remain
  visible in History without being relabelled as live-status failures.

## Tests and deployment

47 backend suites / 1,846 assertions passed. Browser tests passed for independent
live rendering during stalled history, request coalescing, history failure
isolation, editor, activity, job detail and Calibration observer.

Stopped run `20260914-151532-e69e14` while Job 1 was calibrating its 1D LUT.
Verified all workers exited, meter released, and TV acknowledged calibration
mode exit before deployment. No replacement calibration was started.

Two runtime files updated: `webui.pm` and `webui-automation.js`.
Pi backup: `/root/pgen-live-status-o1kGGB/before/`.
Read-only native page verification: `t/browser/automation_native_load.cjs`.
Unlike chart-only previews, this test does not inject current-run state or
override API responses: it exercises actual page startup and saved job graphs.

Final deployed native-page check passed: five saved Dolby Vision graphs,
no JavaScript errors, no aborted automation requests, and no live-status error.
Six current-status responses took 327–392ms. A concurrent bulk-history load
left current status responsive at 336ms (previously approximately 10 seconds).
All 608 packaged files match local SHA-256. TV reconnected with stored pairing,
calibration mode false; process audit found no remaining workers.
Final boot ID: `b194659c-fefa-4013-bddd-5e45ef12edc4`.
