# PR14 startup, cleanup and whole-queue safety contracts

These changes are based on PR head `620af0b43fb5a5552b2e3c9cc6a23b615c673674`.
They do not change calibration algorithms or claim new physical TV validation.

## Startup

The daemon and child use a unique, expiring attempt record. The child loads its
modules, validates the manifest and acquires the singleton runner lock before
announcing readiness. The daemon persists the matching manifest, execution claim,
PID and initial heartbeat before publishing acceptance. The child performs no
device operations or device cleanup without that acceptance. A failed or late
attempt is fenced; a stale PID or an unrelated process is not an acknowledgement.
The daemon and tests use the same launcher, not a runtime function replacement.

## Cleanup

Unconfirmed TV/worker cleanup or final meter release retains execution ownership
in a recoverable interrupted state. Resume, Clear and Delete cannot bypass it.
Each explicit Retry cleanup may launch a new bounded cleanup attempt. Recovery
cannot take ownership from a different batch. Successful cleanup preserves each
job's results; it does not silently resume calibration. Terminal state is saved
before ownership is released. Flush/sync failures are propagated by the shared
atomic writer rather than being published as successful journal writes.

## Whole-queue checks

Check Readiness starts an owned, persistent, check-only run after explicit consent
to temporary signal and picture-mode switching. Run queue and Resume perform fresh
whole-pending-queue checks before calibration. Every pending job is checked in its
actual signal/picture context. Configuration, mode restoration and context evidence
are journalled before mutation. Stop and failed checks restore those contexts;
failed restoration retains ownership for Retry cleanup. A neutral grey pattern,
not the user's previous arbitrary image/video pattern, is left after restoration.

No preflight resets calibration, uploads LUTs, enters calibration mode or takes a
meter measurement. It uses the existing confirmed calibration-exit check to
establish a normal baseline. Control capabilities, value contracts, input,
platform and manual requirements are checked. This is not a promise that a TV
will accept every later command or that a network/meter cannot subsequently fail.

The resolved plan freezes request intent, device identity, input and compatibility
signature. Job-start checks remain mandatory. Editing pending jobs invalidates the
plan, and revision/intent checks under the claim lock prevent an edit-vs-start race.
Completed jobs are not re-calibrated when checking the remaining queue.

### Deliberate compatibility limit

Automatic reversible preflight requires an independently readable original picture
mode. A virtual/echoed requested selector is not restoration evidence. A TV which
cannot provide that evidence is blocked **before** modes are changed rather than
claiming that it can be restored. This includes affected legacy/C1 configurations;
use the guided workflow until native current-mode observation is available. Known
manual requirements for other controls remain explicit warnings, not verified
settings. Do not remove this guard merely to turn an unsupported device green.

## Automated verification

- `t/automation_launch_verification.t`: real subprocesses, stale/foreign PIDs,
  singleton contention, delayed/cancelled/superseded attempts and persistence faults.
- `t/automation_cleanup_journal.t`: interrupted cleanup, initial/result journal
  write failures and stale successful cleanup evidence across process recovery.
- `t/automation_cleanup_ownership.t`: actual store/finish/control paths, failed
  CAL_END/meter release, retries, legacy terminal recovery and competing ownership.
- `t/automation_whole_queue_preflight.t`: real runner orchestration and transport
  with simulated hardware responses, late-job incompatibility, check-only behaviour,
  cancellation, restoration failure/retry, stale plans and edit-vs-claim races.
- `t/browser/automation_review_fixes.cjs`: consent, whole-queue request, late blockers
  and Retry cleanup/disabled Resume presentation alongside the existing UI checks.

Run the complete Perl suite, syntax checks and all ten configured browser suites,
then repeat on the same source. Hardware-free tests are not C1/G3 certification.

## Physical acceptance still required

On the exact candidate build, complete an SDR/HDR10/Dolby Vision queue, demonstrate
that a deliberately incompatible late job blocks calibration before job one, and
check original output/mode restoration after success, rejection and Stop. Disconnect
the TV during restoration, verify that Retry cleanup retains ownership, reconnect
and recover. Exercise delayed startup and a process restart without allowing late
calibration or loss of pending recovery evidence. Confirm legacy unreadable-mode
sets show an actionable block rather than a fabricated successful preflight.
