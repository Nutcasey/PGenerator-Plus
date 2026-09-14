# SDR Gamma defaults

New SDR Filmmaker jobs pin TV Gamma to BT.1886 (`high2`); SDR Cinema
uses Gamma 2.2 (`medium`). Reference queue jobs use the same factory.
The prepared TV Gamma follows the calibration target until explicitly edited,
unpinned or replaced by a TV import. Saved overrides and per-mode drafts survive.
Gamma 2.4 uses `high1`, not `high2`. sRGB has no equivalent TV menu preset, so
the automatic pin is removed without changing the calibration target.
HDR10, HLG and Dolby Vision do not receive generic SDR Gamma defaults.
Existing saved jobs are not silently changed; Restore Reference Defaults is explicit.

The runner converts legacy friendly Gamma labels to LG enum values when writing
and comparing readbacks. Setup boundaries still verify gamma strictly. After
this job's verified 1D upload, known Gamma menu values are recorded as LUT-managed;
settings recovery does not rewrite the bypassed menu control. A later reset or
failed/unverified upload invalidates that ownership. Wrong modes, read errors,
missing/unknown values, unsupported reads and other setting differences are not hidden.

Sources: local G3 settings snapshots and control-surface reference; upstream
https://github.com/chros73/bscpylgtv and its SDR preset examples document raw
Gamma enum values and 1D LUT bypass of user-menu gamma controls.

Checks before deployment:
- 40 Perl suites, 1,626 assertions passed.
- Editor browser regression passed, including 15 new Gamma checks.
- Job-detail browser regression passed.
- Pi worker audit: no active calibration/meter workers.
- Initial 607-file audit differed only in the three intended runtime files.
- Staged runner passed Perl syntax checking on the Pi.

Runtime files: `usr/bin/pgen_automation_runner.pl`,
`usr/share/PGenerator/webui-automation.js`, `usr/share/PGenerator/webui-automation.html`.
Remote backup: `/root/pgen-gamma-defaults-s9USXb/`, originals retained as `*.before`.
Pre-reboot boot ID: `272bad47-db94-4c3e-a54b-d9fc344e1f22`.
No calibration was started for this deployment.

Post-reboot boot ID: `b3ac2bfa-c5c3-4f15-a0be-74b8f47fb680`.
All 607 packaged files matched SHA-256 both before and after reboot.
The API returned HTTP 200 and the post-reboot worker audit was clean.
The served Chrome UI passed `t/browser/automation_gamma_deployed.cjs`:
Filmmaker `high2`/BT.1886, Cinema `medium`/2.2, live target change to
2.4 produced `high1`, Delta E stayed 0.5, and HDR/DV had no SDR Gamma pin.
No browser errors; non-GET/HEAD requests were blocked during that UI check.
