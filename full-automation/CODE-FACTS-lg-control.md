> Code facts gathered 12 September 2026 against commit 42a6f3e8 for FULL_AUTOMATION_GOAL.md. Line numbers drift; re-grep before relying on one. Read-only survey, no design proposals.

# LG TV control surface — PGenerator-Plus

Read-only survey of `usr/share/PGenerator/lg.pm`, `usr/sbin/pgenerator-lg`,
`usr/share/PGenerator/webui-lg.js`, `usr/share/PGenerator/webui-workspace.js`,
`usr/bin/meter_lg_autocal.pl`, `usr/bin/meter_lg_3d_autocal.pl`,
`usr/bin/meter_lg_dv_profile.pl`. Repo root
`/Users/garry.casey/Desktop/personal/PGenerator-Plus`, branch `main` at `42a6f3e8`.

Architecture in one line: the web UI calls JSON endpoints in `lg.pm`, which
shell out to the standalone helper `usr/sbin/pgenerator-lg` (one websocket
session per invocation, wrapped in a `timeout N` backtick on the daemon's
single web-UI request thread). All TV traffic is webOS `ssap://`, the
`palm://`/Luna alert bridge, or `externalpq/setExternalPqData` for calibration.

---

## 1. Picture-mode selection

### 1.1 Label normalisation

`map_picture_mode_label_to_ddc_name` — `usr/sbin/pgenerator-lg:34`

Turns any UI, legacy or camelCase label into the exact webOS
`setSystemSettings` enum value. Takes an optional `$signal_mode` and returns
empty when the resolved canonical name is not valid in that signal family.

Key facts encoded in the map:

- SDR "Standard" is spelt `normal` in every captured webOS enum (C8, C9, CX,
  C1, C2, G3, G4, G5). `standard` appears in none — `usr/sbin/pgenerator-lg:70`.
- Dolby Vision write values are the raw `dolbyHdr*` spelling, **not** the web
  UI's own canonical `dolbyVision*` — `usr/sbin/pgenerator-lg:132`. Sending
  `dolbyVision*` straight through produces webOS 500 "There is No matched
  extended item: pictureMode". This was an operator-reported live bug
  (2026-07-24).
- DV Filmmaker and DV Cinema Dark both resolve to the write value
  `dolbyHdrCinema` — `usr/sbin/pgenerator-lg:257`. Hardware fact established
  on a C2 (webOS 4.1.0): the on-screen "Filmmaker" preset *is* webOS's dark DV
  cinema mode, and `dolbyHdrCinema` is the only accepted value. Writing
  `dolbyHdrCinemaDark`, `dolbyHdrFilmMaker`, `filmMaker`, `cinemaDark` or
  `dolby_cinema_dark` is rejected outright.
- Prefix strippers at `usr/sbin/pgenerator-lg:199` and
  `usr/sbin/pgenerator-lg:215` handle `sdr*`/`hdr*`/`hlg*`/`dolbyvision*`
  prefixes, but `$raw_token` is preserved so `hdrcinema` cannot be folded onto
  `cinema` — `usr/sbin/pgenerator-lg:49`.
- Explicit `hdrPersonalized` / `dolbyHdrPersonalized` entries exist precisely
  so the prefix stripper cannot collapse them onto the SDR token —
  `usr/sbin/pgenerator-lg:115`.

### 1.2 Signal-family mapping

- `lg_picture_mode_signal_for_canonical_name` — `usr/sbin/pgenerator-lg:235`.
  `dolby*` → `dv`; `hdr*` → `hdr10`; everything else → `sdr`. Empty for unknown.
- `lg_picture_mode_signal_compatible` — `usr/sbin/pgenerator-lg:247`. HLG counts
  as HDR10. Returns 1 (permissive) for empty/unknown inputs.
- `lg_picture_mode_signal_examples` — `usr/sbin/pgenerator-lg:265`. Short
  suggestion list per signal, for error messages.

A caller-supplied mode that fails the signal check aborts `picture_set` before
any TV write, with `error_code => "unknown-picture-mode-label"` —
`usr/sbin/pgenerator-lg:6367`.

### 1.3 Front-end mode lists (per signal, per generation)

Three tables in `usr/share/PGenerator/webui-lg.js`, each keyed
`sdr` / `hdr10` / `hlg` / `dv`:

| Table | Line | Applies to |
|---|---|---|
| `LG_PICTURE_MODES_BY_SIGNAL` | `webui-lg.js:114` | current generations (C2+) |
| `LG_2018_2019_PICTURE_MODES_BY_SIGNAL` | `webui-lg.js:168` | C8/C9 (Technicolor family, no Filmmaker) |
| `LG_PRE2022_PICTURE_MODES_BY_SIGNAL` | `webui-lg.js:208` | CX/C1 (no Personalised, no HDR Eco) |

Selection is by model-name regex: `lgUsesPre2022PictureModeMap` at
`webui-lg.js:297`, `lgUses2018Or2019PictureModeMap` at `webui-lg.js:303`,
dispatched in `lgPictureModesForSignal` at `webui-lg.js:309`.

Current-generation DV list (`webui-lg.js:152`) is operator-confirmed on a C2:
DV Cinema Home, DV Filmmaker, DV Game Optimizer, DV Vivid, DV Standard, DV
Personalised Picture. There is no separate DV "Cinema" distinct from Cinema
Home on that menu.

Per-signal selection is persisted in `localStorage` under
`lgPictureMode:<signal>` — `webui-lg.js:450`.

### 1.4 Readback-verified selection

`lg_picture_mode_select` — `usr/sbin/pgenerator-lg:7205`

The authority. Sequence:

1. Read the mode before writing (`lg_current_picture_mode`,
   `usr/sbin/pgenerator-lg:7150`, `settings/getSystemSettings` with
   `keys: ["pictureMode"]`).
2. If already on the requested token, return `route => "already-active"`,
   `verified => 1`, no write.
3. Otherwise dispatch on the route list:
   - Normal: public `settings/setSystemSettings` first (it answers with a real
     error envelope), then the Luna bridge
     `com.webos.settingsservice/setSystemSettings`.
   - Legacy DV (see 1.5): a single `luna-scoped` route carrying
     `current_app: true` and `dimension: {input, _3dStatus: "2d"}`.
4. After each route, poll the readback. `verified` is set **only** when the
   readback matches. Luna is never trusted without it, because its reply is the
   alert-close acknowledgement, not the settings service's —
   `usr/sbin/pgenerator-lg:7171`.
5. Luna is polled even when its dispatch reported failure, because the write
   fires from the alert's close handler — `usr/sbin/pgenerator-lg:7256`.
6. A token the settings service rejected with "no matched extended item" is
   **not** retried on Luna: the token is wrong, not the transport —
   `usr/sbin/pgenerator-lg:7276`.

Polling parameters — `usr/sbin/pgenerator-lg:7189`:

| Parameter | Value |
|---|---|
| `$PICTURE_MODE_SELECT_POLLS` | 12 |
| `$PICTURE_MODE_SELECT_POLL_INTERVAL` | 0.25 s |
| `$PICTURE_MODE_SELECT_READBACK_TIMEOUT` | 3 s |
| `$PICTURE_MODE_SELECT_DEADLINE` | 20 s (whole select, both routes) |

Each readback uses a unique request id so a late reply to a timed-out poll
cannot be consumed as the next poll's answer.

### 1.5 The G5 findings, as they actually appear in code

**The ~8 s inter-switch wait is not in the code.** It is operator practice, not
an implemented delay. The code polls at 250 ms and the comment at
`usr/sbin/pgenerator-lg:7183` records the opposite measurement: *"The G5 reads
the new token back within the first one or two polls; 12 x 0.25 s per route
covers an HDMI re-sync."* There is no sleep between successive mode switches
anywhere in `webui-lg.js` or the helper.

**The G5 finding that is in code** is the legacy DV route scope.
`lg_legacy_dv_picture_mode_route_required` — `usr/sbin/pgenerator-lg:7194` —
restricts the input-scoped Luna payload to platform years 2018-2022 or series
matching `^[A-Z](8|9|X|1|2)$`. The comment at `usr/sbin/pgenerator-lg:7178`
records that the G5 (OLED83G54LW, webOS 25, 2026-08-23) proved applying that
scope universally is unsafe: the scoped write was acknowledged but the old mode
read back.

The G5's `applyToAllInput` readback refusal is real and handled — see §5.

### 1.6 Generations that cannot switch or cannot report

