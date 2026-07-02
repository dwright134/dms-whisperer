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

    readonly property string whispererId: "penguinWhisperer"
    readonly property string home: Quickshell.env("HOME")
    readonly property string recordingPath: "/tmp/penguin-whisperer-recording.wav"
    readonly property int maxRecordSeconds: 300
    // Peak level below this is treated as silence and never sent to whisper,
    // avoiding hallucinated transcripts ("Thank you." etc.) being typed
    readonly property real silenceThresholdDb: -40

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
    property string modelPath: home + "/.local/share/penguin-whisperer/models/ggml-base.en.bin"
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

    readonly property string modelName: modelPath.split("/").pop().replace("ggml-", "").replace(".bin", "")

    // Custom vocabulary is fed to whisper as an initial prompt, which biases
    // decoding toward these spellings (same approach as Superwhisper).
    // Snippet triggers are included so they transcribe verbatim and match.
    readonly property string vocabPrompt: {
        const words = (customWords || [])
            .map(w => typeof w === "string" ? w : (w && w.word ? w.word : ""))
            .concat((snippets || []).map(s => s && s.trigger ? s.trigger : ""))
            .map(w => w.trim())
            .filter(w => w.length > 0)
        return words.length > 0 ? "Glossary: " + words.join(", ") + "." : ""
    }

    // Overlay state
    readonly property bool overlayActive: sttState === "recording" || sttState === "stopping" || sttState === "transcribing" || sttState === "polishing"
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
        modelPath = PluginService.loadPluginData(whispererId, "modelPath", home + "/.local/share/penguin-whisperer/models/ggml-base.en.bin")
        language = PluginService.loadPluginData(whispererId, "language", "en")
        typeText = PluginService.loadPluginData(whispererId, "typeText", true)
        copyText = PluginService.loadPluginData(whispererId, "copyText", true)
        soundCues = PluginService.loadPluginData(whispererId, "soundCues", true)
        customWords = PluginService.loadPluginData(whispererId, "customWords", [])
        snippets = PluginService.loadPluginData(whispererId, "snippets", [])
        aiProvider = PluginService.loadPluginData(whispererId, "aiProvider", "openrouter")
        aiApiKey = PluginService.loadPluginData(whispererId, "aiApiKey", "")
        aiModel = PluginService.loadPluginData(whispererId, "aiModel", "google/gemini-3.5-flash")
        googleApiKey = PluginService.loadPluginData(whispererId, "googleApiKey", "")
        googleModel = PluginService.loadPluginData(whispererId, "googleModel", "gemini-2.5-flash")
        aiStyle = PluginService.loadPluginData(whispererId, "aiStyle", "")
        overlayPosition = PluginService.loadPluginData(whispererId, "overlayPosition", "bottom")
        autoStopEnabled = PluginService.loadPluginData(whispererId, "autoStopEnabled", false)
        autoStopSeconds = PluginService.loadPluginData(whispererId, "autoStopSeconds", 3)
        history = PluginService.loadPluginData(whispererId, "history", [])
    }

    Component.onCompleted: loadSettings()

    Connections {
        target: PluginService
        function onPluginDataChanged(pluginId) {
            if (pluginId === root.whispererId)
                root.loadSettings()
        }
    }

    function playCue(kind) {
        if (!soundCues)
            return
        const cues = {
            start: "/usr/share/sounds/freedesktop/stereo/message-new-instant.oga",
            done: "/usr/share/sounds/freedesktop/stereo/complete.oga",
            error: "/usr/share/sounds/freedesktop/stereo/dialog-error.oga"
        }
        if (cues[kind])
            Quickshell.execDetached(["pw-play", cues[kind]])
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
                    ToastService.showError("Penguin Whisperer: set an API key for the active AI provider in settings")
                startRecording(false)
            } else {
                startRecording(true)
            }
        }
    }

    function startRecording(aiEdit) {
        aiSession = aiEdit === true
        sttState = "recording"
        elapsedSeconds = 0
        levelHistory = new Array(waveBarCount).fill(0)
        levelWarmup = 0
        voiceHeard = false
        noiseFloor = 500
        lastVoiceAt = Date.now()
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
        const db = 20 * Math.log10(Math.max(peak, 1) / 32768)
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
        if (!recorder.running) {
            sttState = "idle"
            return
        }
        sttState = "stopping"
        // SIGINT lets pw-record finalize the WAV header
        recorder.signal(2)
    }

    function fail(message) {
        console.warn("PenguinWhisperer:", message)
        sttState = "error"
        doneKind = "error"
        doneText = message
        doneLingerTimer.restart()
        playCue("error")
        if (typeof ToastService !== "undefined")
            ToastService.showError("Penguin Whisperer: " + message)
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
        if (typeof ToastService !== "undefined")
            ToastService.showInfo("Penguin Whisperer: no speech detected")
    }

    // True if the string contains at least one letter (any script) or digit
    function hasSpeechChars(s) {
        for (const ch of s) {
            if (ch.toLowerCase() !== ch.toUpperCase())
                return true
            if (ch >= "0" && ch <= "9")
                return true
            if (ch.charCodeAt(0) > 0x2E80)  // CJK and other uncased scripts
                return true
        }
        return false
    }

    // Loose comparison for spoken snippet triggers: case, punctuation, and
    // extra whitespace don't count. Char-by-char like hasSpeechChars because
    // QML's V4 engine silently no-ops \p{L}/\p{N} regex property escapes.
    function normalizePhrase(s) {
        let out = ""
        for (const ch of s.toLowerCase()) {
            const isLetter = ch.toLowerCase() !== ch.toUpperCase()
            const isDigit = ch >= "0" && ch <= "9"
            const isUncased = ch.charCodeAt(0) > 0x2E80  // CJK etc.
            out += (isLetter || isDigit || isUncased) ? ch : " "
        }
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
            return Theme.surfaceText
        }
    }

    Process {
        id: recorder
        command: ["pw-record", "--rate", "16000", "--channels", "1", "--format", "s16", root.recordingPath]
        onExited: exitCode => {
            if (root.sttState === "stopping") {
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
        command: ["sh", "-c",
                  "pw-record --rate 8000 --channels 1 --format s16 - | od -An -v -td2 -w2 | " +
                  "awk '{v=$1<0?-$1:$1; if(v>p)p=v; if(++n>=800){print p; p=0; n=0; fflush()}}'"]
        stdout: SplitParser {
            onRead: data => root.handleLevel(parseInt(data.trim(), 10) || 0)
        }
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
                         "-t", "4",
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
        const words = (customWords || [])
            .map(w => typeof w === "string" ? w : (w && w.word ? w.word : ""))
            .concat((snippets || []).map(s => s && s.trigger ? s.trigger : ""))
            .map(w => w.trim())
            .filter(w => w.length > 0)
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
                           + " -H 'X-Title: Penguin Whisperer'"
            }
            const idx = payload.indexOf(marker)
            return ["sh", "-c",
                    "{ printf %s \"$1\"; base64 -w0 \"$3\"; printf %s \"$2\"; } | " +
                    "curl -sS -f --max-time 120" +
                    " -H 'Content-Type: application/json'" +
                    authHeader +
                    " -d @- \"$4\"",
                    "penguin-whisperer",
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
            // Fall back to local whisper so the dictation isn't lost
            console.warn("PenguinWhisperer: AI transcription failed:", aiErr.text.trim(), aiOut.text.slice(0, 300))
            if (typeof ToastService !== "undefined")
                ToastService.showError("Penguin Whisperer: AI transcription failed — falling back to whisper")
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
                  "penguin-whisperer", root.pendingText]
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
        target: "penguinWhisperer"

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

        function status(): string {
            return root.sttState
        }
    }

    // Speaker-style idle icon: three vertical bars, middle full height,
    // sides half height
    component WaveIcon: Item {
        id: wave
        property color barColor: Theme.surfaceText
        implicitWidth: Theme.iconSize - 6
        implicitHeight: Theme.iconSize - 6
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
                    height: Math.max(4, Math.round(wave.height * 0.95 * modelData))
                    radius: width / 2
                    color: wave.barColor
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }
    }

    pillClickAction: () => root.toggleRecording()

    // triggerPopout() routes into pillClickAction when set, so blank it
    // for the duration of the call to reach the plugin-popout path
    pillRightClickAction: () => {
        const saved = root.pillClickAction
        root.pillClickAction = null
        root.triggerPopout()
        root.pillClickAction = saved
    }

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            WaveIcon {
                visible: root.sttState === "idle"
                barColor: root.pillColor()
                anchors.verticalCenter: parent.verticalCenter
            }

            DankIcon {
                id: hIcon
                visible: root.sttState !== "idle"
                name: root.pillIcon()
                size: Theme.iconSize - 6
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
                font.pixelSize: Theme.fontSizeMedium
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
                anchors.horizontalCenter: parent.horizontalCenter
            }

            DankIcon {
                id: vIcon
                visible: root.sttState !== "idle"
                name: root.pillIcon()
                size: Theme.iconSize - 6
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
        WlrLayershell.namespace: "quickshell:penguinWhispererOverlay"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

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
                          ? "Transcribing with AI (" + root.activeAiModel.split("/").pop() + ")…"
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
        }
    }

    // ── Popout: status, actions, transcript history ────────────────────────

    popoutWidth: 380
    popoutHeight: 460

    popoutContent: Component {
        PopoutComponent {
            id: popoutRoot
            headerText: "Penguin Whisperer"
            detailsText: "Local dictation · " + root.modelName + " · Mod+Shift+D / Mod+Shift+A (AI)"
            showCloseButton: true

            Column {
                width: parent.width
                spacing: Theme.spacingM

                Row {
                    spacing: Theme.spacingS

                    DankButton {
                        text: root.sttState === "recording" ? "Stop & transcribe" : "Start recording"
                        iconName: root.sttState === "recording" ? "stop" : "mic"
                        backgroundColor: root.sttState === "recording" ? Theme.error : Theme.primary
                        onClicked: root.toggleRecording()
                    }

                    DankActionButton {
                        iconName: "auto_awesome"
                        tooltipText: root.sttState === "recording" ? "Stop & transcribe with AI" : "Record with AI transcription"
                        buttonSize: 40
                        anchors.verticalCenter: parent.verticalCenter
                        onClicked: root.toggleAiRecording()
                    }

                    DankActionButton {
                        iconName: "settings"
                        tooltipText: "Settings & models"
                        buttonSize: 40
                        anchors.verticalCenter: parent.verticalCenter
                        onClicked: {
                            popoutRoot.closePopout()
                            root.openSettingsPage()
                        }
                    }

                    DankActionButton {
                        iconName: "delete_sweep"
                        tooltipText: "Clear history"
                        buttonSize: 40
                        anchors.verticalCenter: parent.verticalCenter
                        onClicked: root.clearHistory()
                    }
                }

                StyledText {
                    text: root.history.length > 0 ? "Recent transcripts (click to copy)" : "No transcripts yet — hit the mic and start talking."
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }

                ListView {
                    width: parent.width
                    height: 280
                    clip: true
                    spacing: Theme.spacingXS
                    model: root.history

                    delegate: Rectangle {
                        required property var modelData
                        required property int index

                        width: ListView.view.width
                        height: entryColumn.implicitHeight + Theme.spacingM
                        radius: Theme.cornerRadius
                        color: entryArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh

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
