import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: settingsRoot
    pluginId: "penguinWhisperer"

    readonly property string home: Quickshell.env("HOME")
    readonly property string modelsDir: home + "/.local/share/penguin-whisperer/models"
    readonly property string hfBase: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/"

    readonly property var catalog: [
        { name: "tiny.en", desc: "Fastest, lower accuracy", mb: 75, bytes: 77704715 },
        { name: "base.en", desc: "Good balance (default)", mb: 142, bytes: 147964211 },
        { name: "small.en", desc: "More accurate, ~3x slower", mb: 466, bytes: 487614201 },
        { name: "small", desc: "Multilingual — pair with Auto-detect", mb: 466, bytes: 487601967 },
        { name: "medium.en", desc: "Most accurate, slow on this CPU", mb: 1500, bytes: 1528008539 }
    ]

    // Audio-capable OpenRouter models for the AI-transcription dropdown,
    // fetched live from the catalog; static fallback if the fetch fails
    readonly property var aiModelFallback: [
        { label: "Google: Gemini 3.5 Flash", value: "google/gemini-3.5-flash" },
        { label: "Google: Gemini 2.5 Flash", value: "google/gemini-2.5-flash" },
        { label: "Google: Gemini 2.5 Pro", value: "google/gemini-2.5-pro" },
        { label: "OpenAI: GPT Audio", value: "openai/gpt-audio" },
        { label: "OpenAI: GPT Audio Mini", value: "openai/gpt-audio-mini" },
        { label: "Mistral: Voxtral Small 24B", value: "mistralai/voxtral-small-24b-2507" }
    ]
    property var aiModelOptions: aiModelFallback
    property bool aiModelsLive: false

    // Gemini API models (Google tab); the list endpoint needs the API key,
    // so this only goes live once one is configured
    readonly property var googleModelFallback: [
        { label: "gemini-2.5-flash", value: "gemini-2.5-flash" },
        { label: "gemini-2.5-flash-lite", value: "gemini-2.5-flash-lite" },
        { label: "gemini-2.5-pro", value: "gemini-2.5-pro" }
    ]
    property var googleModelOptions: googleModelFallback
    property bool googleModelsLive: false

    function fetchAiModels() {
        Proc.runCommand("penguinWhisperer.aiModels",
                        ["curl", "-sS", "--max-time", "20", "https://openrouter.ai/api/v1/models"],
                        (out, code) => {
                            if (code !== 0)
                                return
                            try {
                                const models = (JSON.parse(out).data || [])
                                    .filter(m => m && m.id && !m.id.startsWith("~")
                                                 && m.architecture
                                                 && (m.architecture.input_modalities || []).indexOf("audio") !== -1
                                                 && (m.architecture.output_modalities || ["text"]).indexOf("text") !== -1)
                                    .map(m => ({ label: m.name || m.id, value: m.id }))
                                    .sort((a, b) => a.label.localeCompare(b.label))
                                if (models.length > 0) {
                                    aiModelOptions = models
                                    aiModelsLive = true
                                }
                            } catch (e) {
                                console.warn("PenguinWhisperer: failed to parse OpenRouter model list:", e)
                            }
                        },
                        50, 25000)
    }

    property var installedFiles: []
    // name → percent; -1 means "just started" (grace period before the
    // orphan check, since curl takes a moment to appear)
    property var downloadPercent: ({})
    property var cancelling: ({})
    property string activeModelPath: ""

    function modelFile(name) {
        return "ggml-" + name + ".bin"
    }

    function modelFullPath(name) {
        return modelsDir + "/" + modelFile(name)
    }

    // pgrep/pkill pattern for a model's download that can't match the
    // probing process itself: first char wrapped in a bracket class
    function downloadProbe(name) {
        const base = modelFile(name) + ".part"
        return ("[" + base[0] + "]" + base.slice(1)).replace(/\./g, "\\.")
    }

    function isInstalled(name) {
        return installedFiles.indexOf(modelFile(name)) !== -1
    }

    function isDownloading(name) {
        return downloadPercent[name] !== undefined
    }

    function shownPercent(name) {
        return Math.max(0, downloadPercent[name] !== undefined ? downloadPercent[name] : 0)
    }

    function refresh() {
        activeModelPath = PluginService.loadPluginData(pluginId, "modelPath", modelFullPath("base.en"))
        Proc.runCommand("penguinWhisperer.scanModels",
                        ["sh", "-c", "ls '" + modelsDir + "' 2>/dev/null; true"],
                        (out, code) => {
                            const files = out.trim().split("\n").filter(f => f.length > 0)
                            installedFiles = files.filter(f => f.endsWith(".bin"))
                            // Resume progress tracking for downloads already in
                            // flight (e.g. the settings page was closed and reopened)
                            const updated = Object.assign({}, downloadPercent)
                            let changed = false
                            for (const f of files.filter(f => f.endsWith(".bin.part"))) {
                                const name = f.replace("ggml-", "").replace(".bin.part", "")
                                if (updated[name] === undefined && catalog.some(m => m.name === name)) {
                                    updated[name] = 0
                                    changed = true
                                }
                            }
                            if (changed)
                                downloadPercent = updated
                        })
    }

    function downloadModel(model) {
        const updated = Object.assign({}, downloadPercent)
        updated[model.name] = -1
        downloadPercent = updated

        const path = modelFullPath(model.name)
        Proc.runCommand("penguinWhisperer.download." + model.name,
                        ["sh", "-c",
                         "mkdir -p \"$(dirname \"$1\")\" && curl -L -sS -f -o \"$1.part\" \"$2\" && mv \"$1.part\" \"$1\"",
                         "_", path, hfBase + modelFile(model.name)],
                        (out, code) => {
                            const done = Object.assign({}, downloadPercent)
                            delete done[model.name]
                            downloadPercent = done
                            const wasCancelled = cancelling[model.name] === true
                            const c = Object.assign({}, cancelling)
                            delete c[model.name]
                            cancelling = c
                            if (code === 0) {
                                if (typeof ToastService !== "undefined")
                                    ToastService.showInfo(model.name + " downloaded")
                            } else if (!wasCancelled) {
                                Proc.runCommand("penguinWhisperer.cleanupPart." + model.name,
                                                ["rm", "-f", path + ".part"], () => {})
                                if (typeof ToastService !== "undefined")
                                    ToastService.showError("Download of " + model.name + " failed")
                            }
                            refresh()
                        },
                        50, Proc.noTimeout)
    }

    function cancelDownload(model) {
        const c = Object.assign({}, cancelling)
        c[model.name] = true
        cancelling = c
        Proc.runCommand("penguinWhisperer.cancel." + model.name,
                        ["sh", "-c", "pkill -f '" + downloadProbe(model.name) + "'; rm -f '" + modelFullPath(model.name) + ".part'"],
                        (out, code) => {
                            const done = Object.assign({}, downloadPercent)
                            delete done[model.name]
                            downloadPercent = done
                            refresh()
                        })
    }

    function deleteModel(model) {
        if (modelFullPath(model.name) === activeModelPath) {
            if (typeof ToastService !== "undefined")
                ToastService.showError("Select a different model before deleting the active one")
            return
        }
        Proc.runCommand("penguinWhisperer.delete." + model.name,
                        ["rm", "-f", modelFullPath(model.name)],
                        () => refresh())
    }

    function selectModel(model) {
        PluginService.savePluginData(pluginId, "modelPath", modelFullPath(model.name))
        activeModelPath = modelFullPath(model.name)
    }

    // Filters out non-conversational Gemini variants (TTS, embeddings, image
    // generation, live/native-audio, etc.) that can't do audio->text dictation
    readonly property var googleModelExclude: /(tts|embedding|live|native-audio|image|imagen|veo|aqa|learnlm|robotics|gemma)/

    property string googleFetchKey: ""

    Process {
        id: googleModelFetch
        environment: ({ "AI_API_KEY": settingsRoot.googleFetchKey })
        command: ["sh", "-c",
                  "curl -sS --max-time 20 -H \"x-goog-api-key: $AI_API_KEY\" " +
                  "'https://generativelanguage.googleapis.com/v1beta/models?pageSize=200'"]
        stdout: StdioCollector {
            id: googleModelsOut
            waitForEnd: true
        }
        onExited: exitCode => {
            if (exitCode !== 0)
                return
            try {
                const models = (JSON.parse(googleModelsOut.text).models || [])
                    .filter(m => m && m.name && m.name.startsWith("models/gemini")
                                 && (m.supportedGenerationMethods || []).indexOf("generateContent") !== -1
                                 && !settingsRoot.googleModelExclude.test(m.name))
                    .map(m => ({ label: m.name.replace("models/", ""), value: m.name.replace("models/", "") }))
                    .sort((a, b) => a.label.localeCompare(b.label))
                if (models.length > 0) {
                    settingsRoot.googleModelOptions = models
                    settingsRoot.googleModelsLive = true
                }
            } catch (e) {
                console.warn("PenguinWhisperer: failed to parse Gemini model list:", e)
            }
        }
    }

    function fetchGoogleModels() {
        const key = PluginService.loadPluginData(pluginId, "googleApiKey", "").trim()
        if (key.length > 0 && !googleModelFetch.running) {
            googleFetchKey = key
            googleModelFetch.running = true
        }
    }

    // Pick up a freshly pasted Google key without reopening the page
    Connections {
        target: PluginService
        function onPluginDataChanged(pluginId) {
            if (pluginId === settingsRoot.pluginId && !settingsRoot.googleModelsLive)
                settingsRoot.fetchGoogleModels()
        }
    }

    Component.onCompleted: {
        refresh()
        fetchAiModels()
        fetchGoogleModels()
    }

    Timer {
        id: progressTimer
        interval: 500
        repeat: true
        running: Object.keys(settingsRoot.downloadPercent).length > 0
        onTriggered: {
            for (const name of Object.keys(settingsRoot.downloadPercent)) {
                const entry = settingsRoot.catalog.find(m => m.name === name)
                if (!entry)
                    continue
                if (settingsRoot.downloadPercent[name] === -1) {
                    // grace tick: curl may not have spawned yet
                    const updated = Object.assign({}, settingsRoot.downloadPercent)
                    updated[name] = 0
                    settingsRoot.downloadPercent = updated
                    continue
                }
                const partPath = settingsRoot.modelFullPath(name) + ".part"
                Proc.runCommand("penguinWhisperer.progress." + name,
                                ["sh", "-c",
                                 "stat -c %s '" + partPath + "' 2>/dev/null || echo 0; " +
                                 "pgrep -fc '" + settingsRoot.downloadProbe(name) + "' 2>/dev/null || echo 0"],
                                (out, code) => {
                                    if (settingsRoot.downloadPercent[name] === undefined)
                                        return
                                    const lines = out.trim().split("\n")
                                    const size = parseInt(lines[0] || "0") || 0
                                    const alive = (parseInt(lines[1] || "0") || 0) > 0
                                    if (!alive) {
                                        // Orphaned .part (e.g. shell restarted
                                        // mid-download): clean up unless the file
                                        // actually landed between ticks
                                        const done = Object.assign({}, settingsRoot.downloadPercent)
                                        delete done[name]
                                        settingsRoot.downloadPercent = done
                                        Proc.runCommand("penguinWhisperer.orphan." + name,
                                                        ["sh", "-c",
                                                         "rm -f '" + partPath + "'; test -f '" + settingsRoot.modelFullPath(name) + "' && echo ok || echo gone"],
                                                        (res, rc) => {
                                                            if (res.trim() !== "ok" && typeof ToastService !== "undefined")
                                                                ToastService.showError(name + " download was interrupted")
                                                            settingsRoot.refresh()
                                                        })
                                        return
                                    }
                                    const updated = Object.assign({}, settingsRoot.downloadPercent)
                                    updated[name] = Math.min(99, Math.round(size / entry.bytes * 100))
                                    settingsRoot.downloadPercent = updated
                                })
            }
        }
    }

    StyledText {
        width: parent.width
        text: "Click the mic in the bar, press Mod+Shift+D, or run `dms ipc call penguinWhisperer toggle` to dictate. Text is typed at the focused cursor when transcription finishes. Mod+Shift+A dictates via an AI provider instead (configured below)."
        font.pixelSize: Theme.fontSizeMedium
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    // ── Model manager ──────────────────────────────────────────────────────

    StyledText {
        width: parent.width
        text: "Models"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    Column {
        width: parent.width
        spacing: Theme.spacingS

        Repeater {
            model: settingsRoot.catalog

            Rectangle {
                id: modelRow
                required property var modelData

                readonly property bool installed: settingsRoot.isInstalled(modelData.name)
                readonly property bool downloading: settingsRoot.isDownloading(modelData.name)
                readonly property bool active: settingsRoot.modelFullPath(modelData.name) === settingsRoot.activeModelPath
                readonly property int percent: settingsRoot.shownPercent(modelData.name)

                width: parent.width
                height: downloading ? 74 : 60
                radius: Theme.cornerRadius
                color: active ? Qt.alpha(Theme.primary, 0.12) : Theme.surfaceContainerHigh
                border.width: active ? 1 : 0
                border.color: Qt.alpha(Theme.primary, 0.5)

                Behavior on height {
                    NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
                }

                Row {
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.spacingM
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.verticalCenterOffset: modelRow.downloading ? -7 : 0
                    spacing: Theme.spacingM

                    DankIcon {
                        name: modelRow.downloading ? "downloading" : (modelRow.active ? "radio_button_checked" : (modelRow.installed ? "radio_button_unchecked" : "cloud_download"))
                        size: Theme.iconSize
                        color: (modelRow.active || modelRow.downloading) ? Theme.primary : Theme.surfaceVariantText
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Column {
                        spacing: 2
                        anchors.verticalCenter: parent.verticalCenter

                        StyledText {
                            text: modelRow.modelData.name + "  ·  " + modelRow.modelData.mb + " MB"
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: modelRow.active ? Font.Medium : Font.Normal
                            color: Theme.surfaceText
                        }

                        StyledText {
                            text: modelRow.downloading
                                  ? "Downloading… " + modelRow.percent + "% of " + modelRow.modelData.mb + " MB"
                                  : modelRow.modelData.desc
                            font.pixelSize: Theme.fontSizeSmall
                            color: modelRow.downloading ? Theme.primary : Theme.surfaceVariantText
                        }
                    }
                }

                // Download progress bar
                Rectangle {
                    visible: modelRow.downloading
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.leftMargin: Theme.spacingM
                    anchors.rightMargin: Theme.spacingM
                    anchors.bottomMargin: 8
                    height: 5
                    radius: 2.5
                    color: Qt.alpha(Theme.primary, 0.2)

                    Rectangle {
                        width: parent.width * modelRow.percent / 100
                        height: parent.height
                        radius: parent.radius
                        color: Theme.primary

                        Behavior on width {
                            NumberAnimation { duration: 400; easing.type: Easing.OutQuad }
                        }
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    enabled: modelRow.installed && !modelRow.active
                    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: settingsRoot.selectModel(modelRow.modelData)
                }

                Row {
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.spacingS
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.verticalCenterOffset: modelRow.downloading ? -7 : 0
                    spacing: Theme.spacingXS

                    DankActionButton {
                        visible: !modelRow.installed && !modelRow.downloading
                        iconName: "download"
                        tooltipText: "Download"
                        buttonSize: 34
                        anchors.verticalCenter: parent.verticalCenter
                        onClicked: settingsRoot.downloadModel(modelRow.modelData)
                    }

                    DankActionButton {
                        visible: modelRow.downloading
                        iconName: "close"
                        tooltipText: "Cancel download"
                        buttonSize: 34
                        anchors.verticalCenter: parent.verticalCenter
                        onClicked: settingsRoot.cancelDownload(modelRow.modelData)
                    }

                    DankActionButton {
                        visible: modelRow.installed && !modelRow.active
                        iconName: "delete"
                        tooltipText: "Delete model file"
                        iconColor: Theme.error
                        buttonSize: 34
                        anchors.verticalCenter: parent.verticalCenter
                        onClicked: settingsRoot.deleteModel(modelRow.modelData)
                    }
                }
            }
        }
    }

    // ── Snippets ───────────────────────────────────────────────────────────

    StyledText {
        width: parent.width
        text: "Snippets"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    ListSettingWithInput {
        settingKey: "snippets"
        label: "Voice snippets"
        description: "Speak a trigger phrase on its own and the full text is typed instead of the transcript. Only applies to local (whisper) dictation; the whole dictation must match the trigger, ignoring case and punctuation. Use \\n in the text for a line break."
        defaultValue: []
        fields: [
            {id: "trigger", label: "Trigger phrase", placeholder: "sign off", width: 160, required: true},
            {id: "text", label: "Text to type", placeholder: "Best regards,\\nDaniel", width: 300, required: true}
        ]
    }

    // ── AI cleanup ─────────────────────────────────────────────────────────

    StyledText {
        width: parent.width
        text: "AI cleanup"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "Dictate with Mod+Shift+A (or `dms ipc call penguinWhisperer toggleAi`) and the audio recording is sent straight to an audio-capable model, which transcribes and formats it in one pass — rambling in, clear formatted text out. Your custom vocabulary is included in the prompt; snippets don't apply in this mode. Pressing Mod+Shift+A while already recording also finishes with AI transcription. On failure it falls back to local whisper. Configure each provider in its tab, then pick which one is active below."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    DankTabBar {
        id: providerTabs
        width: Math.min(320, parent.width)
        height: 45
        model: [
            { text: "OpenRouter", icon: "hub" },
            { text: "Google", icon: "cloud" }
        ]
        Component.onCompleted: {
            currentIndex = PluginService.loadPluginData(settingsRoot.pluginId, "aiProvider", "openrouter") === "google" ? 1 : 0
        }
        onTabClicked: index => currentIndex = index
    }

    // OpenRouter provider tab
    Column {
        width: parent.width
        spacing: Theme.spacingM
        visible: providerTabs.currentIndex === 0

        StringSetting {
            settingKey: "aiApiKey"
            label: "OpenRouter API key"
            description: "Create one at openrouter.ai/keys. Stored in plugin settings; sent only to openrouter.ai."
            placeholder: "sk-or-v1-…"
            defaultValue: ""
        }

        SelectionSetting {
            settingKey: "aiModel"
            label: "Model"
            description: settingsRoot.aiModelsLive
                         ? "Audio-capable models from the OpenRouter catalog"
                         : "Known audio-capable models (couldn't fetch the live OpenRouter catalog)"
            options: settingsRoot.aiModelOptions
            defaultValue: "google/gemini-3.5-flash"
        }
    }

    // Google (Gemini API) provider tab
    Column {
        width: parent.width
        spacing: Theme.spacingM
        visible: providerTabs.currentIndex === 1

        StringSetting {
            settingKey: "googleApiKey"
            label: "Google AI Studio API key"
            description: "Free tier available — create one at aistudio.google.com/apikey. Stored in plugin settings; sent only to generativelanguage.googleapis.com."
            placeholder: "AIza…"
            defaultValue: ""
        }

        SelectionSetting {
            settingKey: "googleModel"
            label: "Model"
            description: settingsRoot.googleModelsLive
                         ? "Gemini models from your account's catalog"
                         : "Common Gemini models (the live catalog loads once an API key is set)"
            options: settingsRoot.googleModelOptions
            defaultValue: "gemini-2.5-flash"
        }
    }

    SelectionSetting {
        settingKey: "aiProvider"
        label: "Active provider"
        description: "Which provider Mod+Shift+A uses"
        options: [
            { label: "OpenRouter", value: "openrouter" },
            { label: "Google (Gemini API)", value: "google" }
        ]
        defaultValue: "openrouter"
    }

    StringSetting {
        settingKey: "aiStyle"
        label: "Extra style instructions (optional)"
        description: "Appended to the cleanup prompt, e.g. \"British spelling\" or \"keep it casual, no em dashes\""
        placeholder: ""
        defaultValue: ""
    }

    // ── Behaviour ──────────────────────────────────────────────────────────

    ListSettingWithInput {
        settingKey: "customWords"
        label: "Custom vocabulary"
        description: "Names, jargon, and unusual spellings the transcriber should know. Fed to whisper as an initial prompt — keep the list short (a few dozen words) for best effect."
        defaultValue: []
        fields: [
            {id: "word", label: "Word or phrase", placeholder: "DankMaterialShell", width: 280, required: true}
        ]
    }

    SelectionSetting {
        settingKey: "language"
        label: "Language"
        description: "Auto-detect requires a multilingual model (e.g. small)"
        options: [
            {label: "English", value: "en"},
            {label: "Auto-detect", value: "auto"}
        ]
        defaultValue: "en"
    }

    ToggleSetting {
        settingKey: "typeText"
        label: "Type at cursor"
        description: "Type the transcript into the focused window using wtype"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "copyText"
        label: "Copy to clipboard"
        description: "Also copy the transcript to the clipboard"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "soundCues"
        label: "Sound cues"
        description: "Play a soft chime when recording starts, finishes, or fails"
        defaultValue: true
    }

    StringSetting {
        settingKey: "whisperBin"
        label: "whisper-cli path"
        description: "Path to the whisper.cpp CLI binary"
        placeholder: "~/.local/bin/whisper-cli"
        defaultValue: Quickshell.env("HOME") + "/.local/bin/whisper-cli"
    }
}