`lg_generation_info` — `usr/sbin/pgenerator-lg:5783` — derives
`platform_year` (from `W(\d{2})` in the platform model), `series` (from the
OLED model-name suffix, with European tuner-code handling at
`usr/sbin/pgenerator-lg:5795`), and `webos_major`. It sets:

- `ddc_only_white_balance` = 1 when `platform_year <= 2021`, or
  `series_year <= 2021`, or `webos_major <= 6`, or nothing resolved at all
  (conservative default) — `usr/sbin/pgenerator-lg:5813`.
- `picture_mode_read_forbidden` = the same flag —
  `usr/sbin/pgenerator-lg:5845`.

On a `ddc_only` set, `lg_picture_set_workflow` takes a separate path —
`usr/sbin/pgenerator-lg:6385` — trying `palm-bridge`, `luna-bridge`, and
input-scoped variants of each. An accepted bridge write is treated as switched
(hardware-confirmed on a 2021 panel); the readback only *upgrades* it to
verified. Returns `manual_confirmation_required` when unverified —
`usr/sbin/pgenerator-lg:6461`.

If every bridge attempt fails, the helper records a virtual DDC target and
returns `virtual_picture_settings: true` — `usr/sbin/pgenerator-lg:6483`. The
web UI must not persist that as a TV readback; both persistence sites guard on
it (`webui-lg.js:1057`, `webui-lg.js:1110`).

A 2021 C1 cannot report `pictureMode` on **any** route — documented at
`usr/sbin/pgenerator-lg:7112`, citing commit `2841812f`. The standing warning
against re-deriving these capability gates from `platform_year <= 2020` is at
`usr/sbin/pgenerator-lg:7117` (commit `eb255177` did exactly that and broke
calibration resets for weeks).

### 1.7 Independent mode probe

`lg_picture_mode_probe` — `usr/sbin/pgenerator-lg:7131`

Returns five keys for merging into a workflow result:

- `tv_picture_mode` (empty means *unknown*, never "no mode set")
- `picture_mode_readable`
- `tv_picture_mode_matches`
- `last_written_picture_mode`
- `last_written_picture_mode_matches`

Comparison goes through `lg_picture_mode_tokens_agree` —
`usr/sbin/pgenerator-lg:7079` — never raw strings, because
`dolbyVisionCinema` reads back as `dolbyHdrCinema`. That function falls back to
the raw token when the map does not know a label, which can turn a
map-incomplete readback into a false disagreement — deliberately the fail-safe
direction (a spurious stop, never a silent wrong-mode run), documented at
`usr/sbin/pgenerator-lg:7084`.

Callers: `lg_picture_reset_workflow` (`usr/sbin/pgenerator-lg:1918`),
`lg_hdr_calman_reset_workflow` (`usr/sbin/pgenerator-lg:4195`),
`lg_dv_calman_reset_workflow` (`usr/sbin/pgenerator-lg:4334`). The polled
`picture_get` path deliberately does **not** probe — the AutoCal panels poll it
every ~30 s on the daemon's single request thread.

`last_written_picture_mode` is persisted by `webui_lg_picture_settings_set` at
`usr/share/PGenerator/lg.pm:1960`, is explicitly *what we last asked for* (not
verified on fire-and-forget generations), and is cleared on disconnect by
`lg_mark_disconnected` (`usr/share/PGenerator/lg.pm:354`).

### 1.8 Renderer side-effect of a mode switch

`usr/share/PGenerator/lg.pm:1901` — a picture-mode-only write that actually
changed the mode triggers `pattern_generator_stop()` + `pattern_generator_start()`
and reports `renderer_resynced`. Reason: a native webOS picture-mode write can
reset the sink's HDMI pipeline while vc4 has a page flip outstanding, leaving
older renderers stuck in `drmHandleEvent()` with the previous patch on screen.

Skipped when `virtual_picture_settings` (no TV write happened) or when
`picture_mode_changed` is false (no-op selection).

### 1.9 Failure reporting

`lg_picture_mode_select_failure` — `usr/sbin/pgenerator-lg:7286` — produces
three distinct messages because the fix differs: TV stopped answering after the
write; every route rejected the token (wrong signal family, or a mode this set
will not switch over the network); or the TV answered but stayed on another
mode. Also handles `legacy-dv-input-scope-unavailable`
(`usr/sbin/pgenerator-lg:7305`).

Front-end: `lgSetPictureMode` at `webui-lg.js:1658`, 50 s client timeout
deliberately above the helper's own 45 s budget so the UI does not declare
failure while the helper is still switching the TV
(`webui-lg.js:1676`).

---

## 2. Picture settings: get / set / readback

### 2.1 There is a generic passthrough

Both endpoints accept arbitrary keys. There is **no allowlist** restricting
which webOS picture keys you may read or write.

| Endpoint | lg.pm handler | Helper workflow |
|---|---|---|
| `POST /api/lg/picture-settings` | `webui_lg_picture_settings` — `lg.pm:1822` | `lg_picture_get_workflow` — `pgenerator-lg:1307` |
| `POST /api/lg/picture-settings/set` | `webui_lg_picture_settings_set` — `lg.pm:1878` | `lg_picture_set_workflow` — `pgenerator-lg:6331` |
| `POST /api/lg/picture-settings/reset` | `webui_lg_picture_reset` — `lg.pm:2015` | `lg_picture_reset_workflow` — `pgenerator-lg:1897` |
| `POST /api/lg/picture-settings/apply-all-inputs` | `webui_lg_picture_apply_all_inputs` — `lg.pm:2058` | `lg_picture_apply_all_inputs_workflow` — `pgenerator-lg:7413` |

Routing table: `webui_lg_api` — `usr/share/PGenerator/lg.pm:3353`.

Under the hood both wrap `settings/getSystemSettings` and
`settings/setSystemSettings` with `category: "picture"`.

### 2.2 Request shape

`picture-settings` (read) accepts: `keys` (array; defaults to
`lg_picture_default_keys`), `picture_mode`, `signal_mode`,
`ignore_calibration_picture_mode`, `include_current_input`,
`force_ddc_white_balance`, `helper_timeout` — `lg.pm:1838`-`lg.pm:1866`.

`picture-settings/set` accepts: `settings` (hash, required), `readback_keys`
(defaults to the keys written), `skip_readback`, `picture_mode`, `signal_mode`,
`keep_calibration_mode`, `calibration_mode_active`, `reset_ddc_baseline` /
`clear_ddc_baseline`, `verify_ddc_upload`, `force_ddc_white_balance`,
`ignore_calibration_picture_mode`, `helper_timeout` — `lg.pm:1892`-`lg.pm:1930`.

### 2.3 Exposed setting keys

**Web UI control list** — `LG_DISPLAY_CONTROL_ITEMS`,
`usr/share/PGenerator/webui-lg.js:245`. 31 keys with type and range metadata:

| Key | Type | Range / options |
|---|---|---|
| `brightness` | number | 0-100 |
| `contrast` | number | 0-100 |
| `blackLevel` | select | auto, low, high, limited, full |
| `blackLevelAdjust` | number | 0-100 |
| `backlight` | number | 0-100 |
| `oledLight` | number | 0-100 |
| `oledPixelBrightness` | number | 0-100 |
| `peakBrightness` | select | off, low, medium, high |
| `color` | number | 0-100 |
| `colorDepth` | number | 0-100 |
| `tint` | number | 0-100 |
| `sharpness` | number | 0-100 |
| `hSharpness` | number | 0-100 |
| `vSharpness` | number | 0-100 |
| `gamma` | select | 1.9, 2.2, 2.4, bt1886, BT.1886 |
| `colorTemperature` | select | cool, medium, warm, warm1-3, expert1, expert2 |
| `colorGamut` | select | auto, native, extended, wide |
| `energySaving` | select | off, minimum, medium, maximum, auto, screenOff |
| `dynamicContrast` | select | off, low, medium, high |
| `dynamicColor` | select | off, low, medium, high |
| `localDimming` | select | off, low, medium, high |
| `noiseReduction` | select | off, low, medium, high, auto |
| `mpegNoiseReduction` | select | off, low, medium, high, auto |
| `smoothGradation` | select | off, low, medium, high |
| `superResolution` | select | off, low, medium, high |
| `realCinema` | select | off, on |
| `eyeComfortMode` | select | off, on |
| `blackFrameInsertion` | select | off, low, medium, high |
| `truMotionMode` | select | off, cinematicMovement, natural, smooth, user |
| `deJudder` | number | 0-10 |
| `deBlur` | number | 0-10 |

