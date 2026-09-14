# HDR Cinema Home startup rejection

Run `20260913-225541-73ee6d` completed four jobs, then interrupted on
HDR10 Cinema Home at reset-and-reapply-verified, before CAL_START succeeded.
Completed job artifacts remain intact; SDR Filmmaker is still queued.

Non-destructive entry/exit probes after cleanup:

- HDR Cinema Home (`hdr_cinema_bright`) rejected CAL_START with LG error 20.
- HDR Cinema (`hdr_cinema`) accepted CAL_START without a TV reboot.
- CAL_END then succeeded; `/api/lg/status` confirmed calibration_mode=false.
- No reset, LUT upload or calibration measurement was performed by these probes.

This contradicts the previous definite stuck-driver diagnosis. It does not prove
that every LG error 20 means unsupported mode. Portrait's LG 2023 AutoCal guide
lists HDR Cinema, Game, Technicolor and Filmmaker, not HDR Cinema Home:
https://www.portrait.com/resource-center/lg-2023-oled-and-qned-autocal-guide/
Each picture mode is a separate calibration memory slot.

Fix: reject HDR Home AutoCal during static batch readiness and before the HDR
reset workflow sends CAL_START. Ordinary settings and readings remain allowed;
Dolby Vision Cinema Home remains supported. Generic HDR error 20 now reports
rejected entry, not a proven driver lock or mandatory cold restart.

The existing reference template and saved/current jobs are deliberately not
remapped to HDR Cinema. The user has been asked to approve that different memory
slot. This leaves the reference template requiring an explicit supported-mode
choice before its next calibration run. Do not call the six-mode goal complete.

Before probes, the Pi run was backed up at
`/root/pgen-hdr-home-start-4nmbjs/interrupted-run`.

## Verification and deployment

- 1,010 assertions across 25 test files passed locally, including real workflow
  entry tests proving that the unsupported mode sends no calibration commands.
- Isolated job-detail browser checks passed.
- Deployed both guard files plus the three pending status-display fixes.
- All 605 packaged device files matched local SHA-256 checksums afterward.
- Deployment backup: `/root/pgen-hdr-mode-guard-MSqOk0/original`.
- Restarted the PGenerator application service, not the entire Pi. The batch
  remains interrupted pending the user's picture-mode choice; no Resume sent.

## Approved continuation, 03:37 UTC

The user approved HDR Cinema. Reference v4 now creates HDR Cinema instead of
HDR Cinema Home; existing saved/custom v3 items are not silently rewritten.
The interrupted fifth item was explicitly replaced using the bounded recovery
script `2026-09-14-approved-hdr-cinema-repair.pl`. Old Home checks/artifacts are
archived under the run's `replaced-items/hdr-home-before-approved-change` and
the old manifest is saved beside it. The original queue snapshot and items
0–3 and 5 were verified unchanged after replacement.

The first Resume stopped during picture-mode verification because the recovery
script had created its replacement item directory as root. This was a recovery
mistake, not a TV mode rejection. Ownership of the explicit new directory and
item.json was restored to pgenerator, and the script now preserves original
ownership. No calibration/reset had started. Cleanup completed before retry.
Second Resume requested after correction. Both remaining items keep Delta E 0.5
and no optional pre/post sweeps. All 605 packaged files match local checksums.
