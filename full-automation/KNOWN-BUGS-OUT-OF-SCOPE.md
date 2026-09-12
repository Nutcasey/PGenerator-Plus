> OUT OF SCOPE for FULL_AUTOMATION_GOAL.md. Decision of 12 September 2026: these confirmed defects are being fixed elsewhere and must not be fixed, worked around with invasive changes, or re-litigated inside the automation goal. They are listed so the implementer knows which existing behaviours are unreliable and can record, rather than mask, their effects. Source: the untracked Bugs/ directory (never commit it).

# Bugs that bear on the unattended calibration queue

Source: `Bugs/HIGH.md`, `Bugs/MEDIUM.md`, `Bugs/LOW.md` (194 confirmed entries, revalidated 12 September 2026 against commit `42a6f3e8`).
Measured against: `FULL_AUTOMATION_DESIGN.md` at the repo root.

Line citations are the line where the entry's `### FAB-nnn` heading starts in the named file.
All file paths in the "Files" column are relative to the repo root.

---

## (a) Must fix before automation can be trusted

These either report success for work that failed, or corrupt the state the next stage builds on. With nobody watching, each one produces a run that looks clean and is not.

| ID | Bug | Files cited | Why it matters to unattended automation | Sev |
|---|---|---|---|---|
| FAB-195 `HIGH.md:64` | Measurement workers continue after the local renderer rejects the requested patch | `usr/bin/meter_series.sh`, `usr/bin/meter_session.sh`, `usr/share/PGenerator/webui.pm` | Pre- and post-calibration sweeps measure the previous patch or idle output under the new patch label; no operator is present to notice a frozen screen. | High |
| FAB-003 `HIGH.md:93` | Failed final DPG commit is marked uploaded and verified | `usr/bin/meter_lg_autocal.pl`, `usr/share/PGenerator/webui.pm` | The queue advances to apply-to-all and post-readings believing a calibration landed that did not. Status recovery then promotes the stopped worker to complete. | High |
| FAB-055 `HIGH.md:150` | Saved 1D calibration restore ignores CAL_START/CAL_END failures and splits the persistent commit across three sockets | `usr/share/PGenerator/lg.pm`, `usr/sbin/pgenerator-lg`, `usr/bin/meter_lg_autocal.pl` | Any resume path that reuploads a stored curve returns ok without persisting it on the panel. The file's own source documents that split sockets do not persist. | High |
| FAB-025 `HIGH.md:181` | Concurrent configuration saves lose each other's changes; the shared `.tmp` inode is truncated after rename | `usr/bin/PGenerator_cmd.pl`, `usr/share/PGenerator/command.pm` | The queue writes config while other lanes do too. Recipe settings vanish silently, which the design explicitly forbids. Reproduced: lost writes in 2 of 5 trials, unrelated lines lost in 5 of 5. | High |
| FAB-024 `HIGH.md:692` | Generating a multi-series report during measurement can overwrite another series cache | `usr/share/PGenerator/webui-app.js`, `usr/share/PGenerator/webui-workspace.js` | Per-item before/after reports are generated back to back while the next item measures. That is exactly the trigger condition. | High |
| FAB-014 `HIGH.md:823` | Picture-mode change and a pattern request can restart the renderer simultaneously; neither path holds a shared lifecycle lock | `usr/share/PGenerator/lg.pm`, `usr/share/PGenerator/webui.pm` | Every queue item boundary changes picture mode. The design requires that transition to be safe and unattended. | High |
| FAB-013 `HIGH.md:798` | Renderer cleanup deletes its own restart lock, letting a second worker create a new inode and take an independent lock | `usr/share/PGenerator/webui.pm` | Same lifecycle cluster as FAB-014. Two queue stages can restart the renderer underneath each other. | High |
| FAB-039 `MEDIUM.md:307` | Worker atomic file writers ignore print/close failure and treat a successful rename as success | `usr/bin/meter_lg_autocal.pl`, `usr/bin/meter_lg_3d_autocal.pl` | Checkpoints and LUT exports are replaced by truncated data while reporting success. Resume then trusts them. | Medium |
| FAB-050 `MEDIUM.md:579` | Exception cleanup records `calibration_mode=false` without checking the CAL_END response | `usr/bin/meter_lg_autocal.pl` | A still-held TV session disappears from worker status. Apply-to-all cannot run against a held session, and the queue would not know. | Medium |
| FAB-063 `MEDIUM.md:884` | Successful HDR DPG readback masks failed calibration-session cleanup | `usr/sbin/pgenerator-lg`, `usr/share/PGenerator/lg.pm` | The same held-session failure, reached through readback. The read endpoint never calls the uncertain-session recorder used by writes. | Medium |
| FAB-062 `MEDIUM.md:857` | SDR reset keeps issuing outside-session identity writes after an unconfirmed CAL_END and returns a generic error | `usr/sbin/pgenerator-lg`, `usr/share/PGenerator/lg.pm` | The reset the design mandates at stage 3.1 loses the one dedicated error the daemon persists for recovery. | Medium |
| FAB-057 `MEDIUM.md:732` | Picture reset passes raw webOS mode names into CAL_START and uses SDR UI_DATA defaults in every mode; its pre-encoded payload is discarded by the request builder | `usr/sbin/pgenerator-lg` | This is the reset that changes picture controls. It is malformed for HDR and Dolby Vision items, which the design queues routinely. | Medium |
| FAB-058 `MEDIUM.md:759` | Picture reset clears saved DDC state and baseline even when its identity LUT write fails | `usr/sbin/pgenerator-lg` | Reset reports success, the baseline is gone, and the recipe's reapply-and-verify step has nothing to verify against. | Medium |
| FAB-059 `MEDIUM.md:784` | Reused WebSocket request IDs let a late reply satisfy a different later request | `usr/sbin/pgenerator-lg` | Readback verification is the backbone of "apply the settings and verify they took effect". A stale reply can confirm a setting that never applied. | Medium |
| FAB-111 `MEDIUM.md:2059` | Cancellation and process-death promotion rewrite the first matching nested status via unanchored regex, not the top-level run status | `usr/share/PGenerator/webui.pm`, `usr/bin/meter_lg_autocal.pl` | Stop and dead-worker detection can leave the run reading `running`. Pause, stop and resume all key off that field. | Medium |
| FAB-065 `MEDIUM.md:959` | 3D post-check with `post_check=true` treats illuminated equal-channel CC24 neutrals as black because their `ire=0` metadata triggers a synthetic zero | `usr/bin/meter_session.sh`, `usr/bin/meter_lg_3d_autocal.pl`, `usr/share/PGenerator/webui-workspace.js` | Latent only because the current browser sends `post_check=false`. A Pi-side queue is precisely the programmatic caller that would turn it on. | Medium |
| FAB-129 `MEDIUM.md:2486` | Run pruning sorts wall-clock run IDs lexically, so a backward clock correction prunes recent completed runs first | `usr/share/PGenerator/PGAutoCalRun.pm`, `usr/share/PGenerator/PGICCProfile.pm` | Directly contradicts the retain-until-deleted policy. The design already flags this file's retention limit as needing work. | Medium |
| FAB-054 `MEDIUM.md:681` | Background discovery saves a stale clients snapshot over newer pairing and manual-IP data; all writers share one temp filename with no store lock | `usr/share/PGenerator/lg.pm`, `usr/share/PGenerator/daemon.pm` | Losing the pairing key mid-queue needs a human with a PIN. That ends unattended execution outright. | Medium |
| FAB-191 `LOW.md:1266` | Calibration archive writer truncates the destination and returns success without checking print or close | `usr/share/PGenerator/lg.pm` | Incomplete JSON that history cannot restore, recorded as a good archive. | Low |

