# Calibration observer presentation

The Calibration workspace now groups the automation job name, queue position,
stage and navigation in one responsive overview. It uses existing application
fonts, theme colours and button styles. Configured settings and measurement
statistics have their own consistent, responsive containers.

Stopped, paused, interrupted, failed and completed runs have state-specific copy.
Stopped results are labelled potentially partial rather than "Between stages".
Navigation to Automation follows and focuses the active/final job, not a run
control. Manual controls remain inert until automation releases ownership.

Browser checks also found that `complete-with-warnings` was missing from saved
calibration graph selection; it now retains the final measurements like other
terminal states. No calibration algorithm changes were made for this UI work.

## Verification

- Two independent agents reviewed UI consistency and observer state/navigation.
- Observer, job-detail and queue-editor browser regression checks passed.
- Read-only appliance presentation checks passed with local assets for running,
  paused, stopped, failed, complete and complete-with-warnings states, dark/light
  themes, and narrow 390px/320px layouts.
- The Perl suite passed: 48 files, 2,097 assertions.
- All 608 packaged appliance files matched after deployment. Device-specific
  configuration and runtime state were preserved.

This deployment also includes the pending reference-job defaults: Dark Detail
and Apply to All Inputs enabled for all six reference jobs. Pre/post sweeps stay
off and the Delta E target stays 0.5. Existing saved queues are not overwritten.

The two replaced UI files were backed up on the Pi under
`/root/pgen-observer-ui-GLjLMI/before`.