**Perl-side key lists:**

- `lg_picture_default_keys` — `usr/share/PGenerator/lg.pm:1476`. The
  white-balance read set: `pictureMode`, `whiteBalanceMethod`,
  `whiteBalancePoint`, `whiteBalanceIre`, `whiteBalanceIre10pt`,
  `whiteBalanceCodeValue`, `whiteBalanceCodeValue10pt`,
  `whiteBalanceLuminance`, `whiteBalanceColorTemperature`, `colorTemperature`,
  `whiteBalanceRed/Green/Blue`, `whiteBalanceRed/Green/Blue10pt`,
  `whiteBalanceRed/Green/BlueGain`, `whiteBalanceRed/Green/BlueOffset`,
  `oledLight`, `backlight`, `adjustingLuminance`, `adjustingLuminance10pt`.
- `lg_picture_diagnostic_keys` — `usr/share/PGenerator/lg.pm:1507`. The above
  plus `brightness`, `contrast`, `blackLevel`, `blackLevelAdjust`,
  `oledPixelBrightness`, `peakBrightness`, `color`, `colorDepth`, `tint`,
  `sharpness`, `hSharpness`, `vSharpness`, `gamma`, `colorGamut`,
  `energySaving`, `dynamicContrast`, `dynamicColor`, `localDimming`,
  `noiseReduction`, `mpegNoiseReduction`, `smoothGradation`,
  `superResolution`, `realCinema`, `eyeComfortMode`, `blackFrameInsertion`,
  `truMotionMode`, `deJudder`, `deBlur`.
- `lg_picture_panel_light_keys` — `usr/sbin/pgenerator-lg:1225`:
  `backlight`, `oledLight`, `oledPixelBrightness`.
- `lg_picture_reset_default_keys` — `usr/sbin/pgenerator-lg:1473` (see §3).
- `lg_picture_reset_white_balance_keys` — `usr/sbin/pgenerator-lg:1501`
  (22 keys, see §3).

### 2.4 Capability discovery

Every read returns three extra fields, built by the `$capability_payload`
closure at `usr/sbin/pgenerator-lg:1325`:

- `requested_picture_keys`
- `supported_picture_keys` (sorted list of keys the TV actually answered)
- `unsupported_picture_keys` (hash key → reason; keys the TV silently omitted
  get `"No value returned by TV"`)
- `picture_capabilities: { supported, unsupported }`

The read strategy is bulk-first, then per-key fallback:
`$get_supported_settings` at `usr/sbin/pgenerator-lg:1347`. A bulk failure
falls back to one request per key so a single unsupported key cannot blank the
whole read.

The web UI consumes these at `webui-lg.js:1051` and uses them to grey out
controls the model does not expose.

**This is the discovery mechanism a new design should use** rather than
hard-coding per-model key support.

### 2.5 Category / dimension escalation on write

`lg_picture_set_workflow` builds a base payload at
`usr/sbin/pgenerator-lg:6558`:

```
{ category => "picture", settings => {...} }
```

plus `dimension => { pictureMode => $active }` when a mode is known and the
write is not panel-light-only (`usr/sbin/pgenerator-lg:6561`).

On rejection it escalates. Two separate fallback ladders:

**Panel-light-only writes** — `usr/sbin/pgenerator-lg:6716`:
1. Luna, `dimension: {input, pictureMode, _3dStatus}`
2. Luna, `dimension: {pictureMode}`
3. Luna, bare `category: "picture"`
4. Public, scoped category `picture$<input>.<mode>.2d.x`
5. Luna, same scoped category

**Other writes**, when the error matches
`/doesn't support the key|not support|undefined|-1000|Application error/` —
`usr/sbin/pgenerator-lg:6770`:
1. Public, full dimension
2. Public, scoped category
3. Luna, full dimension
4. Luna, scoped category

**Permission errors** (`401 insufficient permissions`) get one Luna retry —
`usr/sbin/pgenerator-lg:6816` — then return `json_permission_error` with the
PIN-repair hint.

Signal suffixes for scoped categories: `lg_picture_signal_suffixes` —
`usr/sbin/pgenerator-lg:1528`. `sdr` → (`sdr`, `x`); `hdr10` → (`hdr10`,
`hdr`, `x`); `hlg` → (`hlg`, `hdr`, `x`); `dv` → (`dolby`, `dv`, `x`).
Assembled by `lg_picture_scoped_categories` — `usr/sbin/pgenerator-lg:1607`.

Full payload ladder for arbitrary settings:
`lg_picture_apply_settings_payloads` — `usr/sbin/pgenerator-lg:1685` (8
variants: 4 public, 4 Luna).

### 2.6 Readback on write

`readback_keys` defaults to the keys you wrote (`lg.pm:1900`); `skip_readback`
sets it empty.

Two readback paths in `lg_picture_set_workflow`:

- **Panel-light-only** — `usr/sbin/pgenerator-lg:6874`. Up to **14 attempts**,
  each sweeping up to four payload shapes (the write payload, bare `picture`,
  the scoped category, and the full dimension) one key at a time. Verified when
  every written value matches to within 0.1. `select(0.4)` between attempts. If
  nothing comes back at all, the write is reported as an **error** —
  `usr/sbin/pgenerator-lg:6913`.
- **Everything else** — `usr/sbin/pgenerator-lg:6921`. One
  `getSystemSettings`, category `picture` or the scoped category when not a
  native white-balance write, carrying the write's dimension. If it returns
  nothing, `settings_after` is synthesised from what was written —
  `usr/sbin/pgenerator-lg:6934`.

General-purpose readback helper (used by resets and the DDC path):
`lg_picture_readback_settings` — `usr/sbin/pgenerator-lg:1578`, driven by
`lg_picture_readback_payloads` — `usr/sbin/pgenerator-lg:1539`. Tries bulk
then per-key, across input-scoped, mode-dimensioned and bare payloads, and
returns on the first payload that yields anything. When the keys are
panel-light only and no input is known, it sweeps `hdmi1`-`hdmi4` —
`usr/sbin/pgenerator-lg:1567`.

### 2.7 Three hard constraints on writes

**(a) Panel light is special everywhere.** `backlight`, `oledLight`,
`oledPixelBrightness` get their own key list
(`usr/sbin/pgenerator-lg:1225`), their own detection
(`lg_picture_keys_panel_light_only`, `usr/sbin/pgenerator-lg:1229`), their own
scoped category (`picture$<input>.<mode>.2d.x`,
`usr/sbin/pgenerator-lg:6560`), their own fallback ladder, their own strict
readback, and their own reset path. The recorded reason
(`usr/sbin/pgenerator-lg:2141`): `setSystemSettings(backlight=...)` is
rejected on a C2 outside an active CAL_START session, and
`resetSystemSettings` does not reliably reset `oledLight` /
`oledPixelBrightness` on C1/C2 either.

**(b) Non-writable picture modes.** White-balance writes (and any non-panel-light
write on the white-balance path) are refused unless the calibration-mode name
matches `$WRITABLE_PICTURE_MODES_RE` — `usr/sbin/pgenerator-lg:2521`. That
regex admits expert1/2, isfexpert1/2, technicolorexpert, filmmaker,
filmmakermode, cinema, cinemahome, game, the `hdr*` equivalents, the
`dolbyVision*` names, and the catch-all `dolby_hdr_[a-z_]+`. Refusal is
`error_code => "non-writable-picture-mode"` at `usr/sbin/pgenerator-lg:6544`,
message: *"White-balance writes are only accepted on Expert/ISF/FilmMaker/Cinema
modes."*

**(c) DDC-only generations forbid three key families.**
`lg_picture_key_forbidden_on_ddc_only` — `usr/sbin/pgenerator-lg:5877` —
matches `pictureMode`, `colorTemperature`, `whiteBalance.*`. On those sets the
read path strips them and answers from PGenerator's own DDC state instead
(`lg_ddc_virtual_picture_settings`, `usr/sbin/pgenerator-lg:5967`), returning
`virtual_picture_settings: true` and the message *"LG white-balance settings
are represented through PGenerator DDC state on this LG generation."*
(`usr/sbin/pgenerator-lg:1441`).

### 2.8 The DDC white-balance path

When the settings hash contains a 22-point RGB white-balance set
(`lg_settings_are_ddc_white_balance`, `usr/share/PGenerator/lg.pm:1868` —
`whiteBalanceMethod == "22"` plus three array channels), the write is routed to
`lg_ddc_1d_white_balance_set` — `usr/sbin/pgenerator-lg:5995` — which builds
and uploads a 1D LUT rather than writing menu keys.

