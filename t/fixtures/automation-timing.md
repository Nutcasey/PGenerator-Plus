# Calibration timing evidence

`usr/share/PGenerator/automation-timing.json` contains seven completed jobs
from the Raspberry Pi's saved automation records, retrieved on 20 September
2026 through the read-only item-artifact API. It contains timing and workload
metadata only. The source identifier is the run ID followed by the item index.

The six-job run `20260918-181522-8a9142` covers two SDR hybrid-3 profiles, two
HDR matrix profiles and two Dolby Vision profiles, all with Dark Detail and
a 0.5 target. `20260920-103139-9b2f50`, item 0, supplies the stricter 0.2 SDR
greyscale and hybrid-9 colour profile. Recorded durations include checks,
profiling, solve/upload and calibration-mode exit as separate stages.

Each duration comes from a completed checkpoint's `duration_seconds`.
Greyscale fractions are elapsed time at each `Point finished` log event,
divided by the complete stage duration, starting at zero. Legacy log clocks
were unwrapped across midnight; the newer log uses UTC timestamps. The
unconsumed fraction after the last point reserves final commit/cleanup time.
For 3D profiles, `tail_seconds` is the complete stage duration less the
elapsed log time before `3D LUT solve pattern blank`. It includes HDR shadow
correction and tone-mapping work as well as the LUT solve/upload. Runtime
phase changes establish the corresponding start and end for future samples.

These are starting estimates for the recorded workloads, not universal
calibration durations. There are no invented defaults for unobserved signal
families or profiling methods. A different accuracy target may reuse point
weights once live measurements establish its pace, but does not inherit the
recorded total duration. Future completed greyscale passes save their own
trajectories, and newer comparable timings supersede the factory priors.
Local history is optional. Completed checkpoints save a compact `timing.json`
index; startup reads at most 100 such records, with heartbeat/stop checks
between them. Legacy full manifests are limited to 2 MiB each and 8 MiB total.
Live updates reuse a prepared timing index until the durable job context changes.

`t/automation_eta_replay.t` excludes each job from its own training data and
replays nine checkpoints across its measured trajectory. It also exercises
faster/slower runs, queued-job adaptation, initial coverage and overruns.
The browser activity/progress tests cover bound rendering and stale status;
the live-status test proves recalculation does not rewrite the full manifest.
