# Dolby Vision Cinema Home settings at profile upload

Run `20260913-225541-73ee6d`, item 2 (job 3), interrupted at 22:44 UTC.
The completed 1D upload and failed boundary evidence are backed up at
`/root/pgen-dv-upload-settings-NxoOT3/interrupted-run` on the Pi.

## Observed failure

- c1/c4/c5: 16/16 settings matched before calibration.
- 1D completed and uploaded; c6 matched 16/16 at 22:42:39 UTC.
- Five-patch DV profile measured, uploaded successfully, CAL_END acknowledged.
- c7 and confirmation reported Smooth Gradation Low, requested Off. Other 15
  values matched. One targeted repair and two readbacks confirmed Off.
- Runner paused without automatic recalibration; cleanup left the TV out of
  calibration mode. A fresh later read still reported Smooth Gradation Off.

## Code findings

The 414-line profile worker only measures black, white, red, green and blue in
the batch path; `upload=false` is explicit. The runner separately uploads its
measurements. The helper `lg_dv_profile_upload_workflow` always issues CAL_END
after upload, even if keep-calibration-mode was requested. Previously the runner
hard-coded `calibration_mode_active=true` instead of checking the actual state.
The archived upload proves CAL_START was skipped on that basis.

The old c7 boundary had no readback between profile measurements and upload, so
it could not distinguish a change during measurement from an upload/exit effect.
The old fresh-before-exit exception covered only c8, after the helper had already
exited. Repeating the same profile without addressing that gap would recur.

## Change

- Fresh full settings read immediately after profile measurements, before upload.
- Actual calibration-state query passed to upload instead of hard-coded true.
- Log the upload and observed mode. Archive pre-upload evidence with the stage.
- Pass that fresh proof directly to c7, not from a historical checkpoint.
- Only DV upload, successful verified volume commit, confirmed calibration off,
  processing-only controls, matched pre-upload values, accepted targeted repair,
  and two stable full readbacks permit retaining the measured profile.
- Warn and record exactly which processing controls were restored. Other drift,
  missing/stale proof, failed reads/uploads and unstable repair retain the pause.
- Resume repeats only the short profile, preserving the validated 1D upload.

## Verification

Local full regression suite: 977 assertions passed before adding three additional
error-code checks; all 107 boundary assertions then passed locally and on the Pi.
Job-detail browser tests and JavaScript syntax passed. Packaged-file audit matched
605 files before the final small error-code clarification, also deployed.
Original deployed files are backed up under the same Pi backup directory.
Application service restarted and the same batch resumed; no queue edits.

## Live result

- 22:51:18 UTC: resumed c6 read 16/16; saved 1D retained, only profile repeated.
- 22:52:50 UTC: new post-measurement/pre-upload check matched 16/16.
- 22:52:51 UTC: actual calibration state Off passed to upload.
- 22:52:56 and 22:53:00 UTC: after upload, only Smooth Gradation changed to Low.
- 22:53:04 and 22:53:07 UTC: targeted restoration to Off, 16/16 matched twice.
- 22:53:07 UTC: upload-only restoration recorded with explanation; results retained.
- 22:53:14 UTC: final c8 read 16/16 after calibration exit.
- 22:53:16 UTC: Cinema Home complete-with-warnings, no failure. Warning identifies
  the restoration, not a failed calibration. HDR10 Filmmaker began next.
- Latest 605-file deployment checksum audit matched every packaged file.

This live sequence confirms the processing change occurs in the profile-upload
transaction after the measurements, not in the five-patch measurement worker.