Slot labels — `usr/sbin/pgenerator-lg:2708`:

- SDR (26 points): 2.3, 3, 4, 5, 7, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55,
  60, 65, 70, 75, 80, 85, 90, 95, 99, 105, 109
- HDR20 (20 points): 1.4, 2, 2.7, 4, 5, 7, 10, 15, 20, 25, 30, 35, 40, 45, 50,
  60, 70, 80, 90, 100

Layout is selected per write via `local @LG_DDC_1D_LABELS` —
`usr/sbin/pgenerator-lg:5998`.

The DDC result carries its own verification fields back to the caller
(`usr/sbin/pgenerator-lg:6658`): `ddc_reset_verified`, `ddc_upload_verified`,
`ddc_reset_verify_contract`, `ddc_readback_unavailable` +
`_reason`, `ddc_verify_mismatch`, `calibration_mode_requested`,
`calibration_mode_ensured`, `cal_start_sent`.

Non-white-balance readback keys requested alongside a DDC write are fetched
natively and merged — `usr/sbin/pgenerator-lg:6612`.

### 2.9 Read-only poll gating

`webui_lg_picture_settings` applies `lg_tv_off_gate` —
`usr/share/PGenerator/lg.pm:1848`. Rationale recorded there: the AutoCal panels
re-poll this endpoint every ~30 s whether or not anyone is calibrating, and
with the TV off the 60 s helper wrapper froze the web UI's single request
thread. The gate is **never** applied to `picture_set` or any calibration path.
See §8 for the gate itself.

### 2.10 Front-end read/write

- `lgDisplayControlRefresh` — `webui-lg.js:1032`. Reads `pictureMode` plus all
  31 control keys, 18 s timeout, `ignore_calibration_picture_mode: true`.
- `lgDisplayControlCommit` — `webui-lg.js:1082`. Writes **one key at a time**,
  clamps numbers to the item's min/max, 30 s timeout,
  `readback_keys: [key, 'pictureMode']`, reverts the local value on failure.
- Workspace read/write sites: `webui-workspace.js:3770`, `:3905`, `:4195`,
  `:4245`, `:5267`, `:5287`, `:5491`.

---

## 3. Calibration resets and their picture-control side effects

Four reset entry points. **All of them move picture controls.** The design's
claim is correct.

### 3.1 Picture reset

`webui_lg_picture_reset` — `usr/share/PGenerator/lg.pm:2015` →
`lg_picture_reset_workflow` — `usr/sbin/pgenerator-lg:1897`

Five phases, in order.

**Phase 1 — general picture keys.** Key list from
`lg_picture_reset_keys_from_tv` — `usr/sbin/pgenerator-lg:1624` — which is
`lg_picture_reset_default_keys` (`usr/sbin/pgenerator-lg:1473`) unioned with
every extra picture key the TV itself reports, minus `pictureMode` and minus
anything matching `^whiteBalance` or `^adjustingLuminance`
(`lg_picture_reset_unique_keys`, `usr/sbin/pgenerator-lg:1485`).

The default list, verbatim:

```
brightness, contrast, blackLevel, blackLevelAdjust,
backlight, oledLight, oledPixelBrightness, energySaving, peakBrightness,
color, colorDepth, tint, sharpness, hSharpness, vSharpness,
gamma, colorTemperature, colorGamut, dynamicContrast, dynamicColor,
localDimming, noiseReduction, mpegNoiseReduction, smoothGradation,
superResolution, realCinema, eyeComfortMode, blackFrameInsertion,
truMotion, truMotionMode, deJudder, deBlur
```

Dispatched as `resetSystemSettings` across three dimensions and the scoped
categories, public and Luna — `usr/sbin/pgenerator-lg:1960`. Bulk first, then
per-key when the error names unsupported keys.

**Phase 2 — white balance.** `lg_picture_reset_white_balance_keys` —
`usr/sbin/pgenerator-lg:1501` — 22 keys:

```
whiteBalanceMethod, whiteBalancePoint, whiteBalanceIre, whiteBalanceIre10pt,
whiteBalanceCodeValue, whiteBalanceCodeValue10pt, whiteBalanceLuminance,
whiteBalanceColorTemperature, whiteBalanceRed, whiteBalanceGreen,
whiteBalanceBlue, whiteBalanceRed10pt, whiteBalanceGreen10pt,
whiteBalanceBlue10pt, whiteBalanceRedGain, whiteBalanceGreenGain,
whiteBalanceBlueGain, whiteBalanceRedOffset, whiteBalanceGreenOffset,
whiteBalanceBlueOffset, adjustingLuminance, adjustingLuminance10pt
```

Same payload ladder — `usr/sbin/pgenerator-lg:2026`.

**Phase 3 — panel light.** `resetSystemSettings` on
`backlight`/`oledLight`/`oledPixelBrightness` across the same ladder —
`usr/sbin/pgenerator-lg:2087`.

**Phase 4 — the UI_DATA CAL bracket.** `usr/sbin/pgenerator-lg:2129`.
This reset **opens its own CAL_START session** and writes four values
(`usr/sbin/pgenerator-lg:2168`):

| Command | Value |
|---|---|
| `BRIGHTNESS_UI_DATA` | 50 |
| `CONTRAST_UI_DATA` | 85 |
| `BACKLIGHT_UI_DATA` | 80 |
| `COLOR_UI_DATA` | 50 |

BACKLIGHT 80 is deliberate and is the C2 cinema factory default, not 100 —
comment at `usr/sbin/pgenerator-lg:2172`. The CAL_START payload carries
`picMode` (a C2 rejects it otherwise) and a 9-float all-zeros 3x3 matrix —
`usr/sbin/pgenerator-lg:2152`. If the bracket's CAL_END is unacknowledged, the
result carries `calibration_session_unconfirmed` —
`usr/sbin/pgenerator-lg:2192` — and the caller must not clear the persisted
calibration-mode flag on the strength of this reset.

**Phase 5 — DDC clear.** Only when `reset_ddc_state` is set (which the endpoint
derives from `require_white_balance_reset`, `lg.pm:2039`). Writes an all-zero
26-slot white-balance set and calls `lg_ddc_clear_state` —
`usr/sbin/pgenerator-lg:2276`.

**Fallback chains** when `resetSystemSettings` is refused:

1. `lg_picture_delete_settings_reset` — `usr/sbin/pgenerator-lg:1796` —
   `deleteSystemSettings` over four path/scheme combinations.
2. `lg_picture_factory_default_values` — `usr/sbin/pgenerator-lg:1652` —
   reads `getSystemSettingFactoryValue` per key, then applies via
   `lg_picture_apply_factory_defaults` — `usr/sbin/pgenerator-lg:1712`.
3. `lg_picture_builtin_default_values` — `usr/sbin/pgenerator-lg:1759` —
   hard-coded, **SDR only** (returns `{}` for any other signal). Cinema/default:
   brightness 50, contrast 85, backlight/oledLight/oledPixelBrightness 80,
   color/colorDepth 50, tint 0, sharpness 10. Vivid: panel 100, contrast 100,
   sharpness 30, color 70. Standard/normal/eco/aps: panel 80, contrast 85,
   sharpness 25, color 50.

`basic_picture_reset_ok` is satisfied when brightness **and** contrast landed by
any of the five routes — `usr/sbin/pgenerator-lg:2255`.

**Best-effort escape hatch.** `lg_picture_reset_is_blocking` —
`usr/sbin/pgenerator-lg:1874` — returns 0 (non-blocking) when the generation's
`reset_method` is `ddc_cal_identity` and either webOS forbade the method
("Not allowed to call method") or the set is `ddc_only`. The workflow then sets
`picture_reset_best_effort => "not_permitted"` —
`usr/sbin/pgenerator-lg:2336`.

**HDR escalation.** If the active mode is an HDR mode and the basic reset
failed, the workflow calls `lg_hdr_calman_reset_workflow` inline —
`usr/sbin/pgenerator-lg:2309` — because webOS rejects `resetSystemSettings`
outright on HDR picture modes.

### 3.2 HDR Calman reset

`webui_lg_hdr_calman_reset` — `usr/share/PGenerator/lg.pm:2652` →
`lg_hdr_calman_reset_workflow` — `usr/sbin/pgenerator-lg:4174`.
Route: `POST /api/lg/hdr-calman-reset` (`lg.pm:3393`).

