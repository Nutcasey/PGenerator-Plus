# Live proof protocol

How the implementing agent reaches the appliance and the TV, deploys, proves behaviour on real hardware, and collects evidence. Companion to [FULL_AUTOMATION_GOAL.md](../FULL_AUTOMATION_GOAL.md) section 8.

## 1. Equipment

| Item | Known facts (12 September 2026) |
|---|---|
| Pi appliance | BiasiLinux image, SysV init, Perl 5 with `JSON::PP`, `threads`, `IO::Socket::SSL`. Historically `192.168.50.110` (ssh alias `pgen`, user `root`, key `~/.ssh/id_ed25519_pgenerator`). Came back on DHCP at `192.168.50.111` after the 31 August power cycle. mDNS name `pgenerator.local`. |
| TV | LG OLED55G36LA (G3, webOS 23, software release 9.2.2) at `192.168.50.28`. SSAP ports 3000 and 3001 are the liveness check; ICMP is blocked from the Pi's shell. Pairing key lives in `/var/lib/PGenerator/lg/clients.json` on the Pi. |
| Meter | An X-Rite i1Display-class colorimeter attached to the Pi, driven by ArgyllCMS `spotread` through `usr/bin/meter_session.sh` and `meter_series.sh`. The simulated meter (`usr/bin/spotread_sim`) must be off for any proof. |
| Web UI | `http://<pi>/` served by `webui.pm` on port 80. |

On 12 September from the Mac, the live `pgen` alias reached `.110`; the paired proof target was confirmed as the G3 at `.28`. The G5 facts previously recorded in this document were stale and must not be used for this run.

## 2. Access preflight

Run before every live session. Stop and report if any line fails.

```sh
ssh -o ConnectTimeout=5 pgen 'hostname; uptime; cat /etc/PGenerator/version 2>/dev/null; /etc/init.d/PGenerator status'
ssh pgen 'curl -s --max-time 4 http://127.0.0.1/api/ping'
ssh pgen 'curl -s --max-time 30 -X POST http://127.0.0.1/api/lg/status -d "{}"'   # paired TV, model, power
ssh pgen 'curl -s --max-time 10 http://127.0.0.1/api/meter/status'                # detected, simulated:false
ssh pgen 'pgrep -af "meter_|PGeneratord" || true'                                  # nothing you did not start
```

If `pgen` resolves to the wrong address, fix `~/.ssh/config` on the Mac (`HostName`) rather than typing addresses into commands, so every later command and note stays valid.

Do not start a live step while a guided worker or meter session is running unless you started it.

## 3. Deploy

```sh
cd /Users/garry.casey/Desktop/personal/PGenerator-Plus
rsync -rl --no-perms --no-owner --no-group --exclude='__pycache__/' usr/ pgen:/usr/
ssh pgen 'chmod 755 /usr/bin/pgen_automation_runner.pl'            # every genuinely new executable
ssh pgen '/etc/init.d/PGenerator restart >/tmp/pgstart.log 2>&1; sleep 8; curl -s --max-time 4 http://127.0.0.1/api/ping'
```

Rules, from hard experience:

- Never sync `var/` or `etc/`. Deploy only `usr/`. The repo's `PGenerator.conf` is the default profile, not the owner's.
- Never `--delete`. Never glob-delete on the device: `usr/bin/meter_series.sh.bak` and `usr/share/PGenerator/ccss/QD-OLED_Generic.ccss` are tracked files.
- Always redirect the init script's output over SSH; an unredirected start wedges the daemon (listens, never answers).
- The cron watchdog restarts the daemon every minute while `/api/ping` fails. Give a restart eight seconds before judging it.
- Verify a deploy with a sha256 sweep of `git ls-files usr` against the device, joined on tab-separated `path<TAB>hash` lines and `LC_ALL=C sort` on both sides. Expect only the four benign mismatches recorded in the deploy notes.
- The daemon deletes `/tmp/meter_*.json` and `meter_lg_autocal.log` at startup. Copy evidence before restarting.

