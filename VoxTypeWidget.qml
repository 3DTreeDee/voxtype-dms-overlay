import QtQuick
import Quickshell
import qs.Common
import qs.Modules.Plugins
import qs.Services
import qs.Widgets

// Bar-widget half of the composite plugin: a "tray"-style control for VoxType.
// The pill reflects VoxType's state (published by OverlayDaemon via a plugin
// global var), left-click toggles dictation, right-click opens a control popout
// with daemon controls and the overlay master toggle.
//
// MVP scope: config-safe actions only (record toggle, start/stop/restart the
// systemd unit, open config in $EDITOR/xdg-open, view logs, overlay on/off).
// Actions that mutate ~/.config/voxtype/config.toml (output mode, mic device)
// are intentionally deferred until they can be done with a TOML-aware editor.
PluginComponent {
    id: root

    pluginId: "voxtypeOverlay"
    pluginService: PluginService

    // ── Shared state (published by the daemon's state-file watch) ─────────────
    readonly property string voxState: voxStateGlobal.value
    readonly property bool recording: voxState === "recording" || voxState === "transcribing"
    readonly property bool overlayEnabled: (pluginData && pluginData.overlayEnabled !== undefined) ? pluginData.overlayEnabled : true

    PluginGlobalVar {
        id: voxStateGlobal
        varName: "voxState"
        defaultValue: "idle"
    }

    // ── Actions (all fire-and-forget; none mutate voxtype's config) ───────────
    function recordToggle() {
        Quickshell.execDetached(["voxtype", "record", "toggle"]);
    }
    function svc(verb) {
        Quickshell.execDetached(["systemctl", "--user", verb, "voxtype.service"]);
    }
    function openConfig() {
        Quickshell.execDetached(["sh", "-c", "xdg-open \"$HOME/.config/voxtype/config.toml\""]);
    }
    function viewLogs() {
        Quickshell.execDetached(["sh", "-c", "journalctl --user -u voxtype.service -n 300 --no-pager > \"${XDG_RUNTIME_DIR:-/tmp}/voxtype-logs.txt\"; xdg-open \"${XDG_RUNTIME_DIR:-/tmp}/voxtype-logs.txt\""]);
    }
    function setOverlayEnabled(on) {
        if (pluginService)
            pluginService.savePluginData(pluginId, "overlayEnabled", on);
    }

    // ── Presentation helpers ──────────────────────────────────────────────────
    function stateLabel() {
        switch (voxState) {
        case "recording": return "Recording";
        case "transcribing": return "Transcribing";
        case "idle": return "Idle";
        case "stopped": return "Not running";
        default: return voxState && voxState.length ? (voxState.charAt(0).toUpperCase() + voxState.slice(1)) : "Unknown";
        }
    }
    function stateColor() {
        if (recording)
            return Theme.primary;
        if (voxState === "stopped" || voxState === "")
            return Theme.errorText;
        return Theme.surfaceText;
    }
    function stateIcon() {
        if (voxState === "transcribing")
            return "graphic_eq";
        if (voxState === "stopped" || voxState === "")
            return "mic_off";
        return "mic";
    }

    // ── Menu model / dispatch ─────────────────────────────────────────────────
    readonly property var menuActions: [
        { icon: "fiber_manual_record", label: "Toggle recording", act: "record" },
        { icon: "play_arrow",          label: "Start daemon",      act: "start" },
        { icon: "stop",                label: "Stop daemon",       act: "stop" },
        { icon: "restart_alt",         label: "Restart daemon",    act: "restart" },
        { icon: "tune",                label: "Open config",       act: "config" },
        { icon: "description",         label: "View logs",         act: "logs" }
    ]
    function dispatch(act) {
        switch (act) {
        case "record":  recordToggle(); break;
        case "start":   svc("start");   break;
        case "stop":    svc("stop");    break;
        case "restart": svc("restart"); break;
        case "config":  openConfig();   break;
        case "logs":    viewLogs();     break;
        }
        closePopout();
    }

    // ── Bar pills ─────────────────────────────────────────────────────────────
    horizontalBarPill: Component {
        Item {
            implicitWidth: pillRow.implicitWidth
            implicitHeight: pillRow.implicitHeight || 24

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                cursorShape: Qt.PointingHandCursor
                onClicked: function (mouse) {
                    if (mouse.button === Qt.LeftButton)
                        root.recordToggle();
                    else
                        root.triggerPopout();
                }
            }

            Row {
                id: pillRow
                spacing: Theme.spacingXS
                anchors.centerIn: parent

                DankIcon {
                    id: pillIcon
                    name: root.stateIcon()
                    size: Theme.barIconSize(root.barThickness, -2)
                    color: root.stateColor()
                    anchors.verticalCenter: parent.verticalCenter
                }
                StyledText {
                    visible: root.recording
                    text: root.voxState === "transcribing" ? "…" : "REC"
                    color: root.stateColor()
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Bold
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            // Pulse the icon while recording (mirrors the overlay's mic pulse).
            SequentialAnimation {
                running: root.recording
                loops: Animation.Infinite
                NumberAnimation { target: pillIcon; property: "opacity"; from: 1.0; to: 0.4; duration: 700; easing.type: Easing.InOutSine }
                NumberAnimation { target: pillIcon; property: "opacity"; from: 0.4; to: 1.0; duration: 700; easing.type: Easing.InOutSine }
            }
            Binding {
                target: pillIcon
                property: "opacity"
                value: 1.0
                when: !root.recording
            }
        }
    }

    verticalBarPill: Component {
        Item {
            width: parent ? parent.width : 24
            implicitHeight: vIcon.implicitHeight + Theme.spacingXS * 2

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                cursorShape: Qt.PointingHandCursor
                onClicked: function (mouse) {
                    if (mouse.button === Qt.LeftButton)
                        root.recordToggle();
                    else
                        root.triggerPopout();
                }
            }

            DankIcon {
                id: vIcon
                name: root.stateIcon()
                size: Theme.barIconSize(root.barThickness, -2)
                color: root.stateColor()
                anchors.centerIn: parent
            }
            SequentialAnimation {
                running: root.recording
                loops: Animation.Infinite
                NumberAnimation { target: vIcon; property: "opacity"; from: 1.0; to: 0.4; duration: 700; easing.type: Easing.InOutSine }
                NumberAnimation { target: vIcon; property: "opacity"; from: 0.4; to: 1.0; duration: 700; easing.type: Easing.InOutSine }
            }
            Binding {
                target: vIcon
                property: "opacity"
                value: 1.0
                when: !root.recording
            }
        }
    }

    // ── Control popout (right-click / middle-click) ───────────────────────────
    popoutWidth: 260
    popoutHeight: 128 + root.menuActions.length * 42 + 56

    popoutContent: Component {
        PopoutComponent {
            width: root.popoutWidth
            headerText: "VoxType"
            detailsText: root.stateLabel()
            showCloseButton: false
            closePopout: () => root.closePopout()

            Column {
                width: parent.width
                spacing: Theme.spacingXXS

                // Daemon-control actions.
                Repeater {
                    model: root.menuActions
                    delegate: Rectangle {
                        required property var modelData
                        width: parent.width
                        height: 40
                        radius: Theme.cornerRadius
                        color: rowMouse.containsMouse ? Theme.primaryHoverLight : "transparent"
                        Behavior on color { ColorAnimation { duration: Theme.shorterDuration; easing.type: Theme.standardEasing } }

                        Row {
                            anchors.left: parent.left
                            anchors.leftMargin: Theme.spacingM
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.spacingS
                            DankIcon {
                                name: modelData.icon
                                size: 18
                                color: Theme.surfaceText
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            StyledText {
                                text: modelData.label
                                font.pixelSize: Theme.fontSizeNormal
                                color: Theme.surfaceText
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }

                        MouseArea {
                            id: rowMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.dispatch(modelData.act)
                        }
                    }
                }

                // Divider.
                Item {
                    width: parent.width
                    height: 10
                    Rectangle {
                        width: parent.width - Theme.spacingM
                        height: 1
                        color: Theme.withAlpha(Theme.outline, 0.12)
                        anchors.centerIn: parent
                    }
                }

                // Overlay master toggle (writes this plugin's own settings).
                Rectangle {
                    width: parent.width
                    height: 40
                    radius: Theme.cornerRadius
                    color: toggleMouse.containsMouse ? Theme.primaryHoverLight : "transparent"
                    Behavior on color { ColorAnimation { duration: Theme.shorterDuration; easing.type: Theme.standardEasing } }

                    Row {
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.spacingM
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.spacingS
                        DankIcon {
                            name: "layers"
                            size: 18
                            color: Theme.surfaceText
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        StyledText {
                            text: "Recording overlay"
                            font.pixelSize: Theme.fontSizeNormal
                            color: Theme.surfaceText
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                    DankIcon {
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.spacingM
                        anchors.verticalCenter: parent.verticalCenter
                        name: root.overlayEnabled ? "toggle_on" : "toggle_off"
                        size: 24
                        color: root.overlayEnabled ? Theme.primary : Theme.surfaceVariantText
                    }

                    MouseArea {
                        id: toggleMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.setOverlayEnabled(!root.overlayEnabled)
                    }
                }
            }
        }
    }
}
