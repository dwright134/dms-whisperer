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

    // idle | recording | stopping | transcribing | error
    property string sttState: "idle"
    property int elapsedSeconds: 0
    property string pendingText: ""
    property var history: []

    // Settings (persisted via PluginService)
    property string whisperBin: home + "/.local/bin/whisper-cli"
    property string modelPath: home + "/.local/share/penguin-whisperer/models/ggml-base.en.bin"
    property string language: "en"
    property bool typeText: true
    property bool copyText: true
    property bool soundCues: true

    readonly property string modelName: modelPath.split("/").pop().replace("ggml-", "").replace(".bin", "")

    // Overlay state
    readonly property bool overlayActive: sttState === "recording" || sttState === "stopping" || sttState === "transcribing"
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
            startRecording()
    }

    function startRecording() {
        sttState = "recording"
        elapsedSeconds = 0
        recorder.running = true
        playCue("start")
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

    function handleTranscript(rawText) {
        const text = rawText.trim().replace(/\[BLANK_AUDIO\]/g, "").trim()
        sttState = "idle"
        if (text.length === 0) {
            doneKind = "error"
            doneText = "No speech detected"
            doneLingerTimer.restart()
            if (typeof ToastService !== "undefined")
                ToastService.showInfo("Penguin Whisperer: no speech detected")
            return
        }
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
                root.sttState = "transcribing"
                transcriber.running = true
            } else if (root.sttState === "recording") {
                root.fail("recorder exited unexpectedly (code " + exitCode + ")")
            }
        }
    }

    Process {
        id: transcriber
        command: [root.whisperBin,
                  "-m", root.modelPath,
                  "-f", root.recordingPath,
                  "-l", root.language,
                  "-t", "4",
                  "--no-timestamps", "--no-prints"]
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

    // Small delay so the toggle click/hotkey is fully released before typing
    Timer {
        id: typeDelayTimer
        interval: 150
        onTriggered: typer.running = true
    }

    Process {
        id: typer
        command: ["sh", "-c", "printf %s \"$1\" | wtype -", "penguin-whisperer", root.pendingText]
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

        function start(): string {
            if (root.sttState === "idle" || root.sttState === "error")
                root.startRecording()
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

            DankIcon {
                id: hIcon
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

            DankIcon {
                id: vIcon
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

        anchors.bottom: true
        margins.bottom: 48
        implicitWidth: 360
        implicitHeight: 100

        Rectangle {
            id: overlayCard
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: root.overlayShown ? 12 : -8
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

                Row {
                    id: waveform
                    spacing: 3
                    anchors.verticalCenter: parent.verticalCenter

                    Repeater {
                        id: waveRepeater
                        model: 22

                        Rectangle {
                            width: 4
                            height: 6
                            radius: 2
                            color: Theme.error
                            anchors.verticalCenter: parent.verticalCenter

                            Behavior on height {
                                NumberAnimation { duration: 110; easing.type: Easing.OutQuad }
                            }
                        }
                    }

                    Timer {
                        interval: 110
                        repeat: true
                        running: root.sttState === "recording" && overlayWindow.visible
                        onTriggered: {
                            for (let i = 0; i < waveRepeater.count; i++) {
                                const bar = waveRepeater.itemAt(i)
                                if (bar)
                                    bar.height = 5 + Math.random() * 31
                            }
                        }
                        onRunningChanged: {
                            if (!running) {
                                for (let i = 0; i < waveRepeater.count; i++) {
                                    const bar = waveRepeater.itemAt(i)
                                    if (bar)
                                        bar.height = 6
                                }
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
            }

            // Transcribing: bouncing dots + label
            Row {
                anchors.centerIn: parent
                spacing: Theme.spacingM
                visible: root.sttState === "transcribing"

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
                                running: root.sttState === "transcribing" && overlayWindow.visible
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
                    text: "Transcribing (" + root.modelName + ")…"
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
            detailsText: "Local dictation · " + root.modelName + " · Mod+Shift+D"
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