---

## (b) Should fix

Real hazards for a long unattended run, but they either fail loudly, sit on a narrower path, or live in browser code the new workspace is expected to replace.

### Session, transport and pairing

| ID | Bug | Files cited | Why it matters | Sev |
|---|---|---|---|---|
| FAB-056 `MEDIUM.md:708` | The wss helper passes connect timeout as socat's `-T` inactivity timeout, so an idle transport drops after about 5 seconds | `usr/sbin/pgenerator-lg`, `usr/share/PGenerator/lg.pm` | Long LG commands and a 55-second pairing wait lose their transport mid-run. | Medium |
| FAB-052 `MEDIUM.md:630` | PIN pairing reports success and deletes its recovery copy after a failed key save | `usr/share/PGenerator/lg.pm` | The queue believes it is paired; the next reconnect fails and needs a human. | Medium |
| FAB-061 `MEDIUM.md:832` | A tolerated Dolby Vision CAL_START rejection allows DPG writes, then skips CAL_END and always returns an error | `usr/sbin/pgenerator-lg` | Dolby Vision items write data and then fail unconditionally, leaving session ownership uncertain. | Medium |
| FAB-053 `MEDIUM.md:656` | Forgetting the active TV can pair another saved TV key with the forgotten TV address | `usr/share/PGenerator/lg.pm` | A queue that survives a TV change can target the wrong panel with the wrong key. | Medium |