Requires a `hdr_` calibration mode (`usr/sbin/pgenerator-lg:4185`).
All steps inside **one** CAL_START/CAL_END bracket:

| Order | Command | Value |
|---|---|---|
| 1 | `CAL_START` | force_pic_mode + HDR float payload |
| 2 | `1D_2_2_EN` | 0 |
| 3 | `1D_0_45_EN` | 0 |
| 4 | `BRIGHTNESS_UI_DATA` | 50 |
| 5 | `CONTRAST_UI_DATA` | **100** |
| 6 | `BACKLIGHT_UI_DATA` | **100** |
| 7 | `COLOR_UI_DATA` | 50 |
| 8 | `dynamicContrast` | off (via settings, not externalpq) |
| 9 | `BT2020_3BY3_GAMUT_DATA` | identity 3x3 |
| 10 | `BT2020_3D_LUT_DATA` | unity 33-cube |
| 11 | `1D_DPG_DATA` | unity 1D |
| 12 | `CAL_END` | same payload as CAL_START |

Step list at `usr/sbin/pgenerator-lg:4230`. **Note the divergence from the SDR
path: contrast and backlight land at 100 here, against 85 and 80 for SDR.**

Any failed step fails the whole reset — `usr/sbin/pgenerator-lg:4302`.

CAL_START failure handling: `lg_calibration_start_explicit_rejection`
(`usr/sbin/pgenerator-lg:2617`), `lg_calibration_start_cleanup_if_safe`
(`:2639`), and the driver-error-20 fingerprint
`lg_externalpq_error_is_expected_driver_rejection` (`:2662`). A stuck driver
yields `error_code => "lg-calibration-driver-stuck"` and
`tv_restart_may_be_required` — `usr/sbin/pgenerator-lg:4217`. No speculative
CAL_END is sent in that case, because it could close another session.

### 3.3 Dolby Vision Calman reset

`webui_lg_dv_calman_reset` — `usr/share/PGenerator/lg.pm:2692` →
`lg_dv_calman_reset_workflow` — `usr/sbin/pgenerator-lg:4318`.
Route: `POST /api/lg/dv-calman-reset` (`lg.pm:3396`).

Requires a `dolby_hdr_` calibration mode (`usr/sbin/pgenerator-lg:4326`).
Identical step list to HDR (`usr/sbin/pgenerator-lg:4364`), but:

- CAL_START may be *tolerated* when it matches the DV driver-error fingerprint
  (`lg_dv_calibration_session_rejection_is_tolerable`,
  `usr/sbin/pgenerator-lg:2676`), because that firmware continues to accept
  data commands on the same socket — `usr/sbin/pgenerator-lg:4347`.
- The gamma-enable toggles and all four `*_UI_DATA` commands are in a tolerated
  set — `usr/sbin/pgenerator-lg:4448`. Hardware-observed 2026-07-24: those
  exactly, every time, fail with errorCode 20 on DV modes while the calibration
  data below is accepted. The reset gates only on
  `BT2020_3BY3_GAMUT_DATA`, `BT2020_3D_LUT_DATA`, `1D_DPG_DATA` and
  `dynamicContrast` off.
- A `{type: "skipped"}` synthetic CAL_END is explicitly **not** an
  acknowledgement — `usr/sbin/pgenerator-lg:4429`.

### 3.4 SDR Calman reset

`webui_lg_sdr_calman_reset` — `usr/share/PGenerator/lg.pm:2729` →
`lg_sdr_calman_reset_workflow` — `usr/sbin/pgenerator-lg:4502`.

Mirrors the reference capture (`relay-20260626-212816-nosni.jsonl`), and is
structurally different from HDR/DV: the identity uploads happen **outside** the
CAL bracket.

Session 1, inside CAL_START/CAL_END (`usr/sbin/pgenerator-lg:4554`):

| Command | Value |
|---|---|
| `1D_2_2_EN` | 0 |
| `1D_0_45_EN` | 0 |
| `BRIGHTNESS_UI_DATA` | 50 |
| `CONTRAST_UI_DATA` | **85** |
| `BACKLIGHT_UI_DATA` | **80** |
| `COLOR_UI_DATA` | 50 |

Then, with no active session (`usr/sbin/pgenerator-lg:4586`):
`BT709_3D_LUT_DATA` (unity 33-cube), `1D_DPG_DATA` (unity), then
`BT709_3BY3_GAMUT_DATA` (identity).

Rejects an `hdr_`/`dolby_hdr_` calibration mode explicitly —
`usr/sbin/pgenerator-lg:4538` — so a BT.709 identity matrix cannot
short-circuit the HDR gamut.

The stated reason this workflow exists (`usr/sbin/pgenerator-lg:4494`): the
previous SDR reset only zeroed DDC arrays, which did not clear a prior HDR
cycle's BT.2020 matrix/3D LUT, so SDR DPG deltas were applied through the
BT.2020 chain and the AutoCal spun.

### 3.5 Summary of picture-control side effects

| Reset | brightness | contrast | backlight | colour | Also touched |
|---|---|---|---|---|---|
| Picture reset | 50 | 85 | 80 | 50 | all 32 reset keys + 22 WB keys + panel light + optional DDC clear |
| SDR Calman | 50 | 85 | 80 | 50 | gamma enables, BT.709 identity 3x3 / 3D LUT / 1D DPG |
| HDR Calman | 50 | **100** | **100** | 50 | gamma enables, dynamicContrast off, BT.2020 identity 3x3 / 3D LUT / 1D DPG |
| DV Calman | 50* | 100* | 100* | 50* | as HDR; *those four are tolerated-if-rejected |

---

## 4. Calibration session hold

### 4.1 Start and end

`webui_lg_calibration_mode` — `usr/share/PGenerator/lg.pm:1776` →
`lg_calibration_mode_workflow` — `usr/sbin/pgenerator-lg:7503`.
Body: `{ enabled: bool, picture_mode, signal_mode }`.

Sends `CAL_START` or `CAL_END` via `lg_calibration_request` —
`usr/sbin/pgenerator-lg:3007` — against `externalpq/setExternalPqData`. Every
externalpq command carries `picMode`, not just CAL_START (hw-verified
2026-07-23, comment at `usr/sbin/pgenerator-lg:3013`).

Wire name transformation: `lg_wire_pic_mode` — `usr/sbin/pgenerator-lg:3000` —
strips `dolby_hdr_` to `dolby_`. So calibration mode `dolby_hdr_cinema_dark`
goes on the wire as `dolby_cinema_dark`.

Calibration-mode naming: `lg_picture_mode_for_calibration` —
`usr/sbin/pgenerator-lg:2802`. Resolution entry point:
`lg_3d_lut_resolve_mode` — `usr/sbin/pgenerator-lg:3532`.

CAL_START is refused when the mode has no calibration mapping —
`usr/sbin/pgenerator-lg:7521`: *"LG calibration mode is not mapped for picture
mode 'X'. Switch to Cinema, Expert, Filmmaker, or Game."*

Confirmation predicates: `lg_calibration_start_confirmed` —
`usr/sbin/pgenerator-lg:2631`; `lg_calibration_end_confirmed` —
`usr/sbin/pgenerator-lg:3977`.

### 4.2 Persistence

Flag and mode live in the client store (`/var/lib/PGenerator/lg/clients.json`):

- `lg_store_calibration_mode_state` — `usr/share/PGenerator/lg.pm:1538`.
  Skips the write when nothing changed, because the greyscale solver uploads a
  DPG on every inner iteration.
- `lg_prepare_held_calibration_mode` — `usr/share/PGenerator/lg.pm:1557`.
  Writes the intent **before** the TV call, so a failed mid-write still leaves
  terminal cleanup and the next reset knowing CAL_END may be required. A failed
  persist aborts the write with
  `error_code => "lg-calibration-state-not-persisted"`.
- `lg_record_calibration_mode_result` — `usr/share/PGenerator/lg.pm:1568`. An
  `lg-calibration-end-unconfirmed` result is recorded as **still held**
  (`usr/share/PGenerator/lg.pm:1575`), because a write accepted on its helper
  socket with an unconfirmed CAL_END remains durably held and a later fallback
  CAL_END could revert it.

Fields: `calibration_mode` (bool), `calibration_picture_mode` (string).
`lg_mark_disconnected` — `usr/share/PGenerator/lg.pm:354` — clears them.

### 4.3 What is blocked while a session is held

