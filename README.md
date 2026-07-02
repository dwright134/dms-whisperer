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
  custom vocabulary, language (en/auto), type-at-cursor / clipboard / sound-cue toggles,
  whisper-cli path.
- **Custom vocabulary**: add names, jargon, and tricky spellings in settings; they're passed
  to whisper as an initial prompt (`--prompt` + `--carry-initial-prompt`) to bias decoding
  toward the right spellings. Keep the list to a few dozen entries — the prompt is capped at
  ~224 tokens and biasing weakens as it grows.
- **Voice snippets**: define trigger phrase → full text pairs in settings. Local (whisper)
  dictation only: the expansion is typed when the *entire* dictation matches a trigger phrase
  (ignoring the case/punctuation whisper adds) — triggers inside longer sentences are left
  alone, and snippets play no part in AI mode. Triggers are fed into whisper's vocabulary
  prompt so they transcribe reliably. `\n` in the expansion becomes a real newline.
- **AI transcription** (`Mod+Shift+A`): the audio recording itself is sent (base64, in-memory
  pipe) to an audio-capable model, which transcribes *and* formats in one pass — fillers/false
  starts removed, self-corrections applied, "new paragraph"-style commands honored, newlines
  preserved. The custom vocabulary is injected into the prompt so jargon is spelled right
  without whisper in the loop (snippets are local-mode only). Two providers, configured in
  tabs in settings with an "active provider" selector:
  - **OpenRouter** — model dropdown fetched live from the catalog, filtered to audio-input
    models (default `google/gemini-3.5-flash`). Requests carry `X-Title: Penguin Whisperer`
    so a shared key shows usage per app.
  - **Google (Gemini API)** — free-tier friendly; key from aistudio.google.com/apikey, model
    dropdown fetched from the account's catalog once a key is set (default
    `gemini-2.5-flash`).

  Pressing `Mod+Shift+A` while already recording upgrades that recording to AI mode. On any
  API failure it falls back to local whisper so the dictation isn't lost. Keys are passed to
  curl via the environment, never argv.
- **Sound cues**: freedesktop chimes on start / done / error (toggleable).
- **Silence gate**: if the recording's peak level is below -40 dB, transcription is skipped
  entirely (no whisper hallucinations typed into the focused window). Non-speech tokens are
  also suppressed (`--suppress-nst`) and bracketed annotations scrubbed; output with no real
  words is dropped.
- **Keybinds**: `Mod+Shift+D` → toggle dictation, `Mod+Shift+A` → toggle AI-cleanup dictation
  (in `~/.config/niri/dms/binds.kdl`).
- **IPC**: `dms ipc call penguinWhisperer toggle|toggleAi|start|startAi|stop|status`.
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