### Calibration solver and upload state desync

| ID | Bug | Files cited | Why it matters | Sev |
|---|---|---|---|---|
| FAB-044 `MEDIUM.md:433` | A failed per-iteration HDR upload leaves the unaccepted candidate as the next solver base | `usr/bin/meter_lg_autocal.pl` | The stored curve and the panel diverge with no error raised. | Medium |
| FAB-045 `MEDIUM.md:458` | HDR probe-up assigns `current_dpg` before the upload and does not undo it on failure; its final upload result is ignored | `usr/bin/meter_lg_autocal.pl` | Same divergence, plus a silently ignored final upload. | Medium |
| FAB-042 `MEDIUM.md:382` | After a worsening iteration the solver restores `best_dpg` but still derives the next gain from the rejected reading | `usr/bin/meter_lg_autocal.pl` | The gain is applied to a different curve from the one measured and can move the wrong way. | Medium |
| FAB-043 `MEDIUM.md:408` | An acceptance move first reached on the last permitted iteration uploads a refinement and ends with `acceptance_pending` still true; the final restore skips that state | `usr/bin/meter_lg_autocal.pl` | The run ends on an unmeasured, unrestored curve. | Medium |
| FAB-006 `HIGH.md:507` | A shadowed lexical makes SDR DDC white balance upload the baseline, save zero offsets, and return success for a requested 22-point change | `usr/bin/meter_lg_autocal.pl` | False success on a settings write, the exact failure class the design's verify step is meant to catch. | High |
| FAB-051 `MEDIUM.md:604` | 99/100 pair focus can bypass final 99% validation and save the result under 100% | `usr/bin/meter_lg_autocal.pl` | Legacy SDR DDC runs complete without their final validation. | Medium |
| FAB-033 `MEDIUM.md:158` | The 3D worker silently stops accepting volume patches at 2000 while the UI offers a 4913-node lattice | `usr/bin/meter_lg_3d_autocal.pl`, `usr/share/PGenerator/webui-app.js`, `usr/share/PGenerator/webui-workspace.js` | Silent truncation of a queued 3D profile. The design says do not silently skip. | Medium |

### Meter and pattern delivery

