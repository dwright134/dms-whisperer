import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    readonly property string whispererId: "whisperer"
    readonly property string home: Quickshell.env("HOME")
    readonly property string recordingPath: "/tmp/whisperer-recording.wav"
    // Records which media players we paused (duck fallback) so we resume only those
    readonly property string duckMarkerPath: "/tmp/whisperer-ducked"
    readonly property int maxRecordSeconds: 300
    // whisper-cli CPU threads (-t)
    readonly property int transcribeThreads: 4
    // Peak level below this is treated as silence and never sent to whisper,
    // avoiding hallucinated transcripts ("Thank you." etc.) being typed
    readonly property real silenceThresholdDb: -40
    // |sample| ceiling for s16 (signed 16-bit) audio, for dBFS conversion
    readonly property int s16PeakMax: 32768

    // idle | recording | stopping | transcribing | polishing | error
    property string sttState: "idle"
    property int elapsedSeconds: 0
    property string pendingText: ""
    property var history: []
    // Whether the current recording is transcribed by an AI model (audio sent
    // to OpenRouter) instead of local whisper
    property bool aiSession: false

    // Settings (persisted via PluginService)
    property string whisperBin: home + "/.local/bin/whisper-cli"
    property string modelPath: home + "/.local/share/whisperer/models/ggml-base.en.bin"
    property string language: "en"
    property bool typeText: true
    property bool copyText: true
    property bool soundCues: true
    property var customWords: []
    property var snippets: []
    property string aiProvider: "openrouter"   // "openrouter" | "google"
    property string aiApiKey: ""               // OpenRouter key
    property string aiModel: "google/gemini-3.5-flash"
    property string googleApiKey: ""           // Google AI Studio (Gemini API) key
    property string googleModel: "gemini-2.5-flash"
    property string aiStyle: ""
    property string overlayPosition: "bottom"  // "bottom" | "top"
    property bool autoStopEnabled: false
    property int autoStopSeconds: 3
    // Remove speaker audio (music) from the recording. When PipeWire echo
    // cancellation is available it captures a cleaned virtual mic; otherwise it
    // falls back to pausing media players while recording (see aecTier below).
    property bool cancelBackgroundMusic: false

    // Background-music handling, chosen by capability (see detectAudioCleanup):
    //   "aec"  – PipeWire echo-cancel virtual source available (preferred)
    //   "duck" – no AEC, but playerctl present, so pause media while recording
    //   "none" – feature unavailable; record the raw mic exactly as before
    property string aecTier: "none"
    // The echo-cancel virtual source is confirmed present and ready to record from
    property bool aecReady: false
    // Named virtual source exposed by the echo-cancel module
    readonly property string aecSourceName: "whisperer-aec"
    // True only when we should actually capture through the cleaned source. Any
    // failure to load/confirm it leaves this false, so recording falls back to
    // the default mic — never worse than before the feature existed.
    readonly property bool aecActive: cancelBackgroundMusic && aecTier === "aec" && aecReady

    readonly property bool overlayAtTop: overlayPosition === "top"

    // Live mic level while recording: rolling buffer of 0..1 peaks (one per
    // ~100ms), newest last, drives the overlay waveform and silence auto-stop
    readonly property int waveBarCount: 22
    property var levelHistory: []
    property bool voiceHeard: false
    property real lastVoiceAt: 0
    property int levelWarmup: 0
    // Adaptive noise floor (s16 peak units): captured levels depend on the
    // source's volume, so voice is "well above the recent quiet level"
    // rather than an absolute threshold
    property real noiseFloor: 500

    readonly property string activeAiKey: aiProvider === "google" ? googleApiKey : aiApiKey
    readonly property string activeAiModel: aiProvider === "google" ? googleModel : aiModel
    // Bare model name for display (drops the "vendor/" prefix)
    readonly property string activeAiModelShort: activeAiModel.split("/").pop()

    readonly property string modelName: modelPath.split("/").pop().replace("ggml-", "").replace(".bin", "")

    // Whisper pre-flight: a local transcription needs both the whisper-cli
    // binary (executable) and the model file (readable). These are probed on
    // load and whenever settings change — never on every record click — so the
    // Record button and startRecording() gate reflect current state cheaply.
    // Until the async probe confirms them, both stay false and recording is
    // blocked, which is the safe default for a first run with nothing installed.
    property bool whisperBinReady: false
    property bool modelFileReady: false
    readonly property bool localReady: whisperBinReady && modelFileReady

    // Human-readable reason the local pipeline can't run yet ("" when ready),
    // shown in the popout and used as the blocked-start error message.
    readonly property string preflightReason: {
        if (localReady)
            return ""
        if (!whisperBinReady && !modelFileReady)
            return "whisper-cli and model not found — check paths in settings"
        if (!whisperBinReady)
            return "whisper-cli not found (or not executable): " + whisperBin
        return "model not found: " + modelPath
    }

    // test -x / -r cover "exists and executable" / "exists and readable" in one
    // call each, and are false for an empty path — no separate existence check.
    // When the stored binary path doesn't resolve, fall back to locating one on
    // PATH so a fresh install works without the user entering anything.
    function checkPreflight() {
        Proc.runCommand("whisperer.preflight.bin",
                        ["test", "-x", whisperBin],
                        (out, code) => {
                            if (code === 0) {
                                root.whisperBinReady = true
                            } else {
                                root.whisperBinReady = false
                                root.detectWhisperBin()
                            }
                        })
        Proc.runCommand("whisperer.preflight.model",
                        ["test", "-r", modelPath],
                        (out, code) => root.modelFileReady = (code === 0))
    }

    // Ask the shell where whisper.cpp lives instead of trusting the stored path.
    // whisper-cli is its current binary name; some builds ship it as
    // whisper-cpp / whisper.cpp. On a hit we adopt and persist the path — the
    // save flows back through onPluginDataChanged — and mark the binary ready.
    function detectWhisperBin() {
        Proc.runCommand("whisperer.detectBin",
                        ["sh", "-c",
                         "command -v whisper-cli || command -v whisper-cpp || command -v whisper.cpp"],
                        (out, code) => {
                            const found = (out || "").trim()
                            if (code === 0 && found.length > 0) {
                                root.whisperBinReady = true
                                if (found !== root.whisperBin) {
                                    root.whisperBin = found
                                    PluginService.savePluginData(root.whispererId, "whisperBin", found)
                                }
                            }
                        })
    }

    // Custom vocabulary + snippet triggers, cleaned: the exact terms whisper
    // and the AI prompt should bias toward. Shared by vocabPrompt (below) and
    // aiSystemPrompt().
    function vocabWords() {
        return (customWords || [])
            .map(w => typeof w === "string" ? w : (w && w.word ? w.word : ""))
            .concat((snippets || []).map(s => s && s.trigger ? s.trigger : ""))
            .map(w => w.trim())
            .filter(w => w.length > 0)
    }

    // Custom vocabulary is fed to whisper as an initial prompt, which biases
    // decoding toward these spellings (same approach as Superwhisper).
    // Snippet triggers are included so they transcribe verbatim and match.
    readonly property string vocabPrompt: {
        const words = vocabWords()
        return words.length > 0 ? "Glossary: " + words.join(", ") + "." : ""
    }

    // Overlay state
    readonly property bool overlayActive: sttState === "recording" || sttState === "stopping" || sttState === "cancelling" || sttState === "transcribing" || sttState === "polishing"
    readonly property bool overlayShown: overlayActive || doneLingerTimer.running
    property bool overlayWindowVisible: false
    property string doneKind: ""   // "ok" | "error"
    property string doneText: ""

    onOverlayShownChanged: {
        if (overlayShown) {
            overlayHideTimer.stop()
            overlayWindowVisible = true
        } else {
            overlayHideTimer.restart()
        }
    }

    function loadSettings() {
        whisperBin = PluginService.loadPluginData(whispererId, "whisperBin", home + "/.local/bin/whisper-cli")
        modelPath = PluginService.loadPluginData(whispererId, "modelPath", home + "/.local/share/whisperer/models/ggml-base.en.bin")
        language = PluginService.loadPluginData(whispererId, "language", "en")
        typeText = PluginService.loadPluginData(whispererId, "typeText", true)
        copyText = PluginService.loadPluginData(whispererId, "copyText", true)
        soundCues = PluginService.loadPluginData(whispererId, "soundCues", true)
        customWords = PluginService.loadPluginData(whispererId, "customWords", [])
        snippets = PluginService.loadPluginData(whispererId, "snippets", [])
        aiProvider = PluginService.loadPluginData(whispererId, "aiProvider", "openrouter")
        loadApiKey("aiApiKey", k => aiApiKey = k)
        aiModel = PluginService.loadPluginData(whispererId, "aiModel", "google/gemini-3.5-flash")
        loadApiKey("googleApiKey", k => googleApiKey = k)
        googleModel = PluginService.loadPluginData(whispererId, "googleModel", "gemini-2.5-flash")
        aiStyle = PluginService.loadPluginData(whispererId, "aiStyle", "")
        overlayPosition = PluginService.loadPluginData(whispererId, "overlayPosition", "bottom")
        autoStopEnabled = PluginService.loadPluginData(whispererId, "autoStopEnabled", false)
        autoStopSeconds = PluginService.loadPluginData(whispererId, "autoStopSeconds", 3)
        cancelBackgroundMusic = PluginService.loadPluginData(whispererId, "cancelBackgroundMusic", false)
        history = PluginService.loadPluginData(whispererId, "history", [])
    }

    // API keys live in the login keyring (gnome-keyring, via secret-tool), never
    // in the plugin settings JSON — that file is world-readable and is often
    // synced into a dotfiles repo. Only a boolean "<key>Set" flag is persisted.
    readonly property string keyringService: "whisperer"

    // Look a key up from the keyring; if it isn't there but an older build left
    // a plaintext copy in the JSON, migrate that copy into the keyring once.
    function loadApiKey(attr, apply) {
        Proc.runCommand("whisperer.key.load." + attr,
                        ["secret-tool", "lookup", "service", keyringService, "key", attr],
                        (out, code) => {
                            let key = code === 0 ? out.replace(/\n+$/, "") : ""
                            if (key.length === 0) {
                                const legacy = PluginService.loadPluginData(whispererId, attr, "").trim()
                                if (legacy.length > 0) {
                                    key = legacy
                                    storeApiKey(attr, legacy)
                                }
                            }
                            apply(key)
                        })
    }

    // Write a key into the keyring. The secret goes through the environment, not
    // argv, so it never appears in the process list. On success the plaintext
    // JSON copy is purged and the "<attr>Set" flag is recorded.
    function storeApiKey(attr, key) {
        const p = Qt.createQmlObject('import Quickshell.Io; Process { running: false }', root)
        p.environment = ({ "PW_SECRET": key })
        p.command = ["sh", "-c",
                     "printf %s \"$PW_SECRET\" | secret-tool store --label=\"Whisperer API key\" service \"$1\" key \"$2\"",
                     "sh", keyringService, attr]
        p.exited.connect(code => {
            if (code === 0) {
                PluginService.savePluginData(whispererId, attr, "")
                PluginService.savePluginData(whispererId, attr + "Set", true)
            }
            p.destroy()
        })
        p.running = true
    }

    Component.onCompleted: {
        loadSettings()
        detectAudioCleanup()
        checkPreflight()
    }

    // Killing the pw-cli client unloads the echo-cancel module (its lifetime is
    // tied to that connection), so tearing this Process down leaves no orphaned
    // virtual source behind. Also un-pause any media we ducked.
    Component.onDestruction: {
        aecModule.running = false
        restoreMedia()
    }

    Connections {
        target: PluginService
        function onPluginDataChanged(pluginId) {
            if (pluginId === root.whispererId) {
                root.loadSettings()
                // Re-run detection so toggling the setting live loads or unloads
                // the AEC module (and restores media if we were ducking).
                root.detectAudioCleanup()
                // Re-probe in case the binary/model path was just corrected.
                root.checkPreflight()
                if (!root.cancelBackgroundMusic)
                    root.restoreMedia()
            }
        }
    }

    // Pick the background-music strategy from what's actually available:
    // PipeWire echo cancellation if its module is installed and the daemon is
    // up, otherwise ducking media players if playerctl exists, otherwise nothing.
    // The module can live in different libdirs across distros, so glob for it.
    function detectAudioCleanup() {
        if (!cancelBackgroundMusic) {
            aecTier = "none"
            aecReady = false
            aecModule.running = false
            return
        }
        Proc.runCommand("whisperer.aec.detect",
            ["sh", "-c",
             "pw-cli info 0 >/dev/null 2>&1 || { echo none; exit 0; }; " +
             "for d in /usr/lib/pipewire-0.3 /usr/lib64/pipewire-0.3 /usr/lib/*/pipewire-0.3; do " +
             "[ -e \"$d/libpipewire-module-echo-cancel.so\" ] && { echo aec; exit 0; }; done; " +
             "command -v playerctl >/dev/null 2>&1 && echo duck || echo none"],
            (out, code) => {
                root.aecTier = (out || "").trim() || "none"
                if (root.aecTier === "aec") {
                    root.ensureAecModule()
                } else {
                    root.aecReady = false
                    aecModule.running = false
                }
            })
    }

    // Arguments for libpipewire-module-echo-cancel. monitor.mode references the
    // default sink's monitor as the far-end signal instead of creating a virtual
    // sink, so nothing about the user's playback or default devices changes. The
    // source is named (for pw-record --target) and kept virtual/non-default so it
    // never steals mic input from other apps.
    function aecModuleArgs() {
        return '{ monitor.mode = true '
             + 'source.props = { node.name = "' + aecSourceName + '" '
             + 'node.description = "Whisperer (echo-cancelled mic)" '
             + 'node.virtual = true } '
             + 'capture.props = { node.passive = true } }'
    }

    // Make sure the echo-cancel source exists, loading the module if it doesn't.
    // Called on detection and before each recording, so the source is recreated
    // after a PipeWire restart. Sets aecReady only once the node is confirmed;
    // until then aecActive stays false and recording uses the raw mic.
    function ensureAecModule() {
        if (!cancelBackgroundMusic || aecTier !== "aec")
            return
        Proc.runCommand("whisperer.aec.check",
            ["sh", "-c",
             "pw-cli ls Node 2>/dev/null | grep -q 'node.name = \"" + aecSourceName + "\"'"],
            (out, code) => {
                if (code === 0) {
                    root.aecReady = true
                } else {
                    root.aecReady = false
                    if (!aecModule.running) {
                        aecModule.running = true           // onStarted loads the module
                        aecRecheckTimer.restart()          // confirm the node appears
                    }
                }
            })
    }

    // Duck fallback: pause only the players that are currently Playing, recording
    // their names so restoreMedia resumes exactly those (never un-pausing music
    // the user had already paused). Fire-and-forget, like the sound cues.
    function duckMedia() {
        if (!(cancelBackgroundMusic && aecTier === "duck"))
            return
        Quickshell.execDetached(["sh", "-c",
            "> '" + duckMarkerPath + "'; " +
            "playerctl -l 2>/dev/null | while IFS= read -r p; do " +
            "[ \"$(playerctl -p \"$p\" status 2>/dev/null)\" = Playing ] && " +
            "{ printf '%s\\n' \"$p\" >> '" + duckMarkerPath + "'; playerctl -p \"$p\" pause; }; done"])
    }

    // Resume whatever we ducked. Idempotent — guarded by the marker file, which it
    // removes — so it's safe to call on stop, error, toggle-off, and destruction.
    function restoreMedia() {
        Quickshell.execDetached(["sh", "-c",
            "[ -f '" + duckMarkerPath + "' ] || exit 0; " +
            "while IFS= read -r p; do playerctl -p \"$p\" play 2>/dev/null; done < '" + duckMarkerPath + "'; " +
            "rm -f '" + duckMarkerPath + "'"])
    }

    function playCue(kind) {
        if (!soundCues)
            return
        const cues = {
            start: "Sounds/open.oga",
            done: "Sounds/close.oga",
            error: "Sounds/error.oga"
        }
        if (cues[kind]) {
            const path = decodeURIComponent(
                Qt.resolvedUrl(cues[kind]).toString().replace(/^file:\/\//, ""))
            Quickshell.execDetached(["pw-play", path])
        }
    }

    function toggleRecording() {
        if (sttState === "recording")
            stopRecording()
        else if (sttState === "idle" || sttState === "error")
            startRecording(false)
    }

    // AI keybind: starts an AI-transcription session; pressed mid-recording it
    // upgrades the session to AI mode and stops, so either bind can finish
    function toggleAiRecording() {
        if (sttState === "recording") {
            aiSession = true
            stopRecording()
        } else if (sttState === "idle" || sttState === "error") {
            if (activeAiKey.trim().length === 0) {
                if (typeof ToastService !== "undefined")
                    ToastService.showError("Whisperer: set an API key for the active AI provider in settings")
                startRecording(false)
            } else {
                startRecording(true)
            }
        }
    }

    function startRecording(aiEdit) {
        aiSession = aiEdit === true
        // Pre-flight gate: don't record a clip we can't transcribe. An AI
        // session with a key transcribes over the API (local whisper is only its
        // fallback), so it's allowed through; every other path — plain local
        // dictation, or an AI attempt with no key that degrades to local —
        // requires the local binary and model to be present.
        if (!(aiSession && activeAiKey.trim().length > 0) && !localReady) {
            fail(preflightReason)
            return
        }
        sttState = "recording"
        elapsedSeconds = 0
        levelHistory = new Array(waveBarCount).fill(0)
        levelWarmup = 0
        voiceHeard = false
        noiseFloor = 500
        lastVoiceAt = Date.now()
        if (cancelBackgroundMusic) {
            if (aecTier === "aec")
                ensureAecModule()   // recreate the source if a PipeWire restart dropped it
            else if (aecTier === "duck")
                duckMedia()
        }
        recorder.running = true
        playCue("start")
    }

    function handleLevel(peak) {
        // The first few chunks can carry the stream-start pop; skip them so
        // they neither jolt the waveform nor arm the auto-stop countdown
        if (levelWarmup < 3) {
            levelWarmup++
            return
        }
        // Bar height follows dB so it looks lively at any capture volume:
        // -50 dBFS (quiet) .. -10 dBFS (loud speech) maps to 0..1
        const db = 20 * Math.log10(Math.max(peak, 1) / s16PeakMax)
        levelHistory = levelHistory.slice(1).concat([Math.max(0, Math.min(1, (db + 50) / 40))])
        if (sttState !== "recording")
            return
        // Floor drops instantly on quieter samples, creeps up otherwise
        noiseFloor = peak < noiseFloor ? peak : Math.min(peak, noiseFloor * 1.02 + 2)
        if (peak > Math.max(250, noiseFloor * 3)) {
            voiceHeard = true
            lastVoiceAt = Date.now()
        } else if (autoStopEnabled && voiceHeard
                   && Date.now() - lastVoiceAt >= autoStopSeconds * 1000) {
            stopRecording()
        }
    }

    function stopRecording() {
        restoreMedia()   // resume any ducked players (no-op if we didn't duck)
        if (!recorder.running) {
            sttState = "idle"
            return
        }
        sttState = "stopping"
        // SIGINT lets pw-record finalize the WAV header
        recorder.signal(2)
    }

    // Abort the current recording without transcribing or typing anything.
    // Bound to Escape while the overlay holds focus, and exposed over IPC.
    function cancelRecording() {
        if (sttState !== "recording" && sttState !== "stopping")
            return
        restoreMedia()   // resume any ducked players
        if (recorder.running) {
            // The "cancelling" sentinel tells recorder.onExited to tear down
            // instead of transcribing (stopping) or reporting a crash (recording).
            sttState = "cancelling"
            recorder.signal(2)   // SIGINT → onExited runs finishCancel()
        } else {
            finishCancel()
        }
    }

    function finishCancel() {
        sttState = "idle"
        aiSession = false
        doneKind = "error"
        doneText = "Cancelled"
        doneLingerTimer.restart()
        playCue("error")
        // Discard the partial WAV so it can never be picked up by a later run
        Proc.runCommand("whisperer.discardRecording",
                        ["rm", "-f", recordingPath], () => {})
    }

    function fail(message) {
        restoreMedia()   // never leave media paused because a recording errored out
        console.warn("Whisperer:", message)
        sttState = "error"
        doneKind = "error"
        doneText = message
        doneLingerTimer.restart()
        playCue("error")
        if (typeof ToastService !== "undefined")
            ToastService.showError("Whisperer: " + message)
        errorResetTimer.restart()
    }

    function pushHistory(text) {
        const entries = history.slice()
        entries.unshift({ text: text, ts: Date.now() })
        if (entries.length > 20)
            entries.length = 20
        history = entries
        PluginService.savePluginData(whispererId, "history", entries)
    }

    function clearHistory() {
        history = []
        PluginService.savePluginData(whispererId, "history", [])
    }

    function noSpeech() {
        sttState = "idle"
        doneKind = "error"
        doneText = "No speech detected"
        doneLingerTimer.restart()
        // No toast — the overlay flash above already reports this.
    }

    // True if ch is a cased letter (any script), a digit, or an uncased-script
    // char (CJK etc.). Char-by-char rather than a \p{L}/\p{N} regex because
    // QML's V4 engine silently no-ops those property escapes.
    function isSpeechChar(ch) {
        return ch.toLowerCase() !== ch.toUpperCase()   // cased letter
            || (ch >= "0" && ch <= "9")                // digit
            || ch.charCodeAt(0) > 0x2E80               // CJK and other uncased scripts
    }

    // True if the string contains at least one letter (any script) or digit
    function hasSpeechChars(s) {
        for (const ch of s)
            if (isSpeechChar(ch))
                return true
        return false
    }

    // Loose comparison for spoken snippet triggers: case, punctuation, and
    // extra whitespace don't count. Non-speech chars collapse to spaces.
    function normalizePhrase(s) {
        let out = ""
        for (const ch of s.toLowerCase())
            out += isSpeechChar(ch) ? ch : " "
        return out.replace(/\s+/g, " ").trim()
    }

    function matchSnippet(text) {
        const spoken = normalizePhrase(text)
        if (spoken.length === 0)
            return null
        for (const s of (snippets || [])) {
            if (s && s.trigger && s.text && normalizePhrase(s.trigger) === spoken)
                return s
        }
        return null
    }

    function handleTranscript(rawText) {
        // Drop bracketed non-speech annotations ([BLANK_AUDIO], [MUSIC], ...)
        const text = rawText.replace(/\[[^\]]*\]/g, " ").replace(/\s+/g, " ").trim()
        // Parenthesized sound descriptions ((wind blowing), ...) don't count
        // as speech either, but are kept in the output if real words exist
        const speechOnly = text.replace(/\([^)]*\)/g, " ")
        if (!hasSpeechChars(speechOnly)) {
            sttState = "idle"
            noSpeech()
            return
        }
        sttState = "idle"
        const snippet = matchSnippet(text)
        if (snippet) {
            // literal "\n" in a snippet becomes a real newline when typed
            deliver(snippet.text.replace(/\\n/g, "\n"))
            return
        }
        deliver(text)
    }

    function deliver(text) {
        pushHistory(text)
        if (copyText)
            Quickshell.execDetached(["dms", "cl", "copy", text])
        if (typeText)
            typeOut(text, 150)
        doneKind = "ok"
        doneText = text
        doneLingerTimer.restart()
        playCue("done")
    }

    function typeOut(text, delayMs) {
        pendingText = text
        typeDelayTimer.interval = delayMs || 150
        typeDelayTimer.restart()
    }

    function openSettingsPage() {
        Quickshell.execDetached(["dms", "ipc", "call", "settings", "openWith", "plugins"])
    }

    function formatElapsed() {
        const mins = Math.floor(elapsedSeconds / 60)
        const secs = elapsedSeconds % 60
        return mins + ":" + (secs < 10 ? "0" : "") + secs
    }

    function pillIcon() {
        switch (sttState) {
        case "recording":
        case "stopping":
            return "stop_circle"
        case "transcribing":
            return "graphic_eq"
        case "polishing":
            return "auto_awesome"
        case "error":
            return "mic_off"
        default:
            return "mic"
        }
    }

    function pillColor() {
        switch (sttState) {
        case "recording":
        case "stopping":
            return Theme.error
        case "transcribing":
        case "polishing":
            return Theme.primary
        case "error":
            return Theme.warning
        default:
            return Theme.widgetIconColor
        }
    }

    function stateLabel() {
        switch (sttState) {
        case "recording":
            return "Recording · " + formatElapsed() + (aiSession ? " · AI" : "")
        case "stopping":
            return "Stopping…"
        case "transcribing":
            return "Transcribing (" + modelName + ")…"
        case "polishing":
            return "Transcribing with AI (" + activeAiModelShort + ")…"
        case "error":
            return doneText.length > 0 ? doneText : "Error"
        default:
            return "Idle"
        }
    }

    Process {
        id: recorder
        // Capture from the echo-cancelled source when it's active, otherwise the
        // default mic. aecActive already requires the source to be confirmed
        // ready, so a not-yet-warm source simply falls through to the raw mic.
        command: {
            const c = ["pw-record", "--rate", "16000", "--channels", "1", "--format", "s16"]
            if (root.aecActive)
                c.push("--target", root.aecSourceName)
            c.push(root.recordingPath)
            return c
        }
        onExited: exitCode => {
            if (root.sttState === "cancelling") {
                root.finishCancel()
            } else if (root.sttState === "stopping") {
                root.sttState = root.aiSession && root.activeAiKey.trim().length > 0 ? "polishing" : "transcribing"
                silenceCheck.running = true
            } else if (root.sttState === "recording") {
                root.fail("recorder exited unexpectedly (code " + exitCode + ")")
            }
        }
    }

    // Live level meter: a second capture stream feeds a pipeline that prints
    // one peak sample value per 100ms (800 samples at 8kHz). Killing the sh
    // wrapper orphans the pipeline briefly; it self-destructs via SIGPIPE.
    Process {
        id: levelMonitor
        running: root.sttState === "recording"
        // Meter the same source the recorder captures, so the waveform and the
        // adaptive noise-floor/auto-stop logic react to the cleaned audio rather
        // than to music the recording no longer contains.
        command: ["sh", "-c",
                  "pw-record --rate 8000 --channels 1 --format s16 " +
                  (root.aecActive ? "--target " + root.aecSourceName + " " : "") +
                  "- | od -An -v -td2 -w2 | " +
                  "awk '{v=$1<0?-$1:$1; if(v>p)p=v; if(++n>=800){print p; p=0; n=0; fflush()}}'"]
        stdout: SplitParser {
            onRead: data => root.handleLevel(parseInt(data.trim(), 10) || 0)
        }
    }

    // Owns the PipeWire echo-cancel module. pw-cli holds the module for exactly
    // as long as this client stays connected (verified: the virtual source
    // disappears the moment the client dies), so keeping this Process running
    // keeps the AEC source warm — better cancellation — and setting running=false
    // (toggle off, or Component.onDestruction) tears it down cleanly with no
    // explicit unload and no orphaned node. pw-cli keeps running after stdin EOF.
    Process {
        id: aecModule
        running: false
        command: ["pw-cli"]
        stdinEnabled: true
        onStarted: write("load-module libpipewire-module-echo-cancel " + root.aecModuleArgs() + "\n")
        onExited: exitCode => {
            root.aecReady = false
            // A PipeWire restart drops our client; re-arm if the feature still wants it.
            if (root.cancelBackgroundMusic && root.aecTier === "aec")
                aecRecheckTimer.restart()
        }
    }

    // Re-runs ensureAecModule shortly after a (re)load to flip aecReady once the
    // source node actually appears, and to reload after the client is dropped.
    Timer {
        id: aecRecheckTimer
        interval: 700
        onTriggered: root.ensureAecModule()
    }

    // Peak-level gate: silence skips transcription entirely
    Process {
        id: silenceCheck
        command: ["ffmpeg", "-hide_banner", "-i", root.recordingPath, "-af", "volumedetect", "-f", "null", "-"]
        stderr: StdioCollector {
            id: volumeOut
            waitForEnd: true
        }
        onExited: exitCode => {
            const match = volumeOut.text.match(/max_volume:\s*(-?[\d.]+)\s*dB/)
            if (exitCode === 0 && match && parseFloat(match[1]) < root.silenceThresholdDb)
                root.noSpeech()
            else if (root.sttState === "polishing")
                aiTranscriber.running = true
            else
                transcriber.running = true  // fail open: let whisper decide
        }
    }

    Process {
        id: transcriber
        command: {
            const cmd = [root.whisperBin,
                         "-m", root.modelPath,
                         "-f", root.recordingPath,
                         "-l", root.language,
                         "-t", String(root.transcribeThreads),
                         "--no-timestamps", "--no-prints", "--suppress-nst"]
            if (root.vocabPrompt.length > 0)
                cmd.push("--prompt", root.vocabPrompt, "--carry-initial-prompt")
            return cmd
        }
        stdout: StdioCollector {
            id: transcriptOut
            waitForEnd: true
        }
        stderr: StdioCollector {
            id: transcriptErr
            waitForEnd: true
        }
        onExited: exitCode => {
            if (exitCode === 0)
                root.handleTranscript(transcriptOut.text)
            else
                root.fail("whisper-cli failed (code " + exitCode + "): " + transcriptErr.text.trim().split("\n").slice(-1)[0])
        }
    }

    // AI transcription prompt: dictation rules plus the injected custom
    // vocabulary and snippet library
    function aiSystemPrompt() {
        let p = "You are a dictation engine. The user message contains an audio recording of dictated speech. "
              + "Transcribe it and output clear, well-formatted text: fix punctuation, casing, and grammar; "
              + "remove filler words, false starts, and repeated words; when the speaker corrects themselves, "
              + "keep only the corrected version; follow explicit formatting commands like 'new paragraph', "
              + "'new line', 'bullet list', or 'numbered list' instead of writing them out. When the speaker "
              + "commands a bullet list, put each item on its own line starting with '- '; for a numbered "
              + "list use '1. ', '2. ', and so on. Cues like 'next item', 'next bullet', or a spoken number "
              + "start a new item, and 'end of list' returns to normal text. Otherwise never insert paragraph "
              + "or line breaks on your own: pauses and topic changes are NOT breaks, and the whole output must "
              + "be a single line unless the speaker explicitly commands a break or a list. Preserve the meaning, tone, and "
              + "language of the speaker. Output ONLY the final text, with no preamble, quotes, or commentary."
        // Snippet triggers ride along so they transcribe verbatim and the
        // whole-dictation trigger match can fire on AI transcripts too
        const words = vocabWords()
        if (words.length > 0)
            p += "\n\nThe speaker often uses these terms; use these exact spellings when you hear them: "
               + words.join(", ") + "."
        if (aiStyle.trim().length > 0)
            p += "\n\nAdditional style instructions: " + aiStyle.trim()
        return p
    }

    // AI transcription: the WAV itself goes to an audio-capable model, which
    // transcribes and cleans up in one pass. The JSON payload is built here
    // and split around a placeholder; the shell splices the base64 audio in
    // between (base64 is JSON-safe). The key goes through the environment,
    // not argv, so it never shows up in the process list. The URL travels as
    // an argv parameter so the model name never touches the script text.
    Process {
        id: aiTranscriber
        environment: ({ "AI_API_KEY": root.activeAiKey })
        command: {
            const marker = "__PW_AUDIO_B64__"
            let payload, url, authHeader
            if (root.aiProvider === "google") {
                payload = JSON.stringify({
                    system_instruction: { parts: [{ text: root.aiSystemPrompt() }] },
                    contents: [{ parts: [
                        { inline_data: { mime_type: "audio/wav", data: marker } }
                    ] }]
                })
                url = "https://generativelanguage.googleapis.com/v1beta/models/"
                    + root.googleModel + ":generateContent"
                authHeader = " -H \"x-goog-api-key: $AI_API_KEY\""
            } else {
                payload = JSON.stringify({
                    model: root.aiModel,
                    messages: [
                        { role: "system", content: root.aiSystemPrompt() },
                        { role: "user", content: [
                            { type: "input_audio", input_audio: { data: marker, format: "wav" } }
                        ] }
                    ]
                })
                url = "https://openrouter.ai/api/v1/chat/completions"
                // X-Title: OpenRouter app attribution, usage shows per app name
                authHeader = " -H \"Authorization: Bearer $AI_API_KEY\""
                           + " -H 'X-Title: Whisperer'"
            }
            const idx = payload.indexOf(marker)
            return ["sh", "-c",
                    "{ printf %s \"$1\"; base64 -w0 \"$3\"; printf %s \"$2\"; } | " +
                    "curl -sS -f --max-time 120" +
                    " -H 'Content-Type: application/json'" +
                    authHeader +
                    " -d @- \"$4\"",
                    "whisperer",
                    payload.slice(0, idx), payload.slice(idx + marker.length),
                    root.recordingPath, url]
        }
        stdout: StdioCollector {
            id: aiOut
            waitForEnd: true
        }
        stderr: StdioCollector {
            id: aiErr
            waitForEnd: true
        }
        onExited: exitCode => {
            if (exitCode === 0) {
                try {
                    const resp = JSON.parse(aiOut.text)
                    let content = null
                    if (resp && resp.choices && resp.choices[0] && resp.choices[0].message) {
                        // OpenAI-style (OpenRouter)
                        content = resp.choices[0].message.content
                    } else if (resp && resp.candidates && resp.candidates[0]
                               && resp.candidates[0].content && resp.candidates[0].content.parts) {
                        // Gemini API
                        content = resp.candidates[0].content.parts
                            .map(p => typeof p.text === "string" ? p.text : "").join("")
                    }
                    if (typeof content === "string") {
                        // Unlike handleTranscript, keep newlines — the model's
                        // formatting is the point of this mode
                        const text = content.trim()
                        root.sttState = "idle"
                        if (!root.hasSpeechChars(text)) {
                            root.noSpeech()
                            return
                        }
                        // Snippets fire here too, but only when the entire
                        // dictation matches a trigger — never inside longer text
                        const snippet = root.matchSnippet(text)
                        root.deliver(snippet ? snippet.text.replace(/\\n/g, "\n") : text)
                        return
                    }
                } catch (e) {}
            }
            // Fall back to local whisper so the dictation isn't lost. This is a
            // recovery, not the final outcome — show it as info so we don't stack
            // a second error toast if whisper then fails via fail().
            console.warn("Whisperer: AI transcription failed:", aiErr.text.trim(), aiOut.text.slice(0, 300))
            if (typeof ToastService !== "undefined")
                ToastService.showInfo("Whisperer: AI transcription failed — falling back to whisper")
            root.sttState = "transcribing"
            transcriber.running = true
        }
    }

    // Small delay so the toggle click/hotkey is fully released before typing
    Timer {
        id: typeDelayTimer
        interval: 150
        onTriggered: typer.running = true
    }

    // Newlines are typed as Shift+Enter key events, not literal Returns:
    // wtype types "\n" as an Enter press, which submits chat-style inputs
    // mid-dictation. Shift+Enter inserts a line break in those instead.
    Process {
        id: typer
        command: ["sh", "-c",
                  'printf %s "$1" | { first=1; while IFS= read -r line || [ -n "$line" ]; do ' +
                  '[ "$first" -eq 0 ] && wtype -M shift -k Return -m shift; ' +
                  '[ -n "$line" ] && printf %s "$line" | wtype -; ' +
                  'first=0; done; }',
                  "whisperer", root.pendingText]
        onExited: exitCode => {
            if (exitCode !== 0)
                root.fail("wtype failed (code " + exitCode + ")")
        }
    }

    Timer {
        id: elapsedTimer
        interval: 1000
        repeat: true
        running: root.sttState === "recording"
        onTriggered: {
            root.elapsedSeconds++
            if (root.elapsedSeconds >= root.maxRecordSeconds)
                root.stopRecording()
        }
    }

    Timer {
        id: errorResetTimer
        interval: 5000
        onTriggered: {
            if (root.sttState === "error")
                root.sttState = "idle"
        }
    }

    Timer {
        id: doneLingerTimer
        interval: 2000
    }

    Timer {
        id: overlayHideTimer
        interval: 300
        onTriggered: {
            if (!root.overlayShown)
                root.overlayWindowVisible = false
        }
    }

    IpcHandler {
        target: "whisperer"

        function toggle(): string {
            root.toggleRecording()
            return root.sttState
        }

        function toggleAi(): string {
            root.toggleAiRecording()
            return root.sttState
        }

        function start(): string {
            if (root.sttState === "idle" || root.sttState === "error")
                root.startRecording(false)
            return root.sttState
        }

        function startAi(): string {
            if (root.sttState === "idle" || root.sttState === "error")
                root.toggleAiRecording()
            return root.sttState
        }

        function stop(): string {
            if (root.sttState === "recording")
                root.stopRecording()
            return root.sttState
        }

        function cancel(): string {
            root.cancelRecording()
            return root.sttState
        }

        function status(): string {
            return root.sttState
        }
    }

    // Speaker-style idle icon: three vertical bars, middle full height,
    // sides half height
    component WaveIcon: Item {
        id: wave
        property color barColor: Theme.widgetIconColor
        property int size: Theme.iconSize - 6
        implicitWidth: size
        implicitHeight: size
        width: implicitWidth
        height: implicitHeight

        Row {
            anchors.centerIn: parent
            spacing: Math.max(2, Math.round(wave.width * 0.15))

            Repeater {
                model: [0.5, 1.0, 0.5]

                Rectangle {
                    required property real modelData
                    width: Math.max(3, Math.round(wave.width * 0.17))
                    height: Math.max(4, Math.round(wave.height * 0.8 * modelData))
                    radius: width / 2
                    color: wave.barColor
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }
    }

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            WaveIcon {
                visible: root.sttState === "idle"
                barColor: root.pillColor()
                size: root.iconSizeLarge
                anchors.verticalCenter: parent.verticalCenter
            }

            DankIcon {
                id: hIcon
                visible: root.sttState !== "idle"
                name: root.pillIcon()
                size: root.iconSizeLarge
                color: root.pillColor()
                anchors.verticalCenter: parent.verticalCenter

                SequentialAnimation on opacity {
                    running: root.sttState === "recording"
                    loops: Animation.Infinite
                    NumberAnimation { from: 1; to: 0.35; duration: 600 }
                    NumberAnimation { from: 0.35; to: 1; duration: 600 }
                    onRunningChanged: if (!running) hIcon.opacity = 1
                }
            }

            StyledText {
                visible: root.sttState === "recording" || root.sttState === "transcribing"
                text: root.sttState === "recording" ? root.formatElapsed() : "…"
                color: root.pillColor()
                font.pixelSize: Theme.barTextSize(root.barThickness)
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXS

            WaveIcon {
                visible: root.sttState === "idle"
                barColor: root.pillColor()
                size: root.iconSizeLarge
                anchors.horizontalCenter: parent.horizontalCenter
            }

            DankIcon {
                id: vIcon
                visible: root.sttState !== "idle"
                name: root.pillIcon()
                size: root.iconSizeLarge
                color: root.pillColor()
                anchors.horizontalCenter: parent.horizontalCenter

                SequentialAnimation on opacity {
                    running: root.sttState === "recording"
                    loops: Animation.Infinite
                    NumberAnimation { from: 1; to: 0.35; duration: 600 }
                    NumberAnimation { from: 0.35; to: 1; duration: 600 }
                    onRunningChanged: if (!running) vIcon.opacity = 1
                }
            }
        }
    }

    // ── Bottom-center recording overlay (Superwhisper style) ──────────────

    PanelWindow {
        id: overlayWindow
        visible: root.overlayWindowVisible
        screen: root.parentScreen
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "quickshell:whispererOverlay"
        // Grab the keyboard only while recording so Escape can cancel; focus is
        // released the moment recording stops, well before the transcript is
        // typed, so wtype still lands in the user's window.
        WlrLayershell.keyboardFocus: root.sttState === "recording" ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        anchors.bottom: !root.overlayAtTop
        anchors.top: root.overlayAtTop
        margins.bottom: root.overlayAtTop ? 0 : 48
        margins.top: root.overlayAtTop ? 48 : 0
        implicitWidth: 360
        implicitHeight: 100

        Rectangle {
            id: overlayCard
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: root.overlayAtTop ? undefined : parent.bottom
            anchors.top: root.overlayAtTop ? parent.top : undefined
            // Slides toward the nearest screen edge while fading out
            anchors.bottomMargin: root.overlayShown ? 12 : -8
            anchors.topMargin: root.overlayShown ? 12 : -8
            width: 340
            height: 72
            radius: height / 2
            color: Theme.surfaceContainer
            border.width: 1
            border.color: Qt.alpha(root.sttState === "recording" ? Theme.error : Theme.primary, 0.35)
            opacity: root.overlayShown ? 1 : 0

            Behavior on opacity {
                NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
            }
            Behavior on anchors.bottomMargin {
                NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
            }
            Behavior on anchors.topMargin {
                NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
            }

            MouseArea {
                anchors.fill: parent
                cursorShape: root.sttState === "recording" ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: {
                    if (root.sttState === "recording")
                        root.stopRecording()
                }
            }

            // Catches Escape while the overlay owns the keyboard (recording).
            // forceActiveFocus on entry because the surface only just grabbed
            // the keyboard, so the item isn't focused yet by default.
            Item {
                id: escCatcher
                anchors.fill: parent
                focus: true
                Keys.onEscapePressed: event => {
                    root.cancelRecording()
                    event.accepted = true
                }
                Connections {
                    target: root
                    function onSttStateChanged() {
                        if (root.sttState === "recording")
                            escCatcher.forceActiveFocus()
                    }
                }
            }

            // Recording: red dot + live waveform + elapsed
            Row {
                anchors.centerIn: parent
                spacing: Theme.spacingM
                visible: root.sttState === "recording" || root.sttState === "stopping"

                Rectangle {
                    id: recDot
                    width: 12
                    height: 12
                    radius: 6
                    color: Theme.error
                    anchors.verticalCenter: parent.verticalCenter

                    SequentialAnimation on opacity {
                        running: root.sttState === "recording" && overlayWindow.visible
                        loops: Animation.Infinite
                        NumberAnimation { from: 1; to: 0.3; duration: 550 }
                        NumberAnimation { from: 0.3; to: 1; duration: 550 }
                        onRunningChanged: if (!running) recDot.opacity = 1
                    }
                }

                // Scrolling waveform of real mic levels, newest on the right
                Row {
                    id: waveform
                    spacing: 3
                    anchors.verticalCenter: parent.verticalCenter

                    Repeater {
                        model: root.waveBarCount

                        Rectangle {
                            required property int index
                            width: 4
                            height: 5 + 31 * (root.levelHistory[index] || 0)
                            radius: 2
                            color: Theme.error
                            anchors.verticalCenter: parent.verticalCenter

                            Behavior on height {
                                NumberAnimation { duration: 110; easing.type: Easing.OutQuad }
                            }
                        }
                    }
                }

                StyledText {
                    text: root.formatElapsed()
                    color: Theme.surfaceText
                    font.pixelSize: Theme.fontSizeLarge
                    font.weight: Font.Medium
                    anchors.verticalCenter: parent.verticalCenter
                }

                DankIcon {
                    visible: root.aiSession
                    name: "auto_awesome"
                    size: Theme.iconSize - 8
                    color: Theme.primary
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            // Transcribing / AI cleanup: bouncing dots + label
            Row {
                anchors.centerIn: parent
                spacing: Theme.spacingM
                visible: root.sttState === "transcribing" || root.sttState === "polishing"

                Row {
                    spacing: 5
                    anchors.verticalCenter: parent.verticalCenter

                    Repeater {
                        model: 3

                        Rectangle {
                            id: bounceDot
                            required property int index
                            width: 9
                            height: 9
                            radius: 4.5
                            color: Theme.primary
                            anchors.verticalCenter: parent.verticalCenter

                            SequentialAnimation on scale {
                                running: (root.sttState === "transcribing" || root.sttState === "polishing") && overlayWindow.visible
                                loops: Animation.Infinite
                                PauseAnimation { duration: bounceDot.index * 160 }
                                NumberAnimation { from: 1; to: 1.6; duration: 240; easing.type: Easing.OutQuad }
                                NumberAnimation { from: 1.6; to: 1; duration: 240; easing.type: Easing.InQuad }
                                PauseAnimation { duration: (2 - bounceDot.index) * 160 }
                                onRunningChanged: if (!running) bounceDot.scale = 1
                            }
                        }
                    }
                }

                StyledText {
                    text: root.sttState === "polishing"
                          ? "Transcribing with AI (" + root.activeAiModelShort + ")…"
                          : "Transcribing (" + root.modelName + ")…"
                    color: Theme.surfaceText
                    font.pixelSize: Theme.fontSizeMedium
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            // Done / error flash
            Row {
                anchors.centerIn: parent
                spacing: Theme.spacingS
                visible: !root.overlayActive && root.doneKind.length > 0

                DankIcon {
                    name: root.doneKind === "ok" ? "check_circle" : "error"
                    size: Theme.iconSize
                    color: root.doneKind === "ok" ? Theme.primary : Theme.warning
                    anchors.verticalCenter: parent.verticalCenter
                }

                StyledText {
                    text: root.doneText
                    color: Theme.surfaceText
                    font.pixelSize: Theme.fontSizeMedium
                    width: Math.min(implicitWidth, 250)
                    wrapMode: Text.Wrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            // Cancel hint, tucked against the bottom edge while recording
            StyledText {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 5
                text: "Esc to cancel · click or keybind to finish"
                font.pixelSize: Theme.fontSizeSmall - 1
                color: Theme.surfaceVariantText
                opacity: 0.7
                visible: root.sttState === "recording"
            }
        }
    }

    // Right-click the pill is a quick toggle for local dictation. Left-click is
    // left as the default (open the popout) on purpose: left-clicking a status
    // pill to open its popout is muscle memory, so binding recording to it caused
    // accidental recordings — right-click isn't a reflexive gesture, so it's safe.
    pillRightClickAction: () => root.toggleRecording()

    // ── Popout: status, actions, transcript history ────────────────────────

    popoutWidth: 380
    popoutHeight: 460

    popoutContent: Component {
        PopoutComponent {
            id: popoutRoot
            headerText: "Whisperer"
            detailsText: "Local dictation · " + root.modelName + " · Record below, IPC, or a keybind"
            showCloseButton: true

            // Re-probe each time the popout opens, so a binary/model installed
            // after startup (without touching settings) is picked up and the
            // Record button ungates without a restart. parentPopout is wired by
            // the popout Loader once this content is loaded.
            Connections {
                target: popoutRoot.parentPopout
                function onShouldBeVisibleChanged() {
                    if (popoutRoot.parentPopout && popoutRoot.parentPopout.shouldBeVisible)
                        root.checkPreflight()
                }
            }

            headerActions: Component {
                Row {
                    spacing: Theme.spacingXS

                    DankActionButton {
                        iconName: "settings"
                        iconColor: Theme.surfaceVariantText
                        buttonSize: 28
                        tooltipText: "Settings & models"
                        tooltipSide: "bottom"
                        onClicked: {
                            popoutRoot.closePopout()
                            root.openSettingsPage()
                        }
                    }

                    DankActionButton {
                        iconName: "delete_sweep"
                        iconColor: Theme.surfaceVariantText
                        buttonSize: 28
                        tooltipText: "Clear history"
                        tooltipSide: "bottom"
                        onClicked: root.clearHistory()
                    }
                }
            }

            Column {
                width: parent.width
                spacing: Theme.spacingM

                // Recording control card
                StyledRect {
                    width: parent.width
                    height: 64
                    radius: Theme.cornerRadius
                    color: Theme.surfaceContainerHigh

                    Column {
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.spacingM
                        anchors.right: recControls.left
                        anchors.rightMargin: Theme.spacingM
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 1

                        StyledText {
                            width: parent.width
                            elide: Text.ElideRight
                            text: root.stateLabel()
                            font.weight: Font.Medium
                            color: root.pillColor()
                        }

                        StyledText {
                            width: parent.width
                            elide: Text.ElideRight
                            // Surface the pre-flight problem when idle so the user
                            // sees why Record is disabled without recording first.
                            text: (root.sttState === "idle" && !root.localReady)
                                  ? root.preflightReason
                                  : (root.aiSession ? ("AI · " + root.activeAiModelShort) : ("Local · " + root.modelName))
                            font.pixelSize: Theme.fontSizeSmall
                            color: (root.sttState === "idle" && !root.localReady)
                                   ? Theme.warning : Theme.surfaceVariantText
                        }
                    }

                    Row {
                        id: recControls
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.spacingM
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.spacingS

                        DankButton {
                            text: root.sttState === "recording" ? "Stop" : "Record"
                            iconName: root.sttState === "recording" ? "stop" : "mic"
                            backgroundColor: root.sttState === "recording" ? Theme.error : Theme.primary
                            buttonHeight: 36
                            // Local dictation needs the whisper pipeline; Stop is
                            // always allowed so an in-flight recording can end.
                            enabled: root.sttState === "recording" || root.localReady
                            onClicked: root.toggleRecording()
                        }

                        DankActionButton {
                            iconName: "auto_awesome"
                            tooltipText: root.sttState === "recording"
                                         ? "Stop & transcribe with AI"
                                         : (root.localReady || root.activeAiKey.trim().length > 0
                                            ? "Record with AI transcription"
                                            : root.preflightReason)
                            tooltipSide: "bottom"
                            buttonSize: 36
                            // AI needs either a key (API transcription) or the
                            // local pipeline (its fallback) to be viable.
                            enabled: root.sttState === "recording" || root.localReady || root.activeAiKey.trim().length > 0
                            onClicked: root.toggleAiRecording()
                        }
                    }
                }

                // Discoverability: right-click-to-dictate isn't an obvious gesture
                // on a status pill, so spell it out. Hidden while active so it
                // doesn't distract mid-recording.
                Row {
                    width: parent.width
                    spacing: Theme.spacingXS
                    visible: !root.overlayActive

                    DankIcon {
                        id: hintIcon
                        name: "mouse"
                        size: Theme.fontSizeSmall + 2
                        color: Theme.surfaceVariantText
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    StyledText {
                        width: parent.width - hintIcon.width - parent.spacing
                        text: "Tip: right-click the pill to dictate without opening this"
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        wrapMode: Text.WordWrap
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                StyledText {
                    text: "Recent transcripts (click to copy)"
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    visible: root.history.length > 0
                }

                StyledRect {
                    width: parent.width
                    height: 296
                    radius: Theme.cornerRadius
                    color: Theme.surfaceContainerHigh

                    StyledText {
                        visible: root.history.length === 0
                        anchors.centerIn: parent
                        width: parent.width - Theme.spacingXL * 2
                        horizontalAlignment: Text.AlignHCenter
                        text: "No transcripts yet — hit the mic and start talking."
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        wrapMode: Text.Wrap
                    }

                    ListView {
                        anchors.fill: parent
                        anchors.margins: Theme.spacingS
                        clip: true
                        spacing: Theme.spacingXS
                        model: root.history

                        delegate: Rectangle {
                            required property var modelData
                            required property int index

                            width: ListView.view.width
                            height: entryColumn.implicitHeight + Theme.spacingM
                            radius: Theme.cornerRadius
                            color: entryArea.containsMouse ? Theme.surfaceContainerHighest : "transparent"

                            MouseArea {
                                id: entryArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    Quickshell.execDetached(["dms", "cl", "copy", modelData.text])
                                    if (typeof ToastService !== "undefined")
                                        ToastService.showInfo("Copied to clipboard")
                                }
                            }

                            Column {
                                id: entryColumn
                                anchors.left: parent.left
                                anchors.right: retypeButton.left
                                anchors.leftMargin: Theme.spacingM
                                anchors.rightMargin: Theme.spacingS
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 2

                                StyledText {
                                    width: parent.width
                                    text: modelData.text
                                    color: Theme.surfaceText
                                    font.pixelSize: Theme.fontSizeSmall
                                    wrapMode: Text.Wrap
                                    maximumLineCount: 2
                                    elide: Text.ElideRight
                                }

                                StyledText {
                                    text: Qt.formatDateTime(new Date(modelData.ts), "hh:mm · MMM d")
                                    color: Theme.surfaceVariantText
                                    font.pixelSize: Theme.fontSizeSmall - 1
                                }
                            }

                            DankActionButton {
                                id: retypeButton
                                iconName: "keyboard"
                                tooltipText: "Type at cursor"
                                buttonSize: 30
                                anchors.right: parent.right
                                anchors.rightMargin: Theme.spacingS
                                anchors.verticalCenter: parent.verticalCenter
                                onClicked: {
                                    popoutRoot.closePopout()
                                    // give focus time to return to the previous window
                                    root.typeOut(modelData.text, 450)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
