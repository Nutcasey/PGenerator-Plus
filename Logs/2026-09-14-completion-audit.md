# Six-mode batch completion audit

Run: `20260913-225541-73ee6d`. Completed 2026-09-14 at 06:02 UTC.
Final deployment, reboot, result-persistence and standby checks passed by 06:10 UTC.

The batch completed after the documented debugging fixes and bounded resumes;
this is not a claim of an uninterrupted fresh batch. Earlier valid results were
retained, and affected measurements were repeated where their settings were uncertain.

## Final evidence

| Job | Saved 1D readings | Saved profile | Final controls checked |
| --- | ---: | --- | ---: |
| SDR Cinema | 25 | 63 readings; verified 3D export/upload | 17 |
| Dolby Vision Filmmaker | 21 | Black/white/RGB measurements; accepted profile upload | 16 |
| Dolby Vision Cinema Home | 21 | Black/white/RGB measurements; accepted profile upload | 16 |
| HDR10 Filmmaker | 21 | 5 matrix readings; verified 3D export/upload | 18 |
| HDR10 Cinema | 21 | 5 matrix readings; verified 3D export/upload | 18 |
| SDR Filmmaker | 25 | 63 readings; verified 3D export/upload | 17 |

`2026-09-14-six-mode-result-audit.pl` passed before and after reboot. It checks
all six mode identities, completed stage checkpoints, 0.5 targets, skipped pre/post
sweeps, measured results, uploaded profiles/LUTs, nonempty exported files, and
final requested versus reported settings. Dolby Vision checks use the helper's
documented actual TV selectors. Gamut exceptions must be explicitly LUT-managed;
they are not counted as matching Auto. No run/item failure remains.

`2026-09-14-worker-exit-audit.pl` confirmed no automation, calibration, series,
meter-session or spotread workers before and after reboot. Final session cleanup
reported `ok`; the TV acknowledged calibration exit and status reported mode off.
The run remains complete with no execution owner after reboot.

All 606 packaged files matched SHA-256 after the final deployment and reboot.
Device-specific configuration and runtime files were deliberately excluded.
Kernel boot ID changed from `709da536-cbbb-4df5-992e-e4339fc6aacb` to
`89a704de-da78-46dc-8d6f-ec5da98d3faf`, proving an actual Pi reboot.

The deployed Chrome audit passed after reboot without local JS injection:
correct six-mode v4 preset, 0.5 defaults, no pre/post sweeps, saved graphs,
click-to-pin details, narrow-screen stacking, inactive completed-run status,
latest-log scrolling after reveal and preserved manual scroll-back. No JS errors.

TV power-off was accepted through CEC. A separate direct, uncached
`/usr/sbin/pgenerator-cec status` query then reported **standby**.

Remaining warnings are intentional: Auto requested/Wide reported, and documented
processing-setting restorations. Unsupported controls such as TruMotion and
some TV protections retain explicit manual-check notices. Calibration targets
are 0.5; this audit does not claim every measured patch achieved that target.

The completed run is additionally backed up at
`/root/pgen-processing-guard-Ykac0V/completed-run` on the Pi.

Approved mode change: HDR10 Cinema replaces unsupported HDR10 Cinema Home.
The user subsequently authorized comparable necessary changes without another
approval round. Do not reinterpret this as permission to erase completed results.

## Earlier verification and investigation

- Jobs 1–4: SDR Cinema, DV Filmmaker, DV Cinema Home, HDR10 Filmmaker completed.
- Saved greyscale measurement counts: 25, 21, 21, 21 respectively.
- Saved SDR 3D profile: 63 readings; HDR matrix profile: 5 readings.
- Both DV profiles contain completed black/white/RGB measurements and measured
  white luminance (not an invented baseline or post sweep).
- All four jobs have done setup, reset/reapply, panel-light, 1D, volume, and
  session-close checkpoints. The sole unverifiable settings checkpoint is HDR
  Filmmaker c6: Auto requested, Wide reported, the other 17 values matched.
