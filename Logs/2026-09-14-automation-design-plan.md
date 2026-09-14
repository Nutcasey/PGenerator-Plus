# Branch UI consistency pass

## Brief and design system

Use frontend-design-cx to bring the branch's automation UI into the existing
PGenerator application, not to create a separate visual identity. Operators need
to configure precise signal-path settings and follow long, ordered calibrations.

- Palette: page #0a0a0f, panel #14141f, border #2a2a3a, text #e0e0e8,
  selection #5b7fff, warning #ff9800. Reference existing CSS variables so the
  established light-theme equivalents continue to work. Retain existing error
  and action tokens rather than adding new colours.
- Type: the application's system sans stack for headings, controls and results;
  monospace only for the scrolling diagnostic log. Body .82rem, metadata .75rem,
  section titles .95rem, job titles 1.05rem, with deliberate line spacing.
- Layout: left-aligned, ordered queue rows; configuration stays in the existing
  modal wizard. Live and history inspection share the same result treatment.

```
Automation     status
Current job / stage / progress, when relevant
Activity log (expandable)
Queue | Saved Recipes | Live Run | History
Ordered jobs          Selected job settings and results
                      (stacked beneath on a narrow screen)
```

## Review against brief before implementation

The queue numbers represent an actual execution sequence. Keep them. Repeated
eyebrows, all-caps metadata and nested statistic cards do not help follow that
sequence; avoid introducing them as decoration. Existing field labels and
navigation conventions can remain where matching the application matters.
Keep the progress/selected job as the main accent; do not add glows, gradients,
new fonts, oversized calls to action or animations. Preserve the requested
compact red Run queue action. Retain actual requested/reported settings and
failure explanations; simplify presentation, not evidence.

Scope includes queue, saved recipes, editor, readiness, log, live/history detail,
Calibration observer, and the branch's LG/pattern observer additions. Review
screenshots in both themes and at desktop/mobile widths, then obtain independent
design/state reviews. Calibration algorithms and device control flows are out
of scope.

## Implemented and checked

The branch UI now inherits the application font consistently, uses a restrained
heading scale, and gives disabled controls an explicit visual state. Wizard
descriptions have readable line lengths and spacing; setting grids shrink safely.
History actions wrap alongside long names, and saved-run detail no longer claims
to be following a live job. The Calibration card is titled "Batch calibration"
to distinguish it from the workspace heading.

Readiness failures are shown directly beneath the queue as well as in the log.
Warnings retain amber styling without turning the run into an error. Status
badges use theme-aware foregrounds on neutral surfaces. Requested TV settings
are presented as a wrapping list instead of one long joined string. Graph
statistics use consistent type and tabular numerals without decorative boxes.

Verification: all 48 Perl test files / 2,097 assertions passed. Offline browser
checks passed for editor, observer, job detail, activity, history, pattern
ownership and the new design-state tests (included in CI). Read-only appliance
previews covered queue, recipes, SDR/HDR10/Dolby Vision wizard top/settings/end,
live/history results, readiness, log, dark/light themes and 320px/390px widths.
The separate observer preview covered six run states and retained the graphs.

Both independent reviewers approved the final pass. Their feedback also led to
expandable warning counts/reasons on terminal runs, human-readable history
statuses, labelled tabs with arrow/Home/End keyboard navigation, and distinct
first-load versus stale-result errors. These checks pass in the offline suite.

Deployment backup: `/root/pgen-design-HXCGeV7N/before`. All 608 packaged runtime
files matched the workspace after installation; existing saved queues and
device configuration were preserved. No new calibration was started.

Post-reboot verification passed against served assets (without local overrides):
full design audit, six observer states, and real native page startup with five
saved graphs. The new boot ID is `25c7f1c3-1186-4337-8feb-1b30c6377e57`.
All 608 packaged files still match. The saved run is stopped, no workers remain,
and the TV is connected using its stored pairing with calibration mode false.
