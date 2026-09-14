# New-job reference defaults deployment

Changed runtime files: `webui-automation.js`, `webui-automation.html`.
The pre-deployment audit found only those two files different from the Pi.

New jobs/recipes reuse the reference settings factory. Signal and picture-mode
changes have separate editable drafts. TV import is explicit, preserves missing
values and rejects wrong-mode or late readbacks. Existing saved jobs are not
silently filled or changed. Dynamic Color defaults to Off, matching the reference.

The local editor browser regression and JavaScript syntax check passed immediately
before installation. All 607 packaged files matched SHA-256 after installation.
Device-specific configuration and runtime exclusions are unchanged.

Backup: `/root/pgen-job-defaults-cHCrRZ/` (`*.before`). No active calibration or
meter workers were present before deployment. The last automation run was stopped;
no new calibration was started by this deployment.

Reboot requested after the successful checksum audit. Previous boot ID:
`2d417a00-10a5-4e57-955f-03ba781241f7`.

Post-reboot boot ID: `272bad47-db94-4c3e-a54b-d9fc344e1f22`.
`/api/ping` succeeded; no calibration or meter workers were running.
All 607 packaged files matched again after reboot.

The actual served UI passed Chrome checks for new SDR/HDR10/DV defaults,
SDR panel brightness 95, Delta E 0.5, and both override/reset buttons. Dolby
Vision had no generic gamut or HDR tone-mapping pins. No JavaScript errors
occurred; all browser writes were intercepted, so this test did not alter
the TV or create a calibration job.
