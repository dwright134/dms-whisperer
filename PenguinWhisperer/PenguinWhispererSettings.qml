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

    // Same display name can appear for several catalog entries (e.g. preview
    // revisions); append the model id so every row is tellable apart
    function disambiguate(models) {
        const counts = {}
        for (const m of models)
            counts[m.label] = (counts[m.label] || 0) + 1
        return models.map(m => counts[m.label] > 1
                          ? { label: m.label + " · " + m.value, value: m.value }
                          : m)
    }

    // Secret string setting: a saved value is masked with bullets and is
    // never readable from the settings page (no reveal toggle). Mirrors
    // StringSetting's self-loading pattern so it works nested inside tab
    // columns without relying on PluginSettings' direct-child load walk.
    component SecretSetting: Column {
        id: secret

        required property string settingKey
        required property string label
        property string description: ""
        property string placeholder: ""
        property string defaultValue: ""
        property string value: defaultValue

        width: parent.width
        spacing: Theme.spacingS

        property bool isInitialized: false

        function findSettings() {
            let item = parent
            while (item) {
                if (item.saveValue !== undefined && item.loadValue !== undefined)
                    return item
                item = item.parent
            }
            return null
        }

        // Keys live in the login keyring (gnome-keyring), not the settings JSON.
        // The real value is loaded back masked so the bullet count reflects the
        // stored key and blanking the field still clears it.
        function loadValue() {
            Proc.runCommand("penguinWhisperer.key.show." + settingKey,
                            ["secret-tool", "lookup", "service", "penguin-whisperer", "key", settingKey],
                            (out, code) => {
                                if (textField.activeFocus && isInitialized)
                                    return
                                let loaded = code === 0 ? out.replace(/\n+$/, "") : ""
                                if (loaded.length === 0) {
                                    // Pre-migration fallback: an older build may
                                    // still hold the key in plaintext JSON until
                                    // the widget migrates it to the keyring.
                                    const settings = findSettings()
                                    if (settings)
                                        loaded = settings.loadValue(settingKey, defaultValue)
                                }
                                value = loaded
                                textField.text = loaded
                                isInitialized = true
                            })
        }

        function commit() {
            if (!isInitialized)
                return
            if (textField.text === value)
                return
            value = textField.text
            const settings = findSettings()
            if (value.length > 0) {
                // Store into the keyring (secret via env, never argv). On success
                // purge any plaintext JSON copy and flip the "<key>Set" flag —
                // that flag change is what notifies the widget to reload.
                const p = Qt.createQmlObject('import Quickshell.Io; Process { running: false }', secret)
                p.environment = ({ "PW_SECRET": value })
                p.command = ["sh", "-c",
                             "printf %s \"$PW_SECRET\" | secret-tool store --label=\"Penguin Whisperer API key\" service \"$1\" key \"$2\"",
                             "sh", "penguin-whisperer", settingKey]
                p.exited.connect(code => {
                    if (code === 0 && settings) {
                        settings.saveValue(settingKey, "")
                        settings.saveValue(settingKey + "Set", true)
                    }
                    p.destroy()
                })
                p.running = true
            } else {
                // Cleared: drop it from the keyring and record "not set".
                Proc.runCommand("penguinWhisperer.key.clear." + settingKey,
                                ["secret-tool", "clear", "service", "penguin-whisperer", "key", settingKey],
                                (out, code) => {})
                if (settings) {
                    settings.saveValue(settingKey, "")
                    settings.saveValue(settingKey + "Set", false)
                }
            }
        }

        Component.onCompleted: Qt.callLater(loadValue)

        StyledText {
            text: secret.label
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.Medium
            color: Theme.surfaceText
        }

        StyledText {
            text: secret.description
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            width: parent.width
            wrapMode: Text.WordWrap
            visible: secret.description !== ""
        }

        DankTextField {
            id: textField
            width: parent.width
            placeholderText: secret.placeholder
            echoMode: TextInput.Password
            showPasswordToggle: false
            onEditingFinished: secret.commit()
            onActiveFocusChanged: if (!activeFocus) secret.commit()
        }
    }

    // Model pickers need more room than SelectionSetting's fixed 200px
    // control, which elides long model names into ambiguity: full-width
    // dropdown, wide popup, fuzzy search over the whole catalog
    component ModelSelect: Column {
        id: modelSelect

        required property string settingKey
        required property string label
        property string description: ""
        property var options: []
        property string defaultValue: ""
        property string value: defaultValue

        readonly property var valueToLabel: {
            const map = {}
            for (const opt of options)
                map[opt.value] = opt.label
            return map
        }
        readonly property var labelToValue: {
            const map = {}
            for (const opt of options)
                map[opt.label] = opt.value
            return map
        }

        width: parent.width
        spacing: Theme.spacingS

        // Called by PluginSettings when the plugin service appears
        function loadValue() {
            if (settingsRoot.pluginService)
                value = settingsRoot.loadValue(settingKey, defaultValue)
        }

        Component.onCompleted: loadValue()

        StyledText {
            text: modelSelect.label
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.Medium
            color: Theme.surfaceText
        }

        StyledText {
            text: modelSelect.description
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            width: parent.width
            wrapMode: Text.WordWrap
            visible: modelSelect.description !== ""
        }

        DankDropdown {
            width: parent.width
            enableFuzzySearch: true
            maxPopupHeight: 440
            currentValue: modelSelect.valueToLabel[modelSelect.value] || modelSelect.value
            options: modelSelect.options.map(o => o.label)
            onValueChanged: newValue => {
                modelSelect.value = modelSelect.labelToValue[newValue] || newValue
                settingsRoot.saveValue(modelSelect.settingKey, modelSelect.value)
            }
        }
    }

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
                                    aiModelOptions = disambiguate(models)
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
                         // Reject a truncated/garbage download (e.g. a 200 that
                         // returns an error page) before it lands as a real model
                         // and whisper fails later with a cryptic error.
                         "mkdir -p \"$(dirname \"$1\")\" && curl -L -sS -f -o \"$1.part\" \"$2\" && " +
                         "if [ -n \"$3\" ] && [ \"$(stat -c %s \"$1.part\" 2>/dev/null)\" != \"$3\" ]; then echo size-mismatch; exit 3; fi && " +
                         "mv \"$1.part\" \"$1\"",
                         "_", path, hfBase + modelFile(model.name), String(model.bytes || "")],
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
                                    ToastService.showError(code === 3
                                        ? model.name + " download was corrupted (size mismatch) — please retry"
                                        : "Download of " + model.name + " failed")
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
                    settingsRoot.googleModelOptions = settingsRoot.disambiguate(models)
                    settingsRoot.googleModelsLive = true
                }
            } catch (e) {
                console.warn("PenguinWhisperer: failed to parse Gemini model list:", e)
            }
        }
    }

    function fetchGoogleModels() {
        if (googleModelFetch.running)
            return
        Proc.runCommand("penguinWhisperer.key.googleFetch",
                        ["secret-tool", "lookup", "service", "penguin-whisperer", "key", "googleApiKey"],
                        (out, code) => {
                            let key = code === 0 ? out.replace(/\n+$/, "") : ""
                            if (key.length === 0)
                                key = PluginService.loadPluginData(pluginId, "googleApiKey", "").trim()
                            if (key.length > 0 && !googleModelFetch.running) {
                                googleFetchKey = key
                                googleModelFetch.running = true
                            }
                        })
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
        text: "Dictate with Mod+Shift+A (or `dms ipc call penguinWhisperer toggleAi`) and the audio recording is sent straight to an audio-capable model, which transcribes and formats it in one pass — rambling in, clear formatted text out. Your custom vocabulary and snippet triggers are included in the prompt, and snippets expand here too when the whole dictation matches a trigger. Pressing Mod+Shift+A while already recording also finishes with AI transcription. On failure it falls back to local whisper. Configure each provider in its tab, then pick which one is active below."
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

        SecretSetting {
            settingKey: "aiApiKey"
            label: "OpenRouter API key"
            description: "Create one at openrouter.ai/keys. Stored in your login keyring; sent only to openrouter.ai."
            placeholder: "sk-or-v1-…"
            defaultValue: ""
        }

        ModelSelect {
            settingKey: "aiModel"
            label: "Model"
            description: settingsRoot.aiModelsLive
                         ? "Audio-capable models from the OpenRouter catalog — click to search"
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

        SecretSetting {
            settingKey: "googleApiKey"
            label: "Google AI Studio API key"
            description: "Free tier available — create one at aistudio.google.com/apikey. Stored in your login keyring; sent only to generativelanguage.googleapis.com."
            placeholder: "AIza…"
            defaultValue: ""
        }

        ModelSelect {
            settingKey: "googleModel"
            label: "Model"
            description: settingsRoot.googleModelsLive
                         ? "Gemini models from your account's catalog — click to search"
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

    // ── Recording ──────────────────────────────────────────────────────────

    StyledText {
        width: parent.width
        text: "Recording"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    ToggleSetting {
        settingKey: "autoStopEnabled"
        label: "Auto-stop on silence"
        description: "Stop dictation automatically after a stretch of silence. Only arms once you've actually said something, so it won't cut off a slow start. When off, recording keeps going until you click the bar pill or hit the keybind again (5 minute cap either way)."
        defaultValue: false
    }

    SliderSetting {
        settingKey: "autoStopSeconds"
        label: "Silence before auto-stop"
        description: "How long a pause has to last before dictation stops — raise it if you like to think mid-sentence"
        minimum: 1
        maximum: 15
        defaultValue: 3
        unit: "s"
    }

    ToggleSetting {
        settingKey: "cancelBackgroundMusic"
        label: "Cancel background music"
        description: "Dictate over music playing on speakers. When PipeWire echo cancellation is available it removes the speaker audio from the recording before transcription; otherwise it just pauses your media players while you record. Off by default, and if anything fails it falls back to the plain microphone."
        defaultValue: false
    }

    SelectionSetting {
        settingKey: "overlayPosition"
        label: "Overlay position"
        description: "Screen edge where the recording overlay pops up"
        options: [
            { label: "Bottom", value: "bottom" },
            { label: "Top", value: "top" }
        ]
        defaultValue: "bottom"
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
