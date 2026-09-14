# Expected LG calibration gamut state

Implemented and deployed 2026-09-14 after the Auto/Wide research review.

## Change

After the combined SDR/HDR calibration baseline reset and a subsequent verified
1D stage, the exact requested Auto / reported Wide result at c6 is informational:
`expected-calibration-state`. The UI labels it **Expected calibration state**,
retains the raw requested/reported values and check stage, and does not give it
an amber problem panel or add job/stage warnings. The runner logs the expected
state without claiming that the raw values matched or that a final 3D upload
has already completed. Recovery leaves that gamut control unchanged.

The latest reset and 1D checkpoints must both be done and verified, in order.
Missing, failed, unverified or superseded evidence does not qualify. The rule
does not extend to Dolby Vision, standalone 1D-only workflows, pre-calibration
setup or unknown gamut differences. Existing verified 3D-LUT ownership at later
checkpoints remains unchanged. Failed reads, unavailable controls, incorrect
picture mode, evidence-storage failures and other setting failures retain their
existing handling. Historical saved warnings/results were not rewritten.

## Verification

- Full Perl regression suite: 35 files, 1,376 assertions passed.
- Isolated job-detail browser suite passed, including expected-state display
  and an unrelated brightness mismatch remaining prominent.
- Perl syntax on the Pi, JavaScript syntax and scoped diff whitespace checks passed.
- Before deployment, only the two intended application files differed from the Pi.
- All 606 packaged files matched SHA-256 after deployment and after reboot.
  Device-specific configuration/runtime exclusions remain unchanged.
- Deployed UI loaded in Chrome with GET/HEAD-only request interception: new
  expected-state label, raw values retained, no warning/error panel, no page errors.
- Saved six-job results passed the existing read-only completion audit after reboot.
- No calibration/meter workers were running before deployment or after reboot.
- `/api/ping` returned `{"ok":1}` after startup. The first checksum attempt during
  startup lost its SSH command; the subsequent complete audit passed with no mismatches.

Boot ID changed from `89a704de-da78-46dc-8d6f-ec5da98d3faf` to
`d5ed2b93-d876-46a9-b5d8-e1b3f340fd09`.

Backup of both replaced application files:
`/root/pgen-gamut-state-iGQx5a/` (`*.before`).

No new calibration was started. Direct CEC status after reboot reported TV power
on; no TV power command was issued in this implementation turn.