## 4. Smoke recipes

Short, cheap, repeatable. Any picture mode is allowed. Suggested shapes, each a saved recipe in the workspace:

| Recipe | Format | Stages | Notes |
|---|---|---|---|
| `smoke-measure-sdr` | SDR, Filmmaker | pre-readings only, `greyscale-21` only | Proves setup, verify, series capture, history rendering. Under 5 minutes. |
| `smoke-settings-hdr` | HDR10, Filmmaker | pre-readings only, `greyscale-21`, pinned G3-supported `backlight` and `energySaving` | Proves A1's first half and hazard pinning on the live G3. |
| `smoke-cal-sdr` | SDR, Cinema | calibration only, apply-to-all on, `max_iterations` reduced through the item config | Proves reset, reapply, greyscale, 3D, session close, apply-all. Reduce iteration caps in the item to keep it short; do not change worker defaults. |
| `smoke-cal-dv` | DV, Filmmaker | calibration only | Proves map-mode sequencing and the profile stage. |
| `smoke-target-light` | SDR, Expert (Bright space) | calibration only, `target` panel-light policy, target 100 nits | Proves A12. |

Queue them in pairs to prove A5 (same mode twice) and item boundaries (SDR then HDR).

Failure injection for A4: use the runner's test-only fault hook (goal section 4.1): create `/var/lib/PGenerator/automation/fault.json` containing `{"stage":"apply-all","mode":"error"}` before the item reaches c9. The runner treats the apply-all response as an explicit error, stops the queue, and records the injected fault in the item. Delete the file, Resume, and observe c9 rerun with c4 to c8 untouched by timestamps. Record in NOTES.md that the fault hook was used.

Failure injection for A11: `ssh pgen '/etc/init.d/PGenerator restart >/tmp/pgstart.log 2>&1'` while c6 is running. For the boot case without a reboot: `kill -9` the runner PID, restart the daemon, and confirm the run shows `interrupted` and Resume works.

## 5. Full-length proof

Announce before starting: the queue contents, the expected duration, and that the browser will be closed for at least one item. Then proceed unless told otherwise.

Minimum queue: three SDR modes (for example Filmmaker, Cinema, Game Optimiser) then two HDR10 modes, every item with pre-readings, calibration with apply-to-all, post-readings, default sweeps on both sides, and quality limits enabled on at least one item. Owner-chosen pinned settings per mode.

Afterwards leave the TV in the last item's mode with its settings, as the design requires. Do not restore anything.

## 6. Evidence bundle

One directory per proof session on the Mac, outside the repository:

```
~/PGenerator-automation-evidence/<YYYYMMDD-HHMM>-<label>/
  run/                 rsync of /var/lib/PGenerator/automation/runs/<run-id>/
  lg-last-write.log*   from /var/lib/PGenerator/lg/
  autocal-runs/        /var/lib/PGenerator/lg/autocal-runs/ entries created by the run
  tmp/                 /tmp/meter_*.json, /tmp/*.log captured BEFORE any restart
  webui/               screenshots of Live and History for the run
  NOTES.md             what was proved, which acceptance examples, anomalies, FAB ids observed
```

Copy the Pi-side files immediately after the run and before any restart. `lg/last-write.log` is the TV-communication record and survives reboots; the `/tmp` files do not survive a daemon start.

The PR body links the evidence directory path and quotes the one-line result per acceptance example. Evidence is never committed.

## 7. Leaving the appliance clean

Between proof sessions it is safe to clear `lg/autocal-runs`, `lg/luts`, `lg/ddc`, `lg/last-write.log*` and `reports/full-autocal` on the Pi once they are in an evidence bundle. Keep `lg/clients.json`, `meter_settings.json`, the live `PGenerator.conf`, and every run under `/var/lib/PGenerator/automation/` (those are the owner's history and are only deleted through the UI by the owner).
