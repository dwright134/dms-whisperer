import QtQuick
import Quickshell
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

    Component.onCompleted: refresh()

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
        text: "Click the mic in the bar, press Mod+Shift+D, or run `dms ipc call penguinWhisperer toggle` to dictate. Text is typed at the focused cursor when transcription finishes."
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
