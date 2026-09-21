# Focused SDR shadow experiment

`sdr_patch_test.py` is a host-side hardware experiment for a Pi 4, an LG TV,
and an i1Display Pro Plus. It requires Python 3.12+, Perl, SSH key access, and
the production Perl modules in this checkout. It is not installed on the Pi.

The experiment targets the SDR26 2.3% patch: limited 10-bit code 84, native
1D table row 21. It reloads a completed, upload-verified 3072-value greyscale
snapshot from the same display, input, picture mode and signal configuration.
The snapshot must include `tv_input` from its source run. The caller must
supply that snapshot; do not reuse a curve from another TV.

Only rows 20–25 of each channel can change. The 2% and 2.7% anchor rows remain
fixed, and every other table entry is compared with the snapshot before an
upload. Changes taper toward those fixed boundaries and remain monotone.

The target and Delta E ITP calculations come directly from the calibration
worker. There is no relaxed near-black threshold. Each upload ends calibration
mode before measurement, so optimization and verification use the committed
picture. Three physical XYZ readings form each measurement average. Passing
requires two independent final averages below the requested threshold, plus
neighbour checks at codes 82, 88 and 92. The result records individual readings
as well as averages; it does not claim every single reading met the threshold.

The harness checks that the measured peak white remains within 5% of the saved
reference and then uses the fresh reference for its fixed targets. It preserves
the installed 3D LUT. It does not reset the picture mode or switch signals.

## Run

Wait for any automation, calibration and measurement to finish, including
cleanup. Refresh the archived greyscale snapshot for the run being tested.
Then run, replacing the paths and host as appropriate:

```sh
python3.12 t/hardware/sdr_patch_test.py \
  --host 192.168.50.110 \
  --snapshot /path/to/greyscale-evidence.json \
  --output /path/to/test-results \
  --renderer-sha 877d0ce3d9cdffcebf55e7d53d43024f3fda6eee23cf43251aa30a8191fe1ed5 \
  --target 0.2 --iterations 12 --minutes 25
```

It holds the automation-start lock and a diagnostic meter lock. Results,
curves and UTC events are saved under a new run directory. TPC/GSR disable and
restore requests are recorded as accepted but unverified, matching the TV's
API capabilities. Normal completion releases the meter and confirms calibration
exit. Stop or failure keeps the current signal, picture mode and installed
curve; it does not restore old picture settings. Cleanup failure retains
ownership for recovery. Do not manually remove a diagnostic lock until the
meter is stopped, calibration exit is confirmed and protection restoration has
been handled.

An existing manual meter session also blocks startup, even between readings.
An unacknowledged lock acquisition releases itself within 30 seconds; once
claimed, a lost controller retains ownership for cleanup recovery.

This is a bounded diagnostic, not a full calibration pass. A non-passing result
can reflect measurement variation, a remaining solver issue or an exhausted
budget. `result.json` contains the actual measured outcome; an interrupted
experiment records `failure.json` and its cleanup outcome instead.

## Offline checks

```sh
python3.12 -m unittest discover -s t/hardware -p test_sdr_patch_test.py
```

These exercise curve preservation, monotonicity, production math against the
archived 2.3% measurement, and ownership cleanup. They do not contact hardware.