| ID | Bug | Files cited | Why it matters | Sev |
|---|---|---|---|---|
| FAB-067 `MEDIUM.md:1005` | A pattern-display connection failure leaves the read marked measuring; its curl has no deadline and can hang | `usr/bin/meter_session.sh` | An unattended stage hangs until a generic timeout with no terminal error. | Medium |
| FAB-064 `MEDIUM.md:937` | A later ordinary prompt from the original failure is treated as proof the retry failed | `usr/bin/meter_series.sh` | Aborts a read that would have recovered, ending the item. | Medium |
| FAB-147 `LOW.md:321` | Series meter respawn has no dark-calibration prompt handler after a low-light mode change | `usr/bin/meter_series.sh` | The queue stalls waiting on a prompt nobody will answer. | Low |
| FAB-151 `LOW.md:412` | INT and TERM run cleanup but do not exit, so a read continues after descriptors, state files and spotread are gone | `usr/bin/meter_session.sh` | Directly undermines the design's Stop semantics and holds the session lock. | Low |
| FAB-107 `MEDIUM.md:1964` | Continuous reads store all-zero `null_read` results as valid and can install a zero as series white | `usr/share/PGenerator/webui-app.js`, `usr/bin/meter_session.sh` | Corrupt measurements recorded as good data. | Medium |
| FAB-115 `MEDIUM.md:2153` | A saturated 100% reading satisfies the availability predicate but is rejected by the white finder, suppressing a needed white pre-read | `usr/share/PGenerator/webui-workspace.js`, `usr/share/PGenerator/webui-app.js`, `usr/share/PGenerator/webui.pm` | Automated sweeps lose their white reference without an error. | Medium |
| FAB-022 `HIGH.md:612` | A bright 0%-saturation grey can be reused as the measured black reference; G=0 lattice nodes also satisfy the saved-black test | `usr/share/PGenerator/webui-app.js`, `usr/share/PGenerator/webui-workspace.js` | Before/after reports are anchored to a wrong black. | High |
| FAB-084 `MEDIUM.md:1396` | Concurrent pattern writers can publish a torn command file through a shared `.tmp` path | `usr/share/PGenerator/webui.pm`, `usr/share/PGenerator/pattern.pm` | Corrupt patch commands during back-to-back automated stages. | Medium |
| FAB-071 `MEDIUM.md:1093` | A blocked pattern client stalls the shared event loop; blocking send with no deadline | `usr/share/PGenerator/daemon.pm` | One stuck client freezes the whole unattended run. | Medium |
| FAB-009 `HIGH.md:848` | CCSS creation and Dolby Vision profile cleanup stop and reclaim the meter owned by the independent meter lane; no helper PID guard during CCSS startup | `usr/share/PGenerator/lg.pm`, `usr/share/PGenerator/webui.pm`, `usr/bin/meter_session.sh` | Cross-lane meter seizure during a queue that mixes meter profiling and calibration. | High |
| FAB-034 `MEDIUM.md:181` | The Dolby Vision profile worker stops polling at 60 seconds while a legitimate read budget is 90 to 140 seconds | `usr/bin/meter_lg_dv_profile.pl`, `usr/bin/meter_session.sh` | A slow dark read aborts the profile before the meter itself times out. | Medium |
| FAB-035 `MEDIUM.md:204` | Dolby Vision start stops the meter session and clears its port cache, then sends no meter identity | `usr/bin/meter_lg_dv_profile.pl`, `usr/share/PGenerator/lg.pm`, `usr/share/PGenerator/webui.pm`, `usr/bin/meter_session.sh` | A two-meter rig reads the wrong instrument with no warning. | Medium |

### Reports, history and settings persistence

