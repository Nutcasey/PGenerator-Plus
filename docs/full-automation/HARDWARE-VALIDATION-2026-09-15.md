# Six-job hardware validation — 15 September 2026

## Outcome

All six jobs completed without a manual stop, restart or resume. Two jobs recovered a processing-control change and retained a warning explaining the recovery.

- Run: `20260914-220250-2f9170`.
- Started: 14 September 2026, 20:02:57 UTC.
- Completed: 15 September 2026, 02:05:49 UTC.
- Elapsed: 6 hours, 2 minutes, 52 seconds.
- TV: LG OLED55G36LA, firmware 23.25.55, webOS 9.2.2.
- Final run status: `complete`; no recorded run failure or resume timestamp.

The run used the transport/chart changes through `1b2852c6`, plus the calibration-entry recovery and Dolby Vision signal-acquisition fixes included with this report.

## Saved results

Every job saved verified completion checkpoints for greyscale calibration, the volume/profile stage, final settings and calibration-session closure.

| Job | Outcome | Saved 1D measurements | Saved volume/profile result |
| --- | --- | --- | --- |
| HDR10 Filmmaker | Complete | 32 readings / 32 steps | 3D LUT complete; 5 readings / 5 steps |
| Dolby Vision Filmmaker | Complete | 32 / 32 | Native panel profile complete; 5 steps |
| Dolby Vision Cinema Home | Complete with recovered warning | 32 / 32 | Native panel profile complete; 5 steps |
| HDR10 Cinema | Complete with recovered warning | 32 / 32 | 3D LUT complete; 5 readings / 5 steps |
| SDR Filmmaker | Complete | 33 readings / 34 steps | 3D LUT complete; 63 readings / 63 steps |
| SDR Cinema | Complete | 33 / 34 | 3D LUT complete; 63 readings / 63 steps |

These counts reflect the workers' saved schemas. Dolby Vision profiles store native steps, not a top-level readings array.

All six jobs used the requested ΔE 0.5 target, Dark Detail and Apply to All Inputs. Separate pre- and post-measurement sweeps were disabled and skipped.

SDR Filmmaker used BT.1886; SDR Cinema used gamma 2.2. HDR10 and Dolby Vision retained their PQ display targets and gamma-2.2 1D calibration context.

### Recovered warnings

- Dolby Vision Cinema Home: Smooth Gradation changed from Off to Low after profile upload. A targeted write restored Off; subsequent readbacks confirmed it.
- HDR10 Cinema: Smooth Gradation changed after a calibration transition. The worker restored Off and checked the result before further measurements.

Both jobs retained verified calibration artifacts and completed their remaining stages. These warnings were not ignored failures.

Apply to All Inputs was sent successfully, but this TV cannot confirm it through the API. Its record remains `sent-unconfirmed`, not a verified readback.

## Calibration-entry investigation

An earlier run, `20260914-201248-a84798`, failed when the TV rejected Dolby Vision calibration entry with error 20, before measurements.

The exact TV-side trigger remains unconfirmed. The same request subsequently succeeded, including during a controlled Dolby Vision mapping transition.

The shared entry path now retries only that specific rejection, with a fresh picture-mode check before each retry. It permits at most three attempts.

Unknown errors, timeouts, authentication failures and incompatible modes do not receive this retry. Each successful entry requires an explicit TV acknowledgement.

The automation runner also allows eight cancellable seconds for TV signal acquisition after changing Dolby Vision mapping. This is not per-job panel warm-up.

All six calibration-entry records in the completed run succeeded on their first attempt. The run therefore validates the transition flow, not recovery from another observed rejection.

Simultaneous desktop/mobile inspection produced no observed control writes or browser errors. There is no evidence that viewing the page from a phone caused the rejection.

## Reporting changes deployed after completion

The following changes were tested separately and deployed after the six-job run. They did not affect its calibration measurements.

- Time estimates recalculate at point boundaries and every 120 seconds otherwise. Current-job and batch estimates have separate totals.
- Compatible stage timings can inform another picture mode on the same signal path and device. Different measurement workloads remain separated.
- Recent slower point timings influence the remaining estimate, reducing bright-point bias during near-black calibration.
- Unknown stages no longer hide known durations. The interface labels partial coverage and timings borrowed from similar jobs.
- A replay of the running manifest estimated 44 of 46 remaining stages. The two unmeasured Dolby Vision profile stages remained explicitly untimed.
- Accepted-refinement log messages now report the accepted refinement's ΔE, rather than an earlier best value. Calibration selection and adjustment algorithms are unchanged.
- Completed worker messages no longer repeat their title or display a reset patch counter. Errors retain the interrupted patch context.

## Verification and deployment

- `prove t/`: 52 files, 4,284 assertions passed.
- Seven isolated browser suites passed with Chromium's sandbox enabled: activity, history, refresh, editor, job details, Calibration observer and design states.
- A read-only browser audit opened both saved measurement groups for every deployed job: 36 chart images decoded across 12 views, with no browser errors.
- New tests exercise the actual runner timing loop, point-boundary resets, stage compatibility, partial estimates and the guarded calibration-entry retry.
- Changed Perl modules passed syntax checks on the Pi. JavaScript syntax and `git diff --check` passed locally.
- All 608 packaged appliance files matched local SHA-256 checksums after deployment; no missing or mismatching files remained.
- The reporting deployment preserved a backup at `/root/pgen-batch-reporting-kcyXzI/before` and restarted the PGenerator service after run completion.
- The completed run remained accessible after the service restart. No calibration workers remained; calibration-mode exit was confirmed before TV shutdown.
- The TV acknowledged standby. Because the service restart woke it through HDMI, standby was sent again and confirmed afterward.

## Limits

This run validates six-job sequencing, settings boundaries, saved measurements, uploads and cleanup on one TV. It does not certify every TV or queue combination.

Pre- and post-sweeps were disabled. This run does not validate mixed sweep combinations or provide an independent post-LUT accuracy measurement.

A requested ΔE of 0.5 does not mean every patch achieved 0.5. The standard solver retains its closest result and existing near-black allowances.

The new estimate was validated through regression tests and recorded-run replay, not another six-hour physical batch. Its predictions remain approximate, especially for untimed stages.

Controls unavailable through the TV API still require manual checks. The run cannot prove persistence of Apply to All Inputs across other inputs.