**Apply-to-all-inputs.** Hard refusal at `usr/share/PGenerator/lg.pm:2073`:
`error_code => "lg-calibration-session-held"`, message *"A LG calibration
session is still held on the TV. Run Reset picture mode first, then apply to
all inputs."*

**Resets are NOT blocked.** They call
`lg_clear_stale_calibration_mode_for_reset` —
`usr/share/PGenerator/lg.pm:1623` — which attempts one CAL_END first, but a
rejected cleanup does **not** block the reset. Reasoning recorded at
`usr/share/PGenerator/lg.pm:1616`: the TV may already have dropped the session
(power cycle), and the reset's own CAL_START/CAL_END is the authority. The flag
is only cleared once the reset succeeds, so a genuinely stuck driver keeps
surfacing through the reset's error path. Non-blocking failure returns
`status: "ok"` with `error_code => "lg-calibration-session-stuck"` and
`stale_calibration_mode_cleared: false`.

### 4.4 What is blocked while an AutoCal worker is alive

`lg_autocal_worker_running` — `usr/share/PGenerator/lg.pm:1600`. Checks
`webui_meter_lg_autocal_running` and `webui_meter_lg_3d_autocal_running`.

The `$strict` parameter picks the fail direction when the liveness check itself
dies (comment at `usr/share/PGenerator/lg.pm:1601`):

- Apply-to-all-inputs passes `1` — unknown **blocks**
  (`usr/share/PGenerator/lg.pm:2066`), because the action is irreversible.
- The reset path leaves it unset — unknown **must not** lock the operator out
  of their own recovery route (`usr/share/PGenerator/lg.pm:1629`).

Both refusals use `error_code => "lg-calibration-session-active"`.

### 4.5 Terminal failsafe

`webui_lg_autocal_run_end` — `usr/share/PGenerator/lg.pm:3492` →
`lg_close_calibration_mode_at_run_end` — `usr/share/PGenerator/lg.pm:3568`.

Attempts one explicit CAL_END (75 s helper timeout) and clears the flag only
after the TV acknowledges. Refuses to close a session underneath a live worker
(`usr/share/PGenerator/lg.pm:3582`). With no paired TV available it returns
`lg-calibration-session-stuck` and tells the operator to reconnect and use
Reset Picture Mode.

Run-end also validates run ownership against `controller_id` /
`client_run_token` (`usr/share/PGenerator/lg.pm:3510`) so a delayed callback
from a stale tab cannot tear down the live run's session — it returns
`stale_run_ignored`.

### 4.6 Cross-stage hold in the workers

A full AutoCal deliberately holds CAL_START open across greyscale, 3D-LUT and
tone-map stages — comment at `usr/share/PGenerator/lg.pm:1533`. The workers
pass `keep_calibration_mode` / `calibration_mode_active` on each
`picture-settings/set` call. Worker-side state mirroring:
`set_state_calibration_mode` — `usr/bin/meter_lg_autocal.pl:12740`;
`preserve_unconfirmed_lg_calibration_session` —
`usr/bin/meter_lg_autocal.pl:12761`. 3D-LUT worker hold flags at
`usr/bin/meter_lg_3d_autocal.pl:4507`-`:5710`.

---

## 5. Apply to all inputs

### 5.1 The command

`lg_picture_apply_all_inputs_workflow` — `usr/sbin/pgenerator-lg:7413`.

Payload — `usr/sbin/pgenerator-lg:7430`:

```
{ category: "picture", settings: { applyToAllInput: "picture" } }
```

Public `settings/setSystemSettings` first (`usr/sbin/pgenerator-lg:7431`),
Luna `com.webos.settingsservice/setSystemSettings` as fallback
(`usr/sbin/pgenerator-lg:7453`).

Generation gate: `lg_apply_all_inputs_generation_support` —
`usr/sbin/pgenerator-lg:5862`. Returns 1 / 0 / -1. The key is present in the
captured C1-and-newer settings inventories and absent from C8, C9, CX
(`usr/sbin/pgenerator-lg:5853`). Support 0 → refuse with
`apply-all-inputs-unsupported`. Support -1 (unknown) → the public route may
still prove support by accepting, but the **unacknowledged Luna fallback is not
allowed**; failure yields `apply-all-inputs-support-unknown`
(`usr/sbin/pgenerator-lg:7445`).

### 5.2 What it copies

Whatever picture mode the TV is **actually** on. The workflow reads it first —
`usr/sbin/pgenerator-lg:7429`. The web UI re-reads it before naming the preset
in the irreversible-action modal — `webui-lg.js:1744` — with the comment: *"The
TV copies whatever mode it is actually on, not the dropdown's selection (stale
after a Magic Remote change)."* Falls back to the label *"the active picture
mode (the TV did not report it)"* rather than a possibly wrong one.

### 5.3 Confirmation and its exact limits

Poll parameters — `usr/sbin/pgenerator-lg:7366`:

| Parameter | Value |
|---|---|
| `$APPLY_ALL_INPUTS_POLLS` | 12 |
| `$APPLY_ALL_INPUTS_POLL_INTERVAL` | 0.5 s |
| `$APPLY_ALL_INPUTS_READBACK_SECONDS` | 8 |
| `$APPLY_ALL_INPUTS_READ_TIMEOUT` | 2 s |

Reader: `lg_apply_all_inputs_state` — `usr/sbin/pgenerator-lg:7372`, returns
`($value, $error)`.

Outcome grading: `lg_apply_all_inputs_outcome` —
`usr/sbin/pgenerator-lg:7391` (pure, unit-testable):

- `confirmed` requires `transition_seen && readback eq "done"` — that is, the
  poll must observe `"picture"` **and then** `"done"` within this dispatch.
- `acknowledged` is true only when the public route succeeded.
- A bare `"done"` is **not** proof: the key rests at `done` between runs
  (`usr/sbin/pgenerator-lg:7351`).

**The G5 limitation, verbatim from `usr/sbin/pgenerator-lg:7353`:** *"The G5
(webOS 25, 2026-08-23) refuses the read outright on both the public and the
palm:// service route ('Some keys are not allowed for the request'), so a
rejected read ends the poll at once and is reported as 'this set cannot report
it.'"* The follow-on at `usr/sbin/pgenerator-lg:7362`: another input's settings
cannot be read on these sets either — an input/pictureMode dimension is ignored
and the active values come back — so **byte-level proof of the copy is out of
reach over the network**.

The three operator messages (`usr/sbin/pgenerator-lg:7407`) distinguish
confirmed, acknowledged-but-unconfirmed, and alert-bridge-dispatched.

Result fields: `active_picture_mode`, `transport`, `acknowledged`,
`confirmed`, `readback`, `readback_error`, `transition_seen`, `lg_generation`.

### 5.4 Timeouts and UI

Helper wrapper timeout is 60 s (`usr/share/PGenerator/lg.pm:1101`) with the
message *"LG TV did not finish Apply to All Inputs within 60s."*
(`usr/share/PGenerator/lg.pm:1124`). Client timeout 75 s
(`webui-lg.js:1801`).

UI flow: `lgApplyAllInputs` (`webui-lg.js:1735`) → confirmation modal →
`lgApplyAllInputsConfirmed` (`webui-lg.js:1786`). A bare alert-bridge dispatch
is toasted as a **warning**, not a success — `webui-lg.js:1805`.

---

## 6. Does AutoCal drive OLED light / backlight toward a target luminance?

**No.** This is the clearest gap for the proposed design.

### 6.1 The negative result

A case-insensitive grep for `backlight`, `oledlight`, `oledpixel`,
`panel_light`, `peakBrightness` and `BACKLIGHT_UI_DATA` across
`usr/bin/meter_lg_autocal.pl`, `usr/bin/meter_lg_3d_autocal.pl` and
`usr/bin/meter_lg_dv_profile.pl` returns **zero matches**. Neither AutoCal
worker ever reads or writes a panel-light key.

Repo-wide, `BACKLIGHT_UI_DATA` appears only in the four reset workflows
(`usr/sbin/pgenerator-lg:2170`, `:4235`, `:4370`, `:4568`), where it is set to
a **fixed** value (80 for SDR, 100 for HDR/DV) — never dialled toward a
measurement.

### 6.2 The only picture-control write in the greyscale worker

`restore_factory_levels_for_autocal` — `usr/bin/meter_lg_autocal.pl:21588`,
called once from `usr/bin/meter_lg_autocal.pl:22105`.