| ID | Bug | Files cited | Why it matters | Sev |
|---|---|---|---|---|
| FAB-116 `MEDIUM.md:2177` | A failed 3D AutoCal start clears report state; the successful retry restores config, run ID and results but not the captured Pre-Cal report | `usr/share/PGenerator/webui-workspace.js` | Exactly the "interruption must not discard completed measurements" rule. Browser-side mechanism, but the failure mode carries over. | Medium |
| FAB-117 `MEDIUM.md:2201` | Post-Cal re-anchoring replaces the report object and loses the intentional Skip Pre-Cal marker and completion metadata | `usr/share/PGenerator/webui-workspace.js` | History cannot distinguish an intentional skip from a missing stage. | Medium |
| FAB-127 `MEDIUM.md:2436` | Meter settings return ok when the runtime tmpfs save succeeds but the persistent save fails | `usr/share/PGenerator/webui.pm`, `etc/init.d/PGenerator` | Recipe-adjacent settings silently disappear at reboot. | Medium |
| FAB-128 `MEDIUM.md:2461` | Series cache copies accumulate per boot ID, old namespaces are retained, deleted entries stay indexed | `usr/share/PGenerator/webui-app.js` | Browser quota exhaustion prevents later recovery checkpoints during a long queue. | Medium |
| FAB-118 `MEDIUM.md:2225` | Restoring a full greyscale phase sets running flags without scheduling polling; the watchdog discards the terminal result | `usr/share/PGenerator/webui-workspace.js` | The design requires that closing and reopening the browser never interrupts or strands a run. | Medium |
| FAB-073 `MEDIUM.md:1139` | The common config writer ignores open, print, close and rename results; the caller still returns OK | `usr/share/PGenerator/file.pm`, `usr/bin/PGenerator_cmd.pl` | Pairs with FAB-025. A partial write replaces valid configuration and reports success. | Medium |
| FAB-144 `LOW.md:247` | Run-begin TV metadata reads `clients[ip]`, a store shape that does not exist, so every run records an empty tv object | `usr/share/PGenerator/lg.pm` | History entries lose the model, firmware and pairing context a result set needs to be meaningful. | Low |
| FAB-142 `LOW.md:202` | The abort diagnostic collapses to the number 1 because a ternary applies to the whole concatenated string | `usr/bin/meter_lg_autocal.pl` | Destroys the post-mortem for an unattended failure. | Low |
| FAB-108 `MEDIUM.md:1988` | Series stop waits indefinitely for two explicit false status flags with no close or recovery action | `usr/share/PGenerator/webui-app.js` | Stop semantics: a persistent endpoint failure leaves the operation permanently pending. | Medium |

### Appliance and environment

| ID | Bug | Files cited | Why it matters | Sev |
|---|---|---|---|---|
| FAB-193 `LOW.md:1310` | The watchdog trusts a stale PID file whenever that number exists in `/proc` and after five minutes kills it and its children without checking identity | `usr/sbin/pgenerator-webui-watchdog.sh` | A multi-hour unattended queue worker is a plausible victim of PID reuse. | Low |
| FAB-072 `MEDIUM.md:1116` | Debug and stderr logs in `/tmp` have no built-in size limit | `usr/share/PGenerator/variables.pm`, `usr/share/PGenerator/log.pm`, `usr/share/PGenerator/daemon.pm` | A long-running appliance queue is the case that exhausts the filesystem. | Medium |
| FAB-133 `MEDIUM.md:2579` | The dhcpcd hook runs `directlan_teardown` for any NOCARRIER event without checking the interface | `usr/lib/dhcpcd-hooks/99-PGeneratorDirectLan.conf` | A wlan0 blip removes the eth0 DirectLan connection to the TV. | Medium |
| FAB-170 `LOW.md:777` | EU CX and C1 model suffixes fail the browser generation regex and select the newer picture-mode map, while the daemon identifies them correctly | `usr/share/PGenerator/webui-lg.js`, `usr/sbin/pgenerator-lg` | A recipe can store a picture mode the TV does not have, and the failure appears only at execution time. | Low |

---

## (c) Merely related

Genuine confirmed bugs in the same code, but they do not specifically undermine unattended execution. Most are calibration accuracy defects that are equally wrong when a human is watching, or they sit on paths the queue does not use.

### Calibration and signal accuracy (wrong result, not false success)

