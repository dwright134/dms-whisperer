# Proposal: focus-aware typing (skip wtype when no text field is focused)

**Status:** investigated & prototyped, not built. 2026-07-10.

## Pain point

Whisperer types the transcript at whatever has keyboard focus. When the focused
window has **no active text field**, wtype's synthetic keystrokes land as
keyboard shortcuts instead of text. Real incident: dictating with Firefox
focused but no field active — the transcript triggered a cascade of Firefox
shortcuts (`/` opens quick-find, `'` link-find, space scrolls, …). Terminals
are immune by nature (everything is input), but browsers, media players, games,
and file managers all interpret bare letters as commands.

A per-app blocklist does **not** fix this: Firefox is a legitimate dictation
target when a field *is* focused. The signal needed is "is a text field focused
right now?", not "which app is focused?".

## Findings (verified on niri, 2026-07-10)

The Wayland `text-input-v3` / `input-method-v2` protocol pair carries exactly
this signal: when a text field gains/loses focus, the app tells the compositor,
and the compositor forwards `activate`/`deactivate` events to the seat's
**input method** (this is how on-screen keyboards know when to pop up). A
dependency-free Python prototype that binds `zwp_input_method_v2` and logs
events ([`textinput-monitor-prototype.py`](textinput-monitor-prototype.py))
confirmed, live:

- **Firefox** reports field focus precisely: `ACTIVATE` (+`surrounding_text`,
  `content_type`) on clicking into a text box, `deactivate` on clicking a
  fieldless part of the page. The incident case is cleanly detectable.
- **ghostty** activates text-input when the terminal gains focus, so terminal
  dictation is *not* a false negative (at least for ghostty; other terminals
  vary — alacritty/xterm/Xwayland apps may never activate).
- **niri exposes** `zwp_input_method_manager_v2` + `zwp_text_input_manager_v3`
  (dumped from the registry; no `wayland-info` needed).

Hard-won protocol constraints (Smithay `input_method_handle.rs`, confirmed
empirically):

1. **No state replay on bind.** activate/deactivate are only sent on
   *transitions*. A one-shot probe at typing time always reads "inactive" —
   the monitor must be a **persistent listener** that tracks changes and
   remembers the latest state.
2. **The newest binding wins the seat.** Binding kicks the previous input
   method off (it gets `unavailable`). So the monitor must **refuse to start
   when a real IME (fcitx5/ibus) is running** — otherwise it silently breaks
   CJK input — and must go inert (report "unknown", stop rebinding) if an IME
   binds later and kicks *it*.

## Proposed design

Opt-in toggle, default **off**: “Only type into text fields”.

- **Monitor helper** (`textinput-monitor.py`, stdlib-only Python, shipped in
  the repo): persistent listener that writes `active` / `inactive` / `unknown`
  atomically to `$XDG_RUNTIME_DIR/whisperer-textinput-state` on every change.
  - `flock` on a runtime lockfile so multi-monitor widget instances share one
    binder — losers sleep and retry, so the survivor takes over if the owner's
    instance unloads.
  - Startup guard: if fcitx5/ibus-daemon is running → write `unknown`, idle.
  - On `unavailable` (an IME bound later) → write `unknown`, idle. Never rebind.
  - Spawned by each widget instance (`Process { running: <toggle enabled> }`);
    dies with the plugin.
- **Type-time gate** in `deliver()`/`typeOut()` (Whisperer.qml):
  - state `active` → type (positive signal, trumps everything).
  - state `inactive` → consult the focused app (Quickshell's
    `ToplevelManager.activeToplevel.appId`, compositor-agnostic via
    foreign-toplevel — verified available in `Quickshell.Wayland`): app in the
    user's **“always type into these apps”** list → type; otherwise **skip
    wtype**, keep clipboard + history, and show the overlay as
    “copied — no text field focused in <app-id>” so the skip is never silent
    and users learn what to add to the exception list.
  - state `unknown` / file missing / helper dead → type (today's behavior;
    zero regression when the feature can't work).
- **Settings** (WhispererSettings.qml): the toggle (visible only when “Type at
  cursor” is on) + a `ListSettingWithInput` for the always-type app-ids,
  default empty.
- **README**: feature section incl. the IME caveat and the python3 dependency
  (optional — only this feature needs it).

## Degradation matrix

| Environment | Behavior |
|---|---|
| niri, no IME (the tested setup) | full feature |
| compositor without `input-method-v2` | `unknown` → always type |
| fcitx5 / ibus running | monitor stays inert → always type |
| app without text-input support, focused | `inactive` → exception list or skip-with-notice |
| helper crashed / python3 missing | `unknown` / no file → always type |

## Open questions

- Coverage survey: which of the other common dictation targets activate
  text-input (kitty, foot, alacritty, wezterm, Discord/Electron, LibreOffice,
  Xwayland apps)? Determines how much the exception list is needed in practice.
- Hyprland/sway behavior of the same protocol pair (both implement it; replay
  and kick semantics may differ subtly).
- Should the overlay “skipped” notice offer a one-click “type anyway”
  (re-deliver pendingText) for false negatives?
- Race: focus can change between the state-file read and wtype starting
  (~150 ms type delay). Acceptable, or re-read after the delay timer?

## Effort

Roughly: monitor script ~130 lines (prototype already validates the wire
protocol), QML gate + settings ~80 lines, README. The prototype in this
directory proves the risky part end-to-end.