Writes `contrast` (config `factory_contrast`, default 85) and `brightness`
(config `factory_brightness`, default 50) via `/api/lg/picture-settings/set`
with `readback_keys: [pictureMode, contrast, brightness]`, three attempts
(`usr/bin/meter_lg_autocal.pl:21610`).

Gated off for: non-SDR signal modes (`usr/bin/meter_lg_autocal.pl:21593`),
touch-up runs (`:21592`), and an explicit `restore_factory_levels: false`
(`:21590`).

**The web UI passes `restore_factory_levels: false` at all three call sites** —
`usr/share/PGenerator/webui-workspace.js:8890`, `:9060`, `:10061`. So in the
shipped wizard path this never runs.

### 6.3 How peak luminance is actually handled

Entirely through the 1D LUT / white-balance chain.

- `target_luminance_for_step` — `usr/bin/meter_lg_autocal.pl:1442` — derives
  each step's target from the **measured** white Y, the target gamma, the
  signal mode and the black floor.
- `target_luminance_for_autocal_step` — `usr/bin/meter_lg_autocal.pl:1899`.
- `effective_target_luminance_for_autocal_reading` —
  `usr/bin/meter_lg_autocal.pl:2171`.
- Headroom tracking: `usr/bin/meter_lg_autocal.pl:2236` and `:2294`-`:2331`,
  storing `headroom_target_luminance` in state and
  `$LG_AUTOCAL_HEADROOM_TARGET_LUMINANCE`.

The worker's only TV writes are the DDC white-balance arrays
(`lg_helper_picture_set` — `usr/bin/meter_lg_autocal.pl:353`, whose
`readback_keys` are exactly `pictureMode`, `whiteBalanceMethod`,
`whiteBalanceIre`, `whiteBalanceRed/Green/Blue`, `adjustingLuminance`) plus the
DDC-baseline clears at `usr/bin/meter_lg_autocal.pl:21668` and `:21735`, and
the 1D DPG commits.

**Implication for the design:** nothing today measures peak white, compares it
to a target, and adjusts `oledLight`. A closed loop on panel light would be new
capability. The plumbing exists (panel-light writes work, with a strict
14-attempt readback, and their own scoped-category ladder), but there is no
control loop and no worker that owns one.

---

## 7. Dolby Vision

### 7.1 What AutoCal supports for DV

**Two stages: greyscale, then panel-profile upload. There is no 3D LUT stage.**

- Stated at `usr/share/PGenerator/webui-workspace.js:8553`: *"Dolby Vision has
  no 3D LUT, so it moves into the panel-profile-upload stage instead."*
- Profiling choice is hidden for DV in the confirm dialog —
  `usr/share/PGenerator/webui-workspace.js:8218`
  (`showProfilingChoice: !hdrMatrixOnly && !dvSignal`).
- `lg_generation_profile` reports `dv_mode => "1d_only"` —
  `usr/sbin/pgenerator-lg:5903`.

DDC layout for DV is the HDR20 20-point ladder —
`usr/bin/meter_lg_autocal.pl:415` (`return "hdr20" if hdr10 or dv`).

Target gamma for DV is always 2.2 —
`usr/bin/meter_lg_autocal.pl:14518`.

CAL_START/CAL_END tolerance in the worker —
`usr/bin/meter_lg_autocal.pl:14353`: for DV, a tolerated start/end counts as
accepted.

### 7.2 The panel-profile upload

`lg_dv_profile_upload_workflow` — `usr/sbin/pgenerator-lg:5065`.
Endpoint `POST /api/lg/dv-profile/upload` → `webui_lg_dv_profile_upload` —
`usr/share/PGenerator/lg.pm:2401`.

Requires measured `white_luminance`, `black_luminance`, and `red_x/y`,
`green_x/y`, `blue_x/y` — `usr/sbin/pgenerator-lg:5071`.

Preflight: `lg_dv_profile_preflight_settings_off` —
`usr/sbin/pgenerator-lg:4154` — forces `aiPicture` and `energySaving` to `off`.
Non-fatal (`usr/sbin/pgenerator-lg:5086`), and a key the firmware genuinely
does not expose is not counted as a failure
(`lg_settings_error_is_unsupported_key`, `usr/sbin/pgenerator-lg:2689`).
Rationale at `usr/sbin/pgenerator-lg:4148`: AI Picture/AI Brightness and Energy
Saving vary backlight and tone response in ways that would corrupt the
black/white luminance measurement.

Descriptor built by `lg_dv_profile_descriptor` —
`usr/sbin/pgenerator-lg:2961`, using `lg_dv_profile_lms2rgb_matrix`
(`:2935`). Uploaded as `DOLBY_CFG_DATA` with `dataType` `"unsigned char"`
(`usr/sbin/pgenerator-lg:3055`; still unconfirmed on the wire, sourced from an
`lgrest.dll` string-table decompile).

Measuring worker: `usr/bin/meter_lg_dv_profile.pl`, uploading at line 390.

CAL bracket: skipped when the caller already holds a session
(`calibration_mode_active`, `usr/sbin/pgenerator-lg:5098`); otherwise opened
and closed here. A DV-fingerprint rejection of CAL_START or CAL_END is
tolerated (`usr/sbin/pgenerator-lg:5104`, `:5131`).

### 7.3 The Absolute map mode refusal (commit `5a7c3a2f`)

`webui_lg_autocal_dv_map_mode_error` —
`usr/share/PGenerator/webui.pm:6319`. A pure predicate: returns `""` for any
non-DV signal mode, and for DV returns `""` only when `dv_map_mode` (after
whitespace trim) equals `"2"` (Relative). Everything else — `"1"` (Absolute),
empty ("unset"), undefined, or any unexpected value — is refused.

Consulted in `webui_meter_lg_autocal_start` —
`usr/share/PGenerator/webui.pm:6359` — after the concurrency guards and before
the CEC power gate.

**Why.** DV always solves against a 2.2 target
(`lg_autocal_expected_gamma_for_signal_mode_and_ire` returns 2.2 for dv,
`usr/bin/meter_lg_autocal.pl:14518`), because the panel linearises 2.2 in
calibration mode and re-applies its own transfer when calibration mode is off.
Only Relative presents that curve; Absolute presents ST 2084.

**The measured evidence** in the commit message, from an OLED65C1PUB with the
same config and meter, only the launch path differing (`probe-read initial`
values at each anchor before calibration):

| Launch path | 100% | 20% | 40% | 60% | 80% |
|---|---|---|---|---|---|
| Web UI (x2) | 793-804 | 19.5-19.9 | 86.5-87.6 | 224-226 | 407-412 |
| API | 795 | 32.8 | 39.2 | 718 | 667 |

100% agrees to within 0.3%; 60% is out by a factor of three.

**Refusing rather than auto-switching is deliberate**: `dv_map_mode` is a
renderer restart key and the transition can take up to 25 s with nothing on
screen, which the web UI wraps in the Apply Settings modal. That is not
something to do implicitly inside a start endpoint.

Test coverage: `t/lg_autocal_dv_map_mode.t`, 14 assertions, covering Relative,
Absolute, empty, undef, unexpected values, whitespace, case, and no-opinion on
SDR/HDR10.

### 7.4 The web UI's own map-mode sequencing

`meterDvAutoCalApplyMapMode` — `usr/share/PGenerator/webui-workspace.js:8439`;
`meterDvAutoCalSetMapMode` — `:8475`.

Sequence (`usr/share/PGenerator/webui-workspace.js:8261` and `:8338`):

1. Pre-cal report → Absolute (`"1"`), target gamma `st2084`.
2. Before greyscale → Relative (`"2"`), target gamma `2.2`.
3. Post-cal report → Absolute again (`:7903`, `dvMapModeOverride`).

When the pre-cal report is skipped it goes straight to Relative
(`usr/share/PGenerator/webui-workspace.js:8280`) rather than switching twice.
A no-op guard avoids popping the Apply Settings modal when the mode is already
correct (`:8281`).

### 7.5 Other DV-specific constraints

- **Two names for one preset.** DV Filmmaker's *write* value is
  `dolbyHdrCinema` (`usr/sbin/pgenerator-lg:257`) but its *calibration wire*
  picMode is `dolby_cinema_dark` (`usr/sbin/pgenerator-lg:2876` →
  `lg_wire_pic_mode`, `:3000`). Captured DV Filmmaker calibrations used
  `dolby_cinema_dark` every time, never `dolby_film_maker`.