| ID | Bug | Sev |
|---|---|---|
| FAB-004 `HIGH.md:206` | SDR body targets use the rejected last peak reading after restoring the best peak curve | High |
| FAB-005 `HIGH.md:234` | Full-range 10-bit HDR ladder is clamped into a limited code window | High |
| FAB-002 `HIGH.md:447` | 8-bit HDR shadow correction computes PQ targets with 10-bit limited black and span | High |
| FAB-197 `HIGH.md:478` | Include-greyscale exports discard measured neutral corrections in hybrid and skeleton solves | High |
| FAB-001 `HIGH.md:291` | Live 3D model accepts a missing primary corner and fabricates its contribution | High |
| FAB-020 `HIGH.md:639` | SDR26 per-reading target metadata uses 100 instead of the 109% peak | High |
| FAB-021 `HIGH.md:666` | HLG target luminance applies system gamma directly to the encoded signal | High |
| FAB-023 `HIGH.md:719` | HCFR greyscale import assigns compacted samples to the wrong stimulus | High |
| FAB-032 `MEDIUM.md:132` | Ramp model ignores its measured drift-start 100% white because of an empty profile placeholder | Medium |
| FAB-036 `MEDIUM.md:232` | Fixed 100% target white is normalised as the 109% peak on limited YCbCr SDR | Medium |
| FAB-037 `MEDIUM.md:256` | Legacy 109% white rebase divides out headroom a second time | Medium |
| FAB-038 `MEDIUM.md:281` | Dark Detail patch positions are used as physical DDC slot positions in the legacy path | Medium |
| FAB-040 `MEDIUM.md:334` | Legacy RGB adjustment errors ignore a configured custom white point | Medium |
| FAB-041 `MEDIUM.md:358` | Repeated HDR DPG smoothing changes previously calibrated anchors | Medium |
| FAB-046 `MEDIUM.md:483` | SDR low-IRE boost ceiling is limited by an earlier fixed 1.25 clamp | Medium |
| FAB-047 `MEDIUM.md:507` | SDR peak iteration budget parses 26 from the `sdr26` prefix | Medium |
| FAB-048 `MEDIUM.md:529` | Explicit 8-bit limited YCbCr SDR DPG configuration uses the wrong stimulus span | Medium |
| FAB-049 `MEDIUM.md:553` | SDR peak clamp suppresses the intended upward recovery of overshot channels | Medium |
| FAB-060 `MEDIUM.md:809` | HDR low-end continuity guard discards all but the final clamp per channel | Medium |
| FAB-200 `MEDIUM.md:909` | Offline HDR LUT export changes an explicit BT.709 target to BT.2020 | Medium |
| FAB-104 `MEDIUM.md:1893` | Near-black percentage IRE values are misread as unit fractions in gamma metrics | Medium |
| FAB-110 `MEDIUM.md:2036` | SDR26 server target normalisation reads the wrong scoped range variable | Medium |
| FAB-112 `MEDIUM.md:2083` | SDR26 stimulus lookup misses integer keys in three transport tables | Medium |
| FAB-137 to FAB-141, FAB-145, FAB-146 `LOW.md:80-321` | Legacy seeding, verification-signature and tone-map payload defects in the SDR DDC and LG LUT paths | Low |

### Third-party pattern sources, not the Pi queue

| ID | Bug | Sev |
|---|---|---|
| FAB-010 `HIGH.md:534` | Calman retains stale drawing bit depth after WebUI changes | High |
| FAB-012 `HIGH.md:561` | Resolve precision changes drop patches and repeatedly restart the renderer | High |
| FAB-068 `MEDIUM.md:1028` | Non-pattern Calman commands unexpectedly reclaim the signal range | Medium |
| FAB-069 `MEDIUM.md:1050`, FAB-070 `MEDIUM.md:1070` | GCI active-flag and multi-chunk upload corruption across classic clients | Medium |
| FAB-159 `LOW.md:525` | A nonmatching wildcard LUT row prevents later matching corrections | Low |
| FAB-157 `LOW.md:503` | LightSpace reconnects grow the discovery call stack | Low |

### Renderer internals (rebuilt-from-source findings, no bundled-binary parity established)

FAB-011 `HIGH.md:927`, FAB-074 `MEDIUM.md:1161`, FAB-075 `MEDIUM.md:1185`, FAB-076 `MEDIUM.md:1209`, FAB-077 `MEDIUM.md:1232`, FAB-078 `MEDIUM.md:1255`, FAB-079 `MEDIUM.md:1279`, FAB-080 `MEDIUM.md:1303`, FAB-081 `MEDIUM.md:1327`, FAB-082 `MEDIUM.md:1350`, FAB-083 `MEDIUM.md:1373`, FAB-085 `MEDIUM.md:1418`, FAB-154 `LOW.md:457`, FAB-156 `LOW.md:480`. Mostly EGL, DRM and framebuffer defects. FAB-085 (renderer restart deletes simulated-meter state) is the closest to the queue, since picture-mode changes restart the renderer, but only simulated-meter state is cited as lost.

