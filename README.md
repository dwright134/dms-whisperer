# Penguin Whisperer

A minimal Linux take on [Superwhisper](https://superwhisper.com): push-to-talk dictation that
records your voice, transcribes it **locally** with whisper.cpp, and types the result wherever
your cursor is focused (plus copies it to the clipboard).

Built as a [DankMaterialShell](https://danklinux.com) (quickshell) bar-widget plugin for
niri/Wayland. Internal use; targets this machine's setup.

## How it works

```
Mod+Shift+D / click mic pill
  → pw-record (PipeWire, 16kHz mono WAV → /tmp)
  → whisper-cli (whisper.cpp, local ggml model)
  → wtype (types transcript at focused cursor)
  + dms cl copy (clipboard)
```

## Features

- **Bar pill**: speaker bars (idle; three vertical bars, tall middle) → red pulsing stop icon +
  elapsed (recording) → waveform + "…" (transcribing). Left-click toggles recording;
  right-click opens the popout.
- **Bottom-center overlay** (Superwhisper style): animated waveform + elapsed while recording
  (click it to stop), bouncing dots while transcribing, transcript preview flash when done.
- **Popout** (right-click the pill): record/stop button, last 20 transcripts (click to copy,
  keyboard icon to re-type at cursor), clear history, open settings.
- **Settings → Plugins → Penguin Whisperer**: model manager (download/delete/select tiny.en,
  base.en, small.en, small multilingual, medium.en straight from Hugging Face with progress),
  language (en/auto), type-at-cursor / clipboard / sound-cue toggles, whisper-cli path.
- **Sound cues**: freedesktop chimes on start / done / error (toggleable).
- **Keybind**: `Mod+Shift+D` → toggle dictation (in `~/.config/niri/dms/binds.kdl`).
- **IPC**: `dms ipc call penguinWhisperer toggle|start|stop|status`.
- Recording auto-stops after 5 minutes.

## Layout

- `PenguinWhisperer/` — the DMS plugin (symlinked into `~/.config/DankMaterialShell/plugins/`)
  - `plugin.json` — manifest
  - `PenguinWhisperer.qml` — bar widget, state machine, overlay window, popout
  - `PenguinWhispererSettings.qml` — settings UI + model manager
- `vendor/whisper.cpp/` — whisper.cpp source + build (not tracked in git)

## Installed pieces

- `~/.local/bin/whisper-cli` — CPU build of whisper.cpp (AVX2/FMA)
- `~/.local/share/penguin-whisperer/models/` — ggml models (base.en default, tiny.en fast)
- `~/.config/niri/dms/binds.kdl` — holds the Mod+Shift+D bind (note: DMS-managed file;
  re-add the bind if DMS ever regenerates it)

## Rebuilding whisper-cli

```fish
cmake -S vendor/whisper.cpp -B vendor/whisper.cpp/build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF
ninja -C vendor/whisper.cpp/build whisper-cli
cp vendor/whisper.cpp/build/bin/whisper-cli ~/.local/bin/
```

## Debugging

```fish
qs list --all                      # find the shell instance
qs log -i <instance-id> | grep -i penguin
dms ipc call penguinWhisperer status
```