- **Pre-2022 label remap.** On 2019-2021 sets the dark DV reference preset is
  labelled Cinema, not Filmmaker; `lg_3d_lut_resolve_mode` remaps
  `dolbyvisioncinema`/`dolbyhdrcinema` → `dolbyVisionFilmMaker` for those
  generations only — `usr/sbin/pgenerator-lg:3542`.
- **DV Personalised Picture is not a calibration target.** Excluded at
  `usr/sbin/pgenerator-lg:2810`, alongside HDR Eco and HDR Personalised, until
  their external-PQ namespaces and persistence are hardware-validated. The
  generic Dolby fallback must not turn it into an assumed
  `dolby_hdr_personalized`.
- **Legacy DV input scope.** C2-and-earlier DV mode switching requires the
  active HDMI input scope. With no input available the select refuses
  *without writing*: `blocked_reason => "legacy-dv-input-scope-unavailable"`
  (`usr/sbin/pgenerator-lg:7235`), surfaced as
  `error_code => "picture-mode-route-unproven"` with the advice to use the
  Magic Remote (`usr/sbin/pgenerator-lg:7305`).
- **DV UI_DATA rejections are expected**, see §3.3.
- **`lg_dv_calibration_session_rejection_is_tolerable`** —
  `usr/sbin/pgenerator-lg:2676` — is the single fingerprint gate for all DV
  CAL_START/CAL_END tolerance.

---

## 8. TV-side hazards handled today

Thin coverage. This is the second significant gap.

### 8.1 What is handled

**Energy saving and AI Picture.** Forced `off` only in the DV profile
preflight — `lg_dv_profile_preflight_settings_off`,
`usr/sbin/pgenerator-lg:4154`. Not touched before a greyscale or 3D-LUT run.

`energySaving` is in the picture-reset key list
(`usr/sbin/pgenerator-lg:1475`) and in the diagnostic key list
(`usr/share/PGenerator/lg.pm:1512`), and is exposed as a manual control
(`webui-lg.js:263`, options off/minimum/medium/maximum/auto/screenOff). So a
picture reset restores it to the TV's default — it does **not** pin it off.

**Dynamic contrast.** Forced `off` in the HDR and DV Calman resets —
`lg_hdr_picture_reset_apply_dynamic_contrast_off`,
`usr/sbin/pgenerator-lg:4105`. Tries the plain payload then the full
eight-variant ladder; if every attempt returns the "doesn't support the key"
fingerprint it reports success with `skipped: true`
(`usr/sbin/pgenerator-lg:4136`) so a key the firmware does not expose cannot
abort the reset.

**Power gating.**

- `lg_cec_power_state_cached` — `usr/share/PGenerator/lg.pm:409` — reads the
  CEC power cache file written by `webui_cec_power_cache_write`
  (`usr/share/PGenerator/webui.pm:11261`) rather than calling webui.pm
  directly.
- `lg_tv_powered_off` — `usr/share/PGenerator/lg.pm:443` — true **only** on a
  fresh, unambiguous standby/off reading. `powering-on`/`powering-off` are
  transitional and deliberately not gated.
- `lg_tv_off_gate` — `usr/share/PGenerator/lg.pm:453` — returns an error
  hashref to short-circuit a **read-only** poll, or undef. The contract
  (`usr/share/PGenerator/lg.pm:454`): control actions (wake/power, pairing,
  input switching) and the whole calibration path must never be gated.
- `lg_calibration_run_active` — `usr/share/PGenerator/lg.pm:427` — suppresses
  gating entirely while `/tmp/meter_lg_autocal.json` or
  `/tmp/meter_lg_3d_autocal.json` shows `"status": "running"`, or
  `/tmp/meter_session.pid` exists. A stale CEC reading must not interrupt a
  live run.
- Only caller today: `webui_lg_picture_settings` —
  `usr/share/PGenerator/lg.pm:1848`.

**AutoCal start power check.** `usr/share/PGenerator/webui.pm:6371` — refuses
launch on `standby`, `off` or `powering-off`; fails open on unknown or
`powering-on`, with the comment that older adapters keep advisory states long
after webOS and the HDMI signal are usable, and the authenticated LG
reset/session preflight remains the authoritative launch check.

**Connect-phase timeouts.** `$MAX_CONNECT_TIMEOUT = 5` —
`usr/sbin/pgenerator-lg:289`. A powered-off LG drops SYNs rather than refusing,
so an unbounded connect runs to the kernel's `tcp_syn_retries` budget (~127 s),
consuming the whole helper wrapper and freezing the web UI's single request
thread.

### 8.2 What is NOT handled anywhere

A repo-wide grep across `usr/**/*.pl`, `*.pm`, `*.js` for
`screenSaver`, `screensaver`, `autoPowerOff`, `noSignalPowerOff`,
`pixelRefresh`, `pixel refresh`, `keepAlive`, `keepalive`, `keep-alive` returns
**nothing relevant**. The single `screensaver` hit is PGenerator's own pattern
name `$pattern_screensaver = "ScreenSaver"` at
`usr/share/PGenerator/variables.pm:236`, used only for pattern-name filtering
at `usr/share/PGenerator/command.pm:734`.

Specifically absent:

- **No auto power off / no-signal power off suppression.** Nothing disables the
  TV's 4-hour auto-off or no-signal timer before an hour-long run.
- **No screen-saver suppression.** Nothing disables or defers it.
- **No pixel-refresh handling.** No detection of, suppression of, or recovery
  from a pixel-refresh prompt or a compensation cycle mid-run.
- **No TV keep-alive.** Nothing pings the TV to keep it awake across a long
  run. The only periodic traffic is the web UI's ~30 s `picture-settings` poll
  from the AutoCal panels, which is incidental and is itself gated off when CEC
  reports standby.
- **No AI Picture / AI Brightness suppression outside the DV profile stage.**

---

## Appendix: endpoint map

From `webui_lg_api` — `usr/share/PGenerator/lg.pm:3353`:

| Route | Handler |
|---|---|
| `/api/lg/picture-settings` | `webui_lg_picture_settings` — `lg.pm:1822` |
| `/api/lg/picture-settings/set` | `webui_lg_picture_settings_set` — `lg.pm:1878` |
| `/api/lg/picture-settings/reset` | `webui_lg_picture_reset` — `lg.pm:2015` |
| `/api/lg/picture-settings/apply-all-inputs` | `webui_lg_picture_apply_all_inputs` — `lg.pm:2058` |
| `/api/lg/calibration-mode` | `webui_lg_calibration_mode` — `lg.pm:1776` |
| `/api/lg/hdr-calman-reset` | `webui_lg_hdr_calman_reset` — `lg.pm:2652` |
| `/api/lg/dv-calman-reset` | `webui_lg_dv_calman_reset` — `lg.pm:2692` |
| `/api/lg/sdr-calman-reset` | `webui_lg_sdr_calman_reset` — `lg.pm:2729` |
| `/api/lg/3d-lut/probe` | `webui_lg_3d_lut_probe` — `lg.pm:2140` |
| `/api/lg/3d-lut/upload` | `webui_lg_3d_lut_upload` — `lg.pm:2172` |
| `/api/lg/3d-lut/reset` | `webui_lg_3d_lut_reset` — `lg.pm:2219` |
| `/api/lg/hdr-tone-map/upload` | `webui_lg_hdr_tone_map_upload` — `lg.pm:2259` |
| `/api/lg/1d-dpg/read` | `webui_lg_1d_dpg_read` — `lg.pm:2309` |
| `/api/lg/1d-dpg/upload` | `webui_lg_1d_dpg_upload` — `lg.pm:2335` |
| `/api/lg/dv-profile/upload` | `webui_lg_dv_profile_upload` — `lg.pm:2401` |
| `/api/lg/autocal/run/begin` | `webui_lg_autocal_run_begin` — `lg.pm:3455` |
| `/api/lg/autocal/run/end` | `webui_lg_autocal_run_end` — `lg.pm:3492` |

Helper action dispatch: `main` — `usr/sbin/pgenerator-lg:7788`. Per-action
wrapper timeouts: `lg_helper_timeout` — `usr/share/PGenerator/lg.pm:1086`.

Diagnostic log (the goldmine for live forensics):
`$DIAG_LOG_PATH = "/var/lib/PGenerator/lg/last-write.log"` —
`usr/sbin/pgenerator-lg:2513`, capped at 131072 bytes. Written by
`diag_log_append` — `usr/sbin/pgenerator-lg:2523` — on every picture write,
mode select, reset, and apply-all dispatch.
