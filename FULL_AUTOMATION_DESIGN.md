# Full automation mode

Status: agreed design, including the final clarification about preserving TV settings across resets. Implementation is in progress on `feature/full-automation`; live proof is being recorded against the owner's LG OLED55G36LA G3 (webOS 23, software release 9.2.2).

## Purpose

Add a separate Automation workspace alongside the existing guided calibration flow. Users configure complete calibration setups upfront, arrange them in a queue, and run the queue unattended after initial setup.

The workspace provides queue editing, live progress, and persistent results history. Recipes and queues can be saved and reused.

## Queue items

Each item represents one complete setup:

- Signal format, such as SDR or HDR.
- TV picture mode, such as HDR Filmmaker.
- Explicit TV settings, including applicable brightness, OLED pixel brightness, and other picture controls.
- Calibration targets and relevant options from the existing calibration flow.
- Enabled stages and measurement selections.
- Apply-to-all-inputs selection within the calibration stage.
- Optional quality checks.

Expose the relevant existing configuration choices through presets, editable defaults, and expandable details. Store those choices with the recipe instead of inheriting whatever settings happen to be active when execution starts.

For panel light, each item chooses one of two policies:

- **Target luminance:** calibration may adjust panel light to reach the target.
- **Fixed panel light:** preserve the explicitly selected setting.

The distinction determines which settings calibration may change. A fixed setting must not silently become an adjustable calibration control.

## Item execution

The user-facing flow is:

**Required TV setup → optional pre-calibration readings → optional calibration including apply to all inputs → optional post-calibration readings**

Pre-calibration readings, calibration, and post-calibration readings are independently optional. New items enable all three by default, and at least one must remain enabled.

### 1. Required TV setup

Select the item's signal format and picture mode. Apply its configured TV settings and verify that they took effect before the first enabled stage begins.

This setup also applies to measurement-only items.

### 2. Optional pre-calibration readings

Measure after applying the item's settings, while the existing calibration remains intact. Do not reset the existing calibration before these readings.

Pre- and post-calibration measurements use the same selection by default. Allow the user to configure the selections separately.

### 3. Optional calibration, including apply to all inputs

1. Perform the reset required by the calibration workflow.
2. Reapply and verify the item's configured TV settings after that reset, before calibration proceeds.
3. Run the configured calibration and retain its final readings and graphs.
4. Perform required calibration-session cleanup and verify that the item's required settings remain correct.
5. Apply to all inputs when enabled, before post-calibration readings or changing to another queue item.

Apply to all inputs is a checkbox within the calibration configuration, enabled by default. It copies the active picture mode to the same mode on the other inputs. It is not a separate top-level measurement or calibration stage, and measurement-only items do not perform this calibration-copy action.

### 4. Optional post-calibration readings

Measure the final state, after the calibration and its enabled all-input copy have finished.

Save available results as execution progresses. An interruption must not discard completed measurements or stages.

## TV settings must survive resets

**The queued item's recipe is the authority throughout execution.**

Apply and verify the settings upfront. After any reset that affects them, reapply and verify them before measurements or calibration continue. Check them again before applying to all inputs and before post-calibration readings.

For example, an HDR Filmmaker item with a fixed OLED pixel brightness must use that setting for its pre-calibration readings. If the calibration reset changes it, reinstate and verify the chosen value before calibrating.

Preserve values produced by calibration for controls explicitly allowed to adjust toward a target. Do not overwrite those values with the recipe's initial values.

If a required fixed setting changes unexpectedly, recover and repeat any work affected by the correction. Stop the queue if recovery cannot establish the required state. Changing a setting after calibration must not silently leave results describing an earlier state.

There is no separate step that restores the TV's previous viewing settings or previous picture mode. The TV remains in the current item's picture mode with the intended fixed settings and resulting calibration values.

## Queue behavior

- Run items in exactly the order the user arranges them. Do not automatically regroup them by signal format.
- Allow adding, editing, and reordering pending items while execution continues. Recheck changed items before execution.
- Keep active and completed items fixed.
- Allow overlapping writes without an additional acknowledgement. When items target the same mode, signal format, and overlapping inputs, later items replace earlier TV settings. Earlier recorded results remain available.
- Complete each item's enabled all-input action before changing to the next item's picture mode.
- After successful completion of the queue, leave the last completed item's picture mode active.

## Unattended execution and readiness

Resolve required user interaction during initial setup. Check equipment readiness and the operations needed by the queued items before starting, and verify the required state again as items execute.

