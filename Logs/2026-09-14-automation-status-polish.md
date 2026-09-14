# Status display follow-up (prepared during the live batch)

These changes were held while batch `20260913-225541-73ee6d` was running.
They were deployed when the batch interrupted at unsupported HDR Cinema Home,
together with the mode guard. No active calibration was restarted for these fixes.

- Runner STDERR now encodes decoded JSON status text as UTF-8. Previously a
  superscript 3 (code point 179) was emitted as a raw Latin-1 byte, appearing as
  a replacement character in the UTF-8 activity reader. Regression tests cover
  superscript 3, Delta, and ASCII; the existing reader tests cover decoding once.
- Internal `*-unverified` warning strings are rendered with a human stage label
  and a pointer to recorded checks, including the history summary.
- HDR shadow-worker progress previously printed a hard-coded worst value of
  1e9 on pass 1 and zero on later passes BEFORE measuring the anchors. It now
  describes the operation and pass number, without inventing a measured result.
  No calibration arithmetic, iteration count or acceptance rule changed.

Deployed files:

- `usr/bin/pgen_automation_runner.pl`
- `usr/bin/meter_lg_3d_autocal.pl`
- `usr/share/PGenerator/webui-automation.js`

Local UTF-8/activity tests, browser job-detail tests and Perl/JS syntax checks pass.
