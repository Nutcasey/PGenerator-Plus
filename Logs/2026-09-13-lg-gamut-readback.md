# LG gamut readback and pre-calibration feedback

Run: `20260913-225541-73ee6d`, job 1, SDR Cinema. LG OLED55G36LA,
firmware 23.25.55 / webOS 9.2.2. Original interrupted run preserved on the Pi
at `/root/pgen-gamut-warning-u6hgag/interrupted-run` before further writes.

## Evidence

- Initial setup, after reset, and immediately before setup-white measurements:
  Cinema selected first; all 17 requested settings including picture mode matched.
- Completed 1D upload: worker state `complete`, `final_1d_lut_uploaded=true`,
  `final_1d_lut_upload_verified=true`.
- c6 and fresh confirmation: Auto requested, Wide reported; other 16 values matched.
- Existing recovery wrote Auto, then two reads returned Auto. It paused because
  the effect of the change on measurements was unknown. No automatic repeat.
- A subsequent fresh read after cleanup returned Cinema / Wide again.
- Controlled diagnostic while interrupted: write only the requested Auto value
  through the run-owned API. Write response reported Cinema / Auto; independent
  immediate read also reported Cinema / Auto. No LUT reset/upload or measurement.
- An initial unowned diagnostic write was rejected by the automation guard and
  did not modify the TV. The run-owned request was used only after confirming
  the exact run remained interrupted.

This does NOT establish that Auto and Wide are API aliases. The values change
with calibration/reset/exit state. No colorimetric equivalence is claimed.

## Primary-source research

- [LG webOS 20 picture controls](https://kr.eguide.lgappstv.com/manual/w20/atsc/Contents/settings/picture/advancedcontrol_k_u_b/enga/w50__settings__picture__advancedcontrol_k_u_b__enga.html): Auto follows the signal; Extended and Wide expand color. These are distinct controls.
- [LG webOS 24 color controls](https://kr.eguide.lgappstv.com/manual/w24_mr2/global/Contents/settings/picture/color_k_u_b_e_c_a_t_j/enga/w24__settings__picture__color_k_u_b_e_c_a_t_j__enga.html): Auto Detect follows the input; available controls vary with signal, mode and model.
- [Light Illusion LG integration](https://lightillusion.com/lg_manual.html): Unity 1D/3D uploads can bypass gamut, gamma and white-balance menus. Which controls are disabled depends on model and LUT path. A 1D-only upload need not disable internal gamut management.
- [Portrait LG calibration guide](https://www.portrait.com/resource-center/calibrating-lg-tvs-with-calman/): separates 1D greyscale and 3D color calibration, and exits calibration mode before final readings.

Research used one source-discovery/extraction agent and local device/code checks.
The skill's Haiku-specific execution was unavailable; the inherited agent model
was used instead. A repeated main-agent web fetch of Light Illusion encountered
an anti-bot response; the earlier fetch and independent research agent obtained
the manual. No source establishes universal Auto/Wide equivalence.

## Chosen behavior

Per the user's explicit preference, exact Auto requested / Wide reported is a
non-blocking warning, including before calibration. It is NOT a verified match
or an assertion of LUT ownership. Raw requested/observed values, stage and reason
remain in job evidence; the log and detail panel display the warning.

This exception requires a successful, supported read and confirmed picture mode.
Failed writes, failed/missing reads, other gamut pairs, mode mismatches and other
setting mismatches retain their errors. Existing verified 3D-LUT ownership is
kept separate. Warnings do not initiate repair writes or recalibration.

Every picture-mode selection now has its own fresh readback before applying
queued settings. A full settings read immediately follows those writes, before
measurements. Unsupported mode readback stays explicitly unverified.

A legacy c6 pause may retain its completed 1D upload only if saved c6 AND c6-confirm
records prove the sole mismatch was Auto/Wide, requested values still match the
job, any repair wrote only gamut successfully, and the completed upload artifact
still verifies. Resume reruns the live settings gate before starting profiling.
All other recovery plans retain their prior conservative behavior.

## Verification and deployment

- Local: 22 Perl test files / 946 assertions passed. Browser job details and
  activity/drag-drop passed; Stop UI contract passed. JavaScript syntax and
  `git diff --check` passed.
- Pi: three focused test files / 238 assertions passed. SHA-256 audit matched
  all 605 packaged files. Device configuration and runtime state excluded.
- Deployed runner and automation UI; original files retained in the same backup.
  Restarted the PGenerator application service (not the Pi).
- Resume of the SAME six-job run accepted at approximately 21:30 UTC.
- 21:31:19 UTC: saved sole-gamut pause reclassified; completed 1D retained.
- 21:31:22 UTC: fresh c6 read matched 17/17 requested settings.
- 21:31:25 UTC: 3D LUT worker started. No repeat of reset, setup-white or 1D.
- Deployed browser warning renderer tested in headless Chrome without JavaScript
  errors. cmux WebView intermittently loaded only part of the page; this browser
  limitation was not treated as evidence of an appliance failure.
- 21:40:39 UTC: SDR Cinema 3D LUT exported, uploaded and verified.
- c7/c8: 16/17 raw settings matched; gamut explicitly recorded as controlled by
  the verified 3D LUT. Calibration exit completed, no extra sweeps ran.
- 21:40:50 UTC: SDR Cinema complete. Job 2, Dolby Vision Filmmaker, began.
- 21:41:35 UTC: job 2 picture mode independently confirmed before the 15 queued
  settings were applied at 21:41:52 UTC. This exercises the new ordering on DV.