Full automation is the goal. When an intended workflow cannot run unattended, investigate and fix the missing capability. Readiness checks must not become a substitute for implementing the required automation. Do not silently skip items.

Execution must belong to the Pi rather than depend on an open browser tab. Closing the browser must not interrupt the queue.

## Failure, pause, and resume

- **Unrecoverable equipment or execution failure:** stop the queue and preserve completed results.
- **Resume:** verify the required equipment and TV state, then retry from a safe stage boundary. Retain completed work wherever its validity can be established. An all-input-copy failure should not require repeating a successful calibration.
- **Pause:** finish and save the active stage, then pause before the next stage.
- **Stop:** interrupt the active work immediately, perform required cleanup, and retain completed results. Do not present an interrupted stage as completed.
- **Optional quality check misses its limits:** flag the result and continue. A quality warning is distinct from an execution failure.
- **Explicit all-input-copy error:** stop the queue.
- **All-input command returns without an error, but fresh completion cannot be confirmed:** continue and record the copy as unverified. Do not report independently verified destination settings. Investigate better confirmation without hiding the current limitation.

Safe resume must use verified checkpoints. It does not imply that every existing calibration worker can resume in the middle of its internal measurement loop.

## Results and reusable configurations

Save reusable recipes and queues. Rerunning a saved queue creates a new history entry and performs fresh equipment checks.

Keep every run until the user explicitly deletes it, including completed, partial, and failed runs. Do not replace earlier history when a queue is rerun.

For each item, preserve:

- The configuration used for that execution.
- Available pre-calibration readings and graphs.
- Calibration results, including final readings and graphs even when a separate post-calibration sweep is disabled.
- Available post-calibration readings and graphs.
- Stage completion, failures, quality warnings, and all-input verification status.

Provide a history view where the user can open each run and review every queued item's graphs. Results must remain available after leaving the live calibration screen or closing the browser.

## Existing implementation findings

These findings describe the inspected code and inform implementation work; they do not reduce the agreed product scope.

- Full AutoCal orchestration currently lives in browser code, with some browser and server persistence. It is not a general persistent queue: [webui-workspace.js](usr/share/PGenerator/webui-workspace.js).
- The existing before/after report captures Greyscale 21pt, ColorChecker, and saturation sweeps. Saved readings can regenerate report graphs. The report storage does not provide the required report-history browsing and deletion experience: [webui-app.js](usr/share/PGenerator/webui-app.js), [webui-workspace.js](usr/share/PGenerator/webui-workspace.js), and [webui.pm](usr/share/PGenerator/webui.pm).
- Existing calibration resets change picture controls and calibration baselines. The new queue must explicitly enforce the item's settings across those resets: [webui-lg.js](usr/share/PGenerator/webui-lg.js) and [webui-workspace.js](usr/share/PGenerator/webui-workspace.js).
- The all-input action uses the active picture mode. It has TV-dependent confirmation limits and cannot run while a calibration session remains held: [pgenerator-lg](usr/sbin/pgenerator-lg) and [lg.pm](usr/share/PGenerator/lg.pm).
- Some workers support limited retries, including retrying a generated LUT upload. General queue checkpoints and recovery still need implementation: [meter_lg_3d_autocal.pl](usr/bin/meter_lg_3d_autocal.pl) and [meter_lg_autocal.pl](usr/bin/meter_lg_autocal.pl).
- Existing AutoCal diagnostic retention keeps a limited number of runs. Automation history must meet the agreed retain-until-deleted policy: [PGAutoCalRun.pm](usr/share/PGenerator/PGAutoCalRun.pm).

## Implementation acceptance examples

1. An HDR Filmmaker item with fixed OLED pixel brightness applies and verifies that value before pre-readings and again after the calibration reset.
2. A calibration-only item retains its final calibration graphs, performs its enabled all-input copy, and advances without running pre- or post-calibration sweeps.
3. A measurement-only item applies its configured TV settings, measures without resetting calibration, and retains its graphs.
4. An all-input-copy failure stops the queue. After recovery, Resume retries the copy without repeating a still-valid calibration.
5. Two items targeting the same mode can run consecutively without an overwrite acknowledgement. Both result sets remain accessible.
6. Closing the browser does not stop execution. Reopening the workspace shows current progress and saved results.
7. Rerunning a saved queue preserves the previous run, including any failed or partial results.
8. A quality warning or an unverified copy is visible in history without being misreported as an execution failure or a verified success.