### Desktop ICC profiling and Companion

FAB-196 `HIGH.md:262`, FAB-015 `HIGH.md:319`, FAB-007 `HIGH.md:344`, FAB-016 `HIGH.md:773`, FAB-017 `HIGH.md:901`, FAB-018 `HIGH.md:744`, FAB-019 `HIGH.md:953`, FAB-086 to FAB-102 `MEDIUM.md:1441-1821`, FAB-199 `MEDIUM.md:1845`, FAB-160 to FAB-176 `LOW.md:546-920`, FAB-182 `LOW.md:1057`. None of these sit on the LG TV calibration queue. FAB-017 (lost Companion patch acknowledgments are never retried, aborting a series after 30 seconds) would matter only if the queue ever used a Companion display as pattern source.

### Update, startup and networking machinery

| ID | Bug | Sev |
|---|---|---|
| FAB-030 `HIGH.md:124` | Failed updates leave a new version number on a partially updated system | High |
| FAB-031 `HIGH.md:397` | Two update requests overwrite the same download and installed files | High |
| FAB-028 `HIGH.md:422` | The watchdog can restart PGenerator during an update | High |
| FAB-029 `HIGH.md:372` | Updater can select a payload for the wrong Raspberry Pi target | High |
| FAB-027 `HIGH.md:876` | Starting an already running service can disrupt the existing renderer | High |
| FAB-136 `MEDIUM.md:2647` | Update downloads cannot finish when transfer exceeds sixty seconds | Medium |
| FAB-130 `MEDIUM.md:2533`, FAB-131 `MEDIUM.md:2556`, FAB-134 `MEDIUM.md:2601`, FAB-135 `MEDIUM.md:2624` | Hotspot, CEC, log rotation and DHCP PID-file defects | Medium |
| FAB-125 `MEDIUM.md:2389`, FAB-126 `MEDIUM.md:2412`, FAB-198 `MEDIUM.md:2510` | Backup temp file, delay-migration JSON corruption, export that restore rejects | Medium |
| FAB-192 `LOW.md:1288`, FAB-175 `LOW.md:896`, FAB-177 `LOW.md:944` | CEC adapter, standalone spotread helper, update UI reload timing | Low |

These matter only if an update, a reboot or a network change collides with a running queue. FAB-027 and FAB-028 become relevant if the queue survives across a daemon restart.

### Minor UI defects with no automation consequence

FAB-097 to FAB-101 `MEDIUM.md:1701-1798`, FAB-103 `MEDIUM.md:1870`, FAB-105 `MEDIUM.md:1916`, FAB-106 `MEDIUM.md:1940`, FAB-109 `MEDIUM.md:2012`, FAB-113 `MEDIUM.md:2106`, FAB-114 `MEDIUM.md:2130`, FAB-119 to FAB-124 `MEDIUM.md:2249-2366`, FAB-066 `MEDIUM.md:983`, FAB-148 to FAB-150 `LOW.md:344-389`, FAB-152 `LOW.md:435`, FAB-178 to FAB-190 `LOW.md:968-1244`. Chart hit-testing, toasts, modal state, WiFi parsing, standalone meter wrapper flags, duplicate completion handlers.

---

## Two gaps in the bug list itself

**No entry covers apply to all inputs.** The design leans on it heavily, including the rule that an unverifiable copy must be recorded as unverified rather than reported as an independently verified destination setting. The design's own findings section attributes the confirmation limit to `usr/sbin/pgenerator-lg` and `usr/share/PGenerator/lg.pm`, and notes it cannot run while a calibration session is held. That behaviour has not been audited to the standard of the 194 confirmed entries, so its absence from the list is not evidence that it is sound.

**No entry covers stage-boundary checkpointing or resume.** The closest are FAB-039 (truncated state files reported as written) and FAB-111 (status rewriting missing the top-level run status). The design's requirement that an all-input-copy failure must not force repeating a still-valid calibration has no existing mechanism behind it, which matches the design's own note that general queue checkpoints and recovery still need implementation.
