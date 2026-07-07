import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: settingsRoot
    pluginId: "whisperer"

    readonly property string home: Quickshell.env("HOME")
    readonly property string modelsDir: home + "/.local/share/whisperer/models"
    readonly property string hfBase: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/"

    readonly property var catalog: [
        { name: "tiny.en", desc: "Fastest, lower accuracy", mb: 75, bytes: 77704715 },
        { name: "base.en", desc: "Good balance (default)", mb: 142, bytes: 147964211 },
        { name: "small.en", desc: "More accurate, ~3x slower", mb: 466, bytes: 487614201 },
        { name: "small", desc: "Multilingual — pair with Auto-detect", mb: 466, bytes: 487601967 },
        { name: "medium.en", desc: "Most accurate, slow on this CPU", mb: 1500, bytes: 1528008539 }
    ]

    // Local transcription backends. Descriptions surface the trade-off; the
    // picker only offers the ones actually installed (detectBackends below).
    readonly property var backendMeta: ({
        "whisper.cpp":    { desc: "Local C++ engine. GPU via Vulkan/CUDA if your build supports it, otherwise CPU. Uses the downloadable models below." },
        "faster-whisper": { desc: "CTranslate2 reimplementation — the fastest option on CPU (int8). Needs the whisper-ctranslate2 command." }
    })
    readonly property var backendOrder: ["whisper.cpp", "faster-whisper"]

    // Which backends are on PATH, and where they resolved. Reactive: the
    // detection list and the picker rebuild when these change. whisper.cpp
    // counts as present if any of its binary names resolve; its model files are
    // handled separately below.
    property var backendAvail: ({ "whisper.cpp": false, "faster-whisper": false })
    property var backendPath: ({ "whisper.cpp": "", "faster-whisper": "" })

    // The live backend selection, mirrored from the saved value so the
    // per-backend model UI (the whisper.cpp file manager vs the CLI name
    // picker) can show/hide reactively.
    property string currentBackend: "whisper.cpp"

    // Live mirrors of the language / translate-to-English settings, resynced via
    // onPluginDataChanged, so the English-only-model warning can react without
    // each SelectionSetting/ToggleSetting exposing its value.
    property string curLanguage: "en"
    property bool curTranslate: false

    function loadModelWarningState() {
        curLanguage = PluginService.loadPluginData(pluginId, "language", "en")
        curTranslate = PluginService.loadPluginData(pluginId, "translateToEnglish", false)
    }

    // The local model selected for the active backend, and whether it's an
    // English-only (.en) build. Those can't transcribe non-English audio or run
    // the translate task — the most common footgun — so we warn on the combo.
    readonly property string selectedLocalModel: currentBackend === "faster-whisper"
        ? fwSelected
        : activeModelPath.split("/").pop().replace("ggml-", "").replace(".bin", "")
    readonly property bool englishOnlyMismatch:
        selectedLocalModel.endsWith(".en") && (curLanguage !== "en" || curTranslate)

    // Resolve each backend's binary and remember where it landed, so the
    // detection list can show exactly what was found and the picker can offer
    // only what's installed. Emits one "<key>=<path>" line per backend present.
    function detectBackends() {
        Proc.runCommand("whisperer.settings.detectBackends",
                        ["sh", "-c",
                         "p=$(command -v whisper-cli || command -v whisper-cpp || command -v whisper.cpp); [ -n \"$p\" ] && echo \"cpp=$p\"; "
                         + "p=$(command -v whisper-ctranslate2); [ -n \"$p\" ] && echo \"fw=$p\"; true"],
                        (out, code) => {
                            const keyMap = { "cpp": "whisper.cpp", "fw": "faster-whisper" }
                            const paths = { "whisper.cpp": "", "faster-whisper": "" }
                            for (const line of (out || "").split("\n")) {
                                const i = line.indexOf("=")
                                if (i === -1)
                                    continue
                                const k = keyMap[line.slice(0, i)]
                                if (k)
                                    paths[k] = line.slice(i + 1).trim()
                            }
                            backendPath = paths
                            backendAvail = {
                                "whisper.cpp": paths["whisper.cpp"].length > 0,
                                "faster-whisper": paths["faster-whisper"].length > 0
                            }
                        })
    }

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
            Proc.runCommand("whisperer.key.show." + settingKey,
                            ["secret-tool", "lookup", "service", "whisperer", "key", settingKey],
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
                             "printf %s \"$PW_SECRET\" | secret-tool store --label=\"Whisperer API key\" service \"$1\" key \"$2\"",
                             "sh", "whisperer", settingKey]
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
                Proc.runCommand("whisperer.key.clear." + settingKey,
                                ["secret-tool", "clear", "service", "whisperer", "key", settingKey],
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

    // Read-only summary of which local engines are installed, shown at the top
    // of the Transcription card. Reads the paths resolved by detectBackends()
    // and offers a manual re-scan; the picker below offers whatever's found
    // here. whisper.cpp's own binary is detected and persisted by the plugin,
    // so there's nothing to configure — this is purely informational.
    component BackendDetection: Column {
        width: parent.width
        spacing: Theme.spacingS

        Item {
            width: parent.width
            height: Math.max(detectTitle.implicitHeight, 32)

            StyledText {
                id: detectTitle
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "Detected engines"
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                color: Theme.surfaceText
            }

            DankActionButton {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                iconName: "refresh"
                tooltipText: "Scan again"
                buttonSize: 32
                onClicked: settingsRoot.detectBackends()
            }
        }

        StyledText {
            width: parent.width
            text: "Transcription engines found on your PATH — these are the options offered in the picker below."
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            wrapMode: Text.WordWrap
        }

        Repeater {
            model: settingsRoot.backendOrder

            StyledRect {
                id: engineRow
                required property string modelData
                readonly property bool found: settingsRoot.backendAvail[modelData] === true
                readonly property string resolvedPath: settingsRoot.backendPath[modelData] || ""

                width: parent.width
                height: engineText.implicitHeight + Theme.spacingM * 2
                radius: Theme.cornerRadius
                color: Theme.surfaceContainerHighest

                DankIcon {
                    id: engineIcon
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.spacingM
                    anchors.verticalCenter: parent.verticalCenter
                    name: engineRow.found ? "check_circle" : "cancel"
                    size: Theme.iconSize - 4
                    color: engineRow.found ? Theme.primary : Theme.surfaceVariantText
                }

                Column {
                    id: engineText
                    anchors.left: engineIcon.right
                    anchors.leftMargin: Theme.spacingS
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.spacingM
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 1

                    StyledText {
                        width: parent.width
                        text: engineRow.modelData
                        font.pixelSize: Theme.fontSizeMedium
                        color: Theme.surfaceText
                    }

                    StyledText {
                        width: parent.width
                        text: engineRow.found ? engineRow.resolvedPath : "not installed"
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        elide: Text.ElideMiddle
                    }
                }
            }
        }
    }

    // whisper.cpp's downloadable model manager: pick, download, or delete the
    // ggml model files. Only meaningful for the whisper.cpp backend (the CLI
    // backends fetch their own models by name), so the Transcription card shows
    // it only when whisper.cpp is the selected backend.
    component WhisperCppModels: Column {
        width: parent.width
        spacing: Theme.spacingS

        StyledText {
            text: "Model"
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.Medium
            color: Theme.surfaceText
        }

        StyledText {
            width: parent.width
            text: "Download a model, then click it to make it active."
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            wrapMode: Text.WordWrap
        }

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

    // faster-whisper's model manager, mirroring WhisperCppModels: shows which
    // models are cached locally, downloads/deletes them, and selects the active
    // one (saved to ctModel). Shown only for the faster-whisper backend.
    component FasterWhisperModels: Column {
        width: parent.width
        spacing: Theme.spacingS

        function loadValue() {
            settingsRoot.fwRefresh()
        }
        Component.onCompleted: loadValue()

        StyledText {
            text: "Model"
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.Medium
            color: Theme.surfaceText
        }

        StyledText {
            width: parent.width
            text: "Download a model, then click it to make it active. Stored under ~/.local/share/whisperer/faster-whisper. If you skip this, the tool fetches your selected model into its own cache on first use."
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            wrapMode: Text.WordWrap
        }

        Repeater {
            model: settingsRoot.fwCatalog

            Rectangle {
                id: fwRow
                required property var modelData

                readonly property bool installed: settingsRoot.fwIsInstalled(modelData.name)
                readonly property bool downloading: settingsRoot.fwIsDownloading(modelData.name)
                readonly property bool active: settingsRoot.fwSelected === modelData.name
                readonly property int percent: settingsRoot.fwShownPercent(modelData.name)

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
                    anchors.verticalCenterOffset: fwRow.downloading ? -7 : 0
                    spacing: Theme.spacingM

                    DankIcon {
                        name: fwRow.downloading ? "downloading" : (fwRow.active ? "radio_button_checked" : (fwRow.installed ? "radio_button_unchecked" : "cloud_download"))
                        size: Theme.iconSize
                        color: (fwRow.active || fwRow.downloading) ? Theme.primary : Theme.surfaceVariantText
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Column {
                        spacing: 2
                        anchors.verticalCenter: parent.verticalCenter

                        StyledText {
                            text: fwRow.modelData.name + "  ·  " + fwRow.modelData.mb + " MB"
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: fwRow.active ? Font.Medium : Font.Normal
                            color: Theme.surfaceText
                        }

                        StyledText {
                            text: fwRow.downloading
                                  ? "Downloading… " + fwRow.percent + "% of " + fwRow.modelData.mb + " MB"
                                  : (fwRow.installed ? "Cached — " + fwRow.modelData.desc : fwRow.modelData.desc)
                            font.pixelSize: Theme.fontSizeSmall
                            color: fwRow.downloading ? Theme.primary : Theme.surfaceVariantText
                        }
                    }
                }

                // Download progress bar
                Rectangle {
                    visible: fwRow.downloading
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
                        width: parent.width * fwRow.percent / 100
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
                    enabled: fwRow.installed && !fwRow.active
                    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: settingsRoot.fwSelect(fwRow.modelData)
                }

                Row {
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.spacingS
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.verticalCenterOffset: fwRow.downloading ? -7 : 0
                    spacing: Theme.spacingXS

                    DankActionButton {
                        visible: !fwRow.installed && !fwRow.downloading
                        iconName: "download"
                        tooltipText: "Download"
                        buttonSize: 34
                        anchors.verticalCenter: parent.verticalCenter
                        onClicked: settingsRoot.fwDownload(fwRow.modelData)
                    }

                    DankActionButton {
                        visible: fwRow.downloading
                        iconName: "close"
                        tooltipText: "Cancel download"
                        buttonSize: 34
                        anchors.verticalCenter: parent.verticalCenter
                        onClicked: settingsRoot.fwCancel(fwRow.modelData)
                    }

                    DankActionButton {
                        visible: fwRow.installed && !fwRow.downloading
                        iconName: "delete"
                        tooltipText: "Delete model files"
                        iconColor: Theme.error
                        buttonSize: 34
                        anchors.verticalCenter: parent.verticalCenter
                        onClicked: settingsRoot.fwDelete(fwRow.modelData)
                    }
                }
            }
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

    // Local-backend picker. Options are only the backends detected on PATH,
    // plus the currently-saved one even if uninstalled (so a removed tool's
    // selection isn't silently dropped). Mirrors the choice into currentBackend
    // so the whisper.cpp-only UI can react.
    component BackendSelect: Column {
        id: backendSelect

        required property string settingKey
        property string defaultValue: "whisper.cpp"
        property string value: defaultValue

        readonly property var options: {
            const opts = []
            for (const key of settingsRoot.backendOrder)
                if (settingsRoot.backendAvail[key] || key === backendSelect.value)
                    opts.push(key)
            return opts
        }

        width: parent.width
        spacing: Theme.spacingS

        function loadValue() {
            if (settingsRoot.pluginService) {
                value = settingsRoot.loadValue(settingKey, defaultValue)
                settingsRoot.currentBackend = value
            }
        }

        Component.onCompleted: {
            settingsRoot.detectBackends()
            loadValue()
        }

        StyledText {
            text: "Local backend"
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.Medium
            color: Theme.surfaceText
        }

        StyledText {
            text: settingsRoot.backendMeta[backendSelect.value]
                  ? settingsRoot.backendMeta[backendSelect.value].desc : ""
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            width: parent.width
            wrapMode: Text.WordWrap
        }

        DankDropdown {
            width: parent.width
            currentValue: backendSelect.value
            options: backendSelect.options
            onValueChanged: newValue => {
                backendSelect.value = newValue
                settingsRoot.currentBackend = newValue
                settingsRoot.saveValue(backendSelect.settingKey, newValue)
            }
        }

        StyledText {
            visible: backendSelect.options.length <= 1
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Install faster-whisper (whisper-ctranslate2) to add the fastest CPU engine — see the README for the command."
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
        }
    }

    // Groups a section's settings into a titled card so the page reads as
    // distinct panels instead of one long undivided list. Children are laid
    // out in an inner column.
    //
    // PluginSettings reloads persisted values by calling loadValue() on each of
    // its DIRECT children whenever pluginService appears or plugin data changes.
    // Nesting settings inside a card makes them grandchildren, so we forward
    // that call down: without this, components that only self-load in their own
    // Component.onCompleted (SelectionSetting, ListSettingWithInput) can miss
    // the load — pluginService isn't always ready that early — and then persist
    // their default over the stored value on the next edit.
    component Card: StyledRect {
        id: card

        property string title: ""
        default property alias content: cardContent.children

        function loadValue() {
            _cascadeLoad(cardContent)
        }

        function _cascadeLoad(item) {
            const kids = item.children
            for (let i = 0; i < kids.length; i++) {
                const c = kids[i]
                if (!c)
                    continue
                if (c.loadValue !== undefined)
                    c.loadValue()
                else if (c.children !== undefined)
                    _cascadeLoad(c)
            }
        }

        width: parent.width
        height: cardColumn.implicitHeight + Theme.spacingL * 2
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh
        border.width: 0

        Column {
            id: cardColumn
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingM

            StyledText {
                width: parent.width
                text: card.title
                font.pixelSize: Theme.fontSizeLarge
                font.weight: Font.Bold
                color: Theme.surfaceText
                visible: card.title !== ""
            }

            Column {
                id: cardContent
                width: parent.width
                spacing: Theme.spacingM
            }
        }
    }

    function fetchAiModels() {
        Proc.runCommand("whisperer.aiModels",
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
                                console.warn("Whisperer: failed to parse OpenRouter model list:", e)
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
        Proc.runCommand("whisperer.scanModels",
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
        Proc.runCommand("whisperer.download." + model.name,
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
                                Proc.runCommand("whisperer.cleanupPart." + model.name,
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
        Proc.runCommand("whisperer.cancel." + model.name,
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
        Proc.runCommand("whisperer.delete." + model.name,
                        ["rm", "-f", modelFullPath(model.name)],
                        () => refresh())
    }

    function selectModel(model) {
        PluginService.savePluginData(pluginId, "modelPath", modelFullPath(model.name))
        activeModelPath = modelFullPath(model.name)
    }

    // ── faster-whisper model manager ────────────────────────────────────────
    // faster-whisper (whisper-ctranslate2) caches its own models by name, but we
    // manage explicit copies under fwDir so they can be downloaded, selected and
    // deleted like the whisper.cpp files. The transcriber prefers fwDir/<name>
    // via --model_directory, falling back to the tool's own fetch when absent.
    readonly property string fwDir: home + "/.local/share/whisperer/faster-whisper"
    readonly property string fwHfBase: "https://huggingface.co/Systran/faster-whisper-"

    // model.bin bytes drive the progress bar; the other files are a few MB and
    // download first. Sizes are the current Systran repo blobs.
    readonly property var fwCatalog: [
        { name: "tiny.en",   desc: "Fastest, English",            mb: 75,   bytes: 75537502 },
        { name: "tiny",      desc: "Fastest, multilingual",       mb: 75,   bytes: 75538270 },
        { name: "base.en",   desc: "Balanced, English (default)", mb: 145,  bytes: 145216508 },
        { name: "base",      desc: "Balanced, multilingual",      mb: 145,  bytes: 145217532 },
        { name: "small.en",  desc: "More accurate, English",      mb: 484,  bytes: 483545366 },
        { name: "small",     desc: "More accurate, multilingual", mb: 484,  bytes: 483546902 },
        { name: "medium.en", desc: "Most accurate, English",      mb: 1528, bytes: 1527904330 },
        { name: "medium",    desc: "Most accurate, multilingual", mb: 1528, bytes: 1527906378 },
        { name: "large-v3",  desc: "Highest accuracy, slow",      mb: 3087, bytes: 3087284237 }
    ]

    property var fwInstalled: []          // model names with a local model.bin
    property var fwDownloadPercent: ({})  // name → percent; -1 = just started
    property var fwCancelling: ({})
    property string fwSelected: "base.en" // mirrors the ctModel setting

    function fwModelDir(name) {
        return fwDir + "/" + name
    }

    // pgrep/pkill pattern matching this download's shell + curls (their args
    // carry the "<name>.part" tmp path) but never the probe itself; the ".part"
    // suffix is a terminator so "base" can't match "base.en"
    function fwProbe(name) {
        const base = "faster-whisper/" + name + ".part"
        return ("[" + base[0] + "]" + base.slice(1)).replace(/\./g, "\\.")
    }

    function fwIsInstalled(name) {
        return fwInstalled.indexOf(name) !== -1
    }

    function fwIsDownloading(name) {
        return fwDownloadPercent[name] !== undefined
    }

    function fwShownPercent(name) {
        return Math.max(0, fwDownloadPercent[name] !== undefined ? fwDownloadPercent[name] : 0)
    }

    function fwRefresh() {
        fwSelected = PluginService.loadPluginData(pluginId, "ctModel", "base.en")
        Proc.runCommand("whisperer.fw.scan",
                        ["sh", "-c",
                         "for d in '" + fwDir + "'/*/; do [ -f \"$d/model.bin\" ] && basename \"$d\"; done 2>/dev/null; "
                         + "for d in '" + fwDir + "'/*.part; do [ -d \"$d\" ] && echo \"PART:$(basename \"$d\" .part)\"; done 2>/dev/null; true"],
                        (out, code) => {
                            const installed = []
                            const parts = []
                            for (const line of (out || "").trim().split("\n")) {
                                if (line.length === 0)
                                    continue
                                if (line.indexOf("PART:") === 0)
                                    parts.push(line.slice(5))
                                else
                                    installed.push(line)
                            }
                            fwInstalled = installed
                            const updated = Object.assign({}, fwDownloadPercent)
                            let changed = false
                            for (const name of parts) {
                                if (updated[name] === undefined && fwCatalog.some(m => m.name === name)) {
                                    updated[name] = 0
                                    changed = true
                                }
                            }
                            if (changed)
                                fwDownloadPercent = updated
                        })
    }

    function fwDownload(model) {
        const updated = Object.assign({}, fwDownloadPercent)
        updated[model.name] = -1
        fwDownloadPercent = updated

        const dir = fwModelDir(model.name)
        const tmp = dir + ".part"
        const base = fwHfBase + model.name + "/resolve/main"
        // Pull the runtime files into a .part dir, then atomically swap in. The
        // small required files come first; model.bin is last so the progress bar
        // tracks the dominant download. vocabulary is .txt or .json depending on
        // the model; preprocessor_config.json exists only for some.
        const script =
              'tmp="$1"; base="$2"; dir="$3"; rm -rf "$tmp"; mkdir -p "$tmp" || exit 1; '
            + 'for f in config.json tokenizer.json model.bin; do '
            +   'curl -L -sS -f -o "$tmp/$f" "$base/$f" || { rm -rf "$tmp"; exit 1; }; done; '
            + 'curl -L -sS -f -o "$tmp/vocabulary.txt" "$base/vocabulary.txt" '
            +   '|| curl -L -sS -f -o "$tmp/vocabulary.json" "$base/vocabulary.json" '
            +   '|| { rm -rf "$tmp"; exit 1; }; '
            + 'curl -L -sS -f -o "$tmp/preprocessor_config.json" "$base/preprocessor_config.json" 2>/dev/null || true; '
            + 'rm -rf "$dir"; mv "$tmp" "$dir"'
        Proc.runCommand("whisperer.fw.download." + model.name,
                        ["sh", "-c", script, "whisperer", tmp, base, dir],
                        (out, code) => {
                            const done = Object.assign({}, fwDownloadPercent)
                            delete done[model.name]
                            fwDownloadPercent = done
                            const wasCancelled = fwCancelling[model.name] === true
                            const c = Object.assign({}, fwCancelling)
                            delete c[model.name]
                            fwCancelling = c
                            if (code === 0) {
                                if (typeof ToastService !== "undefined")
                                    ToastService.showInfo(model.name + " downloaded")
                            } else if (!wasCancelled) {
                                if (typeof ToastService !== "undefined")
                                    ToastService.showError("Download of " + model.name + " failed")
                            }
                            fwRefresh()
                        },
                        50, Proc.noTimeout)
    }

    function fwCancel(model) {
        const c = Object.assign({}, fwCancelling)
        c[model.name] = true
        fwCancelling = c
        Proc.runCommand("whisperer.fw.cancel." + model.name,
                        ["sh", "-c", "pkill -f '" + fwProbe(model.name) + "'; rm -rf '" + fwModelDir(model.name) + ".part'"],
                        (out, code) => {
                            const done = Object.assign({}, fwDownloadPercent)
                            delete done[model.name]
                            fwDownloadPercent = done
                            fwRefresh()
                        })
    }

    function fwDelete(model) {
        Proc.runCommand("whisperer.fw.delete." + model.name,
                        ["rm", "-rf", fwModelDir(model.name)],
                        () => fwRefresh())
    }

    function fwSelect(model) {
        PluginService.savePluginData(pluginId, "ctModel", model.name)
        fwSelected = model.name
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
                console.warn("Whisperer: failed to parse Gemini model list:", e)
            }
        }
    }

    function fetchGoogleModels() {
        if (googleModelFetch.running)
            return
        Proc.runCommand("whisperer.key.googleFetch",
                        ["secret-tool", "lookup", "service", "whisperer", "key", "googleApiKey"],
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
            if (pluginId !== settingsRoot.pluginId)
                return
            settingsRoot.loadModelWarningState()
            if (!settingsRoot.googleModelsLive)
                settingsRoot.fetchGoogleModels()
        }
    }

    Component.onCompleted: {
        refresh()
        fwRefresh()
        loadModelWarningState()
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
                Proc.runCommand("whisperer.progress." + name,
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
                                        Proc.runCommand("whisperer.orphan." + name,
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

    // faster-whisper's counterpart of progressTimer: polls the in-flight
    // model.bin size in the .part dir. The download shell carries the ".part"
    // path in its args, so fwProbe matches it for the whole run — no false
    // orphan during the brief gaps between the small-file curls.
    Timer {
        id: fwProgressTimer
        interval: 500
        repeat: true
        running: Object.keys(settingsRoot.fwDownloadPercent).length > 0
        onTriggered: {
            for (const name of Object.keys(settingsRoot.fwDownloadPercent)) {
                const entry = settingsRoot.fwCatalog.find(m => m.name === name)
                if (!entry)
                    continue
                if (settingsRoot.fwDownloadPercent[name] === -1) {
                    // grace tick: the download shell may not have spawned yet
                    const updated = Object.assign({}, settingsRoot.fwDownloadPercent)
                    updated[name] = 0
                    settingsRoot.fwDownloadPercent = updated
                    continue
                }
                const binPath = settingsRoot.fwModelDir(name) + ".part/model.bin"
                Proc.runCommand("whisperer.fw.progress." + name,
                                ["sh", "-c",
                                 "stat -c %s '" + binPath + "' 2>/dev/null || echo 0; " +
                                 "pgrep -fc '" + settingsRoot.fwProbe(name) + "' 2>/dev/null || echo 0"],
                                (out, code) => {
                                    if (settingsRoot.fwDownloadPercent[name] === undefined)
                                        return
                                    const lines = out.trim().split("\n")
                                    const size = parseInt(lines[0] || "0") || 0
                                    const alive = (parseInt(lines[1] || "0") || 0) > 0
                                    if (!alive) {
                                        // Orphaned .part (shell died mid-download):
                                        // clean up unless the model actually landed
                                        const done = Object.assign({}, settingsRoot.fwDownloadPercent)
                                        delete done[name]
                                        settingsRoot.fwDownloadPercent = done
                                        Proc.runCommand("whisperer.fw.orphan." + name,
                                                        ["sh", "-c",
                                                         "rm -rf '" + settingsRoot.fwModelDir(name) + ".part'; test -f '" + settingsRoot.fwModelDir(name) + "/model.bin' && echo ok || echo gone"],
                                                        (res, rc) => {
                                                            if (res.trim() !== "ok" && typeof ToastService !== "undefined")
                                                                ToastService.showError(name + " download was interrupted")
                                                            settingsRoot.fwRefresh()
                                                        })
                                        return
                                    }
                                    const updated = Object.assign({}, settingsRoot.fwDownloadPercent)
                                    updated[name] = Math.min(99, Math.round(size / entry.bytes * 100))
                                    settingsRoot.fwDownloadPercent = updated
                                })
            }
        }
    }

    StyledText {
        width: parent.width
        text: "Right-click the mic in the bar for a quick toggle, left-click it to open the popout and hit Record, or run `dms ipc call whisperer toggle` (bind it to any free key you like), to dictate. Text is typed at the focused cursor when transcription finishes. `dms ipc call whisperer toggleAi` dictates via an AI provider instead (configured below)."
        font.pixelSize: Theme.fontSizeMedium
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    // ── Transcription ──────────────────────────────────────────────────────

    Card {
        title: "Transcription"

        BackendDetection {}

        BackendSelect {
            settingKey: "backend"
            defaultValue: "whisper.cpp"
        }

        // whisper.cpp downloads and manages its model files locally; the CLI
        // backends handle their own, so this shows only for whisper.cpp.
        WhisperCppModels {
            visible: settingsRoot.currentBackend === "whisper.cpp"
        }

        // faster-whisper's downloadable model manager (cached indicator +
        // download/delete), shown when that backend is selected.
        FasterWhisperModels {
            visible: settingsRoot.currentBackend !== "whisper.cpp"
        }

        // English-only (.en) model paired with a non-English language or the
        // translate toggle: warn, because it silently produces garbage.
        StyledRect {
            visible: settingsRoot.englishOnlyMismatch
            width: parent.width
            height: warnText.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadius
            color: Qt.alpha(Theme.warning, 0.15)

            DankIcon {
                id: warnIcon
                name: "warning"
                size: Theme.iconSize - 4
                color: Theme.warning
                anchors.left: parent.left
                anchors.leftMargin: Theme.spacingM
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                id: warnText
                anchors.left: warnIcon.right
                anchors.leftMargin: Theme.spacingS
                anchors.right: parent.right
                anchors.rightMargin: Theme.spacingM
                anchors.verticalCenter: parent.verticalCenter
                wrapMode: Text.WordWrap
                text: "“" + settingsRoot.selectedLocalModel + "” is English-only. Non-English speech and translate-to-English need a multilingual model — pick one without “.en” (e.g. small)."
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceText
            }
        }

        SelectionSetting {
            settingKey: "language"
            label: "Language"
            description: "Anything other than English requires a multilingual model (e.g. small)"
            options: [
                {label: "English", value: "en"},
                {label: "Auto-detect", value: "auto"},
                {label: "Spanish", value: "es"},
                {label: "French", value: "fr"},
                {label: "German", value: "de"}
            ]
            defaultValue: "en"
        }

        ToggleSetting {
            settingKey: "translateToEnglish"
            label: "Translate to English"
            description: "Output the dictation in English instead of the spoken language — whisper's translate task locally, and the AI model is instructed to translate"
            defaultValue: false
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
    }

    // ── AI cleanup ─────────────────────────────────────────────────────────

    Card {
        title: "AI cleanup"

        StyledText {
            width: parent.width
            text: "Run `dms ipc call whisperer toggleAi` (bind it to a key of your choice) and the audio recording is sent straight to an audio-capable model, which transcribes and formats it in one pass — rambling in, clear formatted text out. Your custom vocabulary and snippet triggers are included in the prompt, and snippets expand here too when the whole dictation matches a trigger. Triggering AI dictation while already recording also finishes the current recording with AI transcription. On failure it falls back to local whisper. Configure each provider in its tab, then pick which one is active below."
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            wrapMode: Text.WordWrap
        }

        // DankTabBar draws its underline ~10px below its own height, outside
        // its layout bounds, so the column reserves no space for it. Wrap it
        // so the card leaves room for the underline plus a margin before the
        // provider fields below.
        Item {
            width: parent.width
            height: providerTabs.height + Theme.spacingL

            DankTabBar {
                id: providerTabs
                width: Math.min(320, parent.width)
                model: [
                    { text: "OpenRouter", icon: "hub" },
                    { text: "Google", icon: "cloud" }
                ]
                Component.onCompleted: {
                    currentIndex = PluginService.loadPluginData(settingsRoot.pluginId, "aiProvider", "openrouter") === "google" ? 1 : 0
                }
                onTabClicked: index => currentIndex = index
            }
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
            description: "Which provider AI dictation (toggleAi) uses"
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
    }

    // ── Snippets & vocabulary ──────────────────────────────────────────────

    Card {
        title: "Snippets & vocabulary"

        ListSettingWithInput {
            settingKey: "snippets"
            label: "Voice snippets"
            description: "Speak a trigger phrase on its own and the full text is typed instead of the transcript. Works with both local and AI dictation; the whole dictation must match the trigger, ignoring case and punctuation. Use \\n in the text for a line break."
            defaultValue: []
            fields: [
                {id: "trigger", label: "Trigger phrase", placeholder: "sign off", width: 160, required: true},
                {id: "text", label: "Text to type", placeholder: "Best regards,\\nDaniel", width: 300, required: true}
            ]
        }

        ListSettingWithInput {
            settingKey: "customWords"
            label: "Custom vocabulary"
            description: "Names, jargon, and unusual spellings the transcriber should know. Fed to whisper as an initial prompt — keep the list short (a few dozen words) for best effect."
            defaultValue: []
            fields: [
                {id: "word", label: "Word or phrase", placeholder: "DankMaterialShell", width: 280, required: true}
            ]
        }
    }

    // ── Recording ──────────────────────────────────────────────────────────

    Card {
        title: "Recording"

        ToggleSetting {
            settingKey: "autoStopEnabled"
            label: "Auto-stop on silence"
            description: "Stop dictation automatically after a stretch of silence. Only arms once you've actually said something, so it won't cut off a slow start. When off, recording keeps going until you stop it — click the recording overlay, right-click the pill, hit Stop in the popout, or trigger your keybind again (5 minute cap either way)."
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
    }

}