- DV Home restored Smooth Gradation to Off after profile upload, retained its
  calibration, and passed subsequent full settings readbacks.
- Every job uses Delta E 0.5; optional pre/post readings and apply-all are off.
- New HDR Cinema retry passed c5 with all 18 values matching before measurement.
- Chrome live-job check showed the correct HDR Cinema target/settings and five
  graph images from live data, with no JavaScript errors.
- Reference v4 tests pass. After the processing-guard deployment and application
  restart, all 606 packaged files match SHA-256 on the Pi; served HTML contains v4.

## HDR Cinema transition repair

The fifth job paused at c7: requested Smooth Gradation Off, observed Low.
Its c6 evidence verified Off and every other requested control except the accepted
Auto/Wide gamut warning. The old recovery planner treated that single gamut
warning as invalidating the otherwise verified 1D stage. The planner now retains
1D for a processing-only later mismatch when this exact evidence is present.

A live CAL_START/CAL_END-only probe (no LUT write) reproduced Off → Low at
CAL_END. The deployed processing guard then restored Off, read all six processing
controls plus picture mode twice, and verified calibration remained off. Saved
probe output contained 22 checks and one explicit restoration warning.

The 3D worker now checks requested processing controls before measurements after
calibration transitions and after final smoothing. Missing readback, wrong mode,
failed writes or unstable restoration block measurement. Checks retain their
timestamps in job evidence. Standalone calibration is unchanged.

Profile-only resume now explicitly stages unity 3D and the exact saved 3072-value
1D curve into a held session, then applies/verifies requested settings. It cannot
substitute identity for missing saved data or claim success after a failed restore.

Regression: 1,120 assertions across 26 suites passed, plus three worker-load
assertions. Local/Pi Perl syntax and JavaScript syntax passed. Deployment backup
and complete original interrupted run: `/root/pgen-processing-guard-Ykac0V/`.
Only the fifth item's recovery plan was changed to volume-only; prior artifacts
remain archived. The completed first four jobs were not reset.

Resume live proof (05:10 UTC): baseline restoration and fresh c6 each matched
18/18 values; the matrix profile started without another 1D measurement stage.
During actual shadow probing, the worker repeatedly caught CAL_END resetting
Smooth Gradation and restored Off before further measurements.

05:28 UTC: HDR Cinema completed, c7/c8 passed (17 matching controls plus the
verified-LUT-managed gamut value). The batch automatically advanced to SDR
Filmmaker, confirmed its signal and picture mode before applying settings. The
saved HDR Cinema 1D result still exactly matches the archived pre-retry file:
SHA-256 `f933810b84fc06f68a6b87bb927078b785f17af12caeac8e7ff55854a99edcf7`.

The deployed read-only Chrome audit verified all six v4 modes, 0.5 targets,
disabled optional pre/post sweeps, five live graph images, completed-job graphs
and 172 saved setting checks for job 1, pinned selection, and narrow-screen
stacking. No JavaScript errors. Full Perl test suite: 1,225 assertions, 35 files.

## Deployed UI-only fix

The live screenshot exposed an initially hidden workspace retaining scrollTop 0
while saying Following latest. A failing isolated reproduction confirmed that an
unchanged log signature skipped scroll restoration on reveal. Local JS now
follows on reveal and ignores hidden scroll events; manual scroll-back remains
respected. Activity/drag/drop and job-detail browser suites pass. A read-only
Chrome preview against actual run data also passed with only these local log
functions injected. Deployed only after the batch completed, then verified again
against the served code after the Pi reboot. Final checksum audit includes it.

## Browser limitation

The cmux WKWebView tab repeatedly stalled while parsing the external
`/assets/hcfr_chc.js` script. Direct asset requests returned HTTP 200 and Chrome
loaded successfully. No cause established; do not claim the cmux view passed.
