import QtQuick
import Quickshell
import qs.Common
import qs.Modules.Plugins
import qs.Services
import qs.Widgets

// Bar-widget half of the composite plugin: a "tray"-style control for VoxType.
// The pill reflects VoxType's state (published by OverlayDaemon via a plugin
// global var), left-click toggles dictation, right/middle-click opens a control
// popout with daemon controls, output-mode + microphone pickers, and the
// overlay master toggle.
//
// Config-mutating actions (output mode, mic device) go through the bundled
// scripts/voxtype-config-set helper — a section-aware TOML editor — never a
// blind append, then restart the daemon so the change takes effect.
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

    // ── Current VoxType config (refreshed when the popout opens) ───────────────
    property string currentMode: "type"      // type | clipboard | paste
    property string currentDevice: "default"
    property var micList: []
    property bool outputExpanded: false
    property bool micExpanded: false

    // Bundled TOML editor. DMS always loads plugins from <config>/DankMaterialShell
    // /plugins/<id>/, so resolve the helper there (works through the dev symlink).
    readonly property string configSetScript: {
        const cfg = Quickshell.env("XDG_CONFIG_HOME") || ((Quickshell.env("HOME") || "") + "/.config");
        return cfg + "/DankMaterialShell/plugins/" + pluginId + "/scripts/voxtype-config-set";
    }

    // ── Simple actions (fire-and-forget) ──────────────────────────────────────
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

    // ── Config-mutating actions (section-aware editor, then restart) ───────────
    function _applyConfig(section, key, value) {
        Proc.runCommand("voxtypeOverlay.cfgset", ["sh", root.configSetScript, section, key, value], (out, exit) => {
            root.svc("restart");
        }, 0);
    }
    function setOutputMode(mode) {
        if (mode !== root.currentMode) {
            root.currentMode = mode;           // optimistic; refreshed on next open
            root._applyConfig("output", "mode", mode);
        }
        closePopout();
    }
    function setMic(name) {
        if (name !== root.currentDevice) {
            root.currentDevice = name;
            root._applyConfig("audio", "device", name);
        }
        closePopout();
    }

    // ── Reads (parse `voxtype config` + `pactl`) ───────────────────────────────
    function refreshConfig() {
        Proc.runCommand("voxtypeOverlay.cfgget", ["voxtype", "config"], (out, exit) => {
            if (exit !== 0 || !out)
                return;
            let sec = "";
            let mode = root.currentMode;
            let dev = root.currentDevice;
            const lines = out.split("\n");
            for (let i = 0; i < lines.length; i++) {
                const line = lines[i].trim();
                const hdr = line.match(/^\[([^\]]+)\]/);
                if (hdr) { sec = hdr[1]; continue; }
                if (sec === "output") {
                    const mm = line.match(/^mode\s*=\s*"?([A-Za-z]+)"?/);
                    if (mm) mode = mm[1].toLowerCase();
                } else if (sec === "audio") {
                    const dm = line.match(/^device\s*=\s*"?([^"]+)"?\s*$/);
                    if (dm) dev = dm[1].trim();
                }
            }
            root.currentMode = mode;
            root.currentDevice = dev;
        }, 0);
    }
    function refreshMics() {
        Proc.runCommand("voxtypeOverlay.mics", ["pactl", "-f", "json", "list", "sources"], (out, exit) => {
            const list = [{ name: "default", label: "System default" }];
            if (exit === 0 && out) {
                try {
                    const arr = JSON.parse(out);
                    for (let i = 0; i < arr.length; i++) {
                        const s = arr[i];
                        if (!s || !s.name || s.name.endsWith(".monitor"))
                            continue;
                        list.push({ name: s.name, label: (s.description && s.description !== "") ? s.description : root.deviceLabel(s.name) });
                    }
                } catch (e) {
                    // malformed JSON → leave just "System default"
                }
            }
            root.micList = list;
        }, 0);
    }
    // Friendly label for a device name: its PipeWire description if we have it,
    // else a cleaned-up form of the raw source id.
    function micLabelFor(name) {
        if (name === "default")
            return "System default";
        for (let i = 0; i < micList.length; i++)
            if (micList[i].name === name)
                return micList[i].label;
        return deviceLabel(name);
    }
    function refreshAll() {
        refreshConfig();
        refreshMics();
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
        if (recording) return Theme.primary;
        if (voxState === "stopped" || voxState === "") return Theme.errorText;
        return Theme.surfaceText;
    }
    function stateIcon() {
        if (voxState === "transcribing") return "graphic_eq";
        if (voxState === "stopped" || voxState === "") return "mic_off";
        return "mic";
    }
    function modeLabel(m) {
        switch (m) {
        case "type": return "Active window";
        case "clipboard": return "Clipboard";
        case "paste": return "Paste";
        default: return m;
        }
    }
    function deviceLabel(name) {
        if (name === "default") return "System default";
        return name.replace(/^alsa_(input|output)\./, "").replace(/\.(mono-fallback|analog-stereo|analog-mono|iec958-stereo)$/, "").replace(/_/g, " ");
    }

    // ── Daemon-control menu model ─────────────────────────────────────────────
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

    readonly property var outputModes: [
        { v: "type", l: "Active window" },
        { v: "clipboard", l: "Clipboard" },
        { v: "paste", l: "Paste" }
    ]

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
                    if (mouse.button === Qt.LeftButton) {
                        root.recordToggle();
                    } else {
                        root.refreshAll();
                        root.triggerPopout();
                    }
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
                    if (mouse.button === Qt.LeftButton) {
                        root.recordToggle();
                    } else {
                        root.refreshAll();
                        root.triggerPopout();
                    }
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
    popoutWidth: 268
    readonly property int _rowH: 40
    readonly property int _choiceH: 34
    popoutHeight: 92
        + menuActions.length * _rowH
        + 36 + (outputExpanded ? outputModes.length * _choiceH : 0)
        + 36 + (micExpanded ? Math.min(micList.length, 6) * _choiceH : 0)
        + 12 + _rowH + 12

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
                        height: root._rowH
                        radius: Theme.cornerRadius
                        color: rowMouse.containsMouse ? Theme.primaryHoverLight : "transparent"
                        Behavior on color { ColorAnimation { duration: Theme.shorterDuration; easing.type: Theme.standardEasing } }

                        Row {
                            anchors.left: parent.left
                            anchors.leftMargin: Theme.spacingM
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.spacingS
                            DankIcon { name: modelData.icon; size: 18; color: Theme.surfaceText; anchors.verticalCenter: parent.verticalCenter }
                            StyledText { text: modelData.label; font.pixelSize: Theme.fontSizeNormal; color: Theme.surfaceText; anchors.verticalCenter: parent.verticalCenter }
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

                // ── Output mode (expandable) ──────────────────────────────────
                Rectangle {
                    width: parent.width
                    height: root._rowH
                    radius: Theme.cornerRadius
                    color: outHeaderMouse.containsMouse ? Theme.primaryHoverLight : "transparent"
                    Behavior on color { ColorAnimation { duration: Theme.shorterDuration; easing.type: Theme.standardEasing } }
                    Row {
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.spacingM
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.spacingS
                        DankIcon { name: "keyboard"; size: 18; color: Theme.surfaceText; anchors.verticalCenter: parent.verticalCenter }
                        StyledText { text: "Output: " + root.modeLabel(root.currentMode); font.pixelSize: Theme.fontSizeNormal; color: Theme.surfaceText; anchors.verticalCenter: parent.verticalCenter }
                    }
                    DankIcon {
                        anchors.right: parent.right; anchors.rightMargin: Theme.spacingM
                        anchors.verticalCenter: parent.verticalCenter
                        name: root.outputExpanded ? "expand_less" : "expand_more"
                        size: 18; color: Theme.surfaceVariantText
                    }
                    MouseArea {
                        id: outHeaderMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.outputExpanded = !root.outputExpanded
                    }
                }
                Repeater {
                    model: root.outputExpanded ? root.outputModes : []
                    delegate: Rectangle {
                        required property var modelData
                        width: parent.width
                        height: root._choiceH
                        radius: Theme.cornerRadius
                        color: outChoiceMouse.containsMouse ? Theme.primaryHoverLight : "transparent"
                        Behavior on color { ColorAnimation { duration: Theme.shorterDuration; easing.type: Theme.standardEasing } }
                        Row {
                            anchors.left: parent.left; anchors.leftMargin: Theme.spacingM + 26
                            anchors.verticalCenter: parent.verticalCenter; spacing: Theme.spacingS
                            StyledText { text: modelData.l; font.pixelSize: Theme.fontSizeNormal - 1; color: Theme.surfaceText; anchors.verticalCenter: parent.verticalCenter }
                        }
                        DankIcon {
                            visible: modelData.v === root.currentMode
                            anchors.right: parent.right; anchors.rightMargin: Theme.spacingM
                            anchors.verticalCenter: parent.verticalCenter
                            name: "check"; size: 16; color: Theme.primary
                        }
                        MouseArea {
                            id: outChoiceMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.setOutputMode(modelData.v)
                        }
                    }
                }

                // ── Microphone (expandable) ───────────────────────────────────
                Rectangle {
                    width: parent.width
                    height: root._rowH
                    radius: Theme.cornerRadius
                    color: micHeaderMouse.containsMouse ? Theme.primaryHoverLight : "transparent"
                    Behavior on color { ColorAnimation { duration: Theme.shorterDuration; easing.type: Theme.standardEasing } }
                    Row {
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.spacingM
                        anchors.right: expandIcon.left; anchors.rightMargin: Theme.spacingS
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.spacingS
                        DankIcon { name: "settings_voice"; size: 18; color: Theme.surfaceText; anchors.verticalCenter: parent.verticalCenter }
                        StyledText {
                            text: "Mic: " + root.micLabelFor(root.currentDevice)
                            font.pixelSize: Theme.fontSizeNormal; color: Theme.surfaceText
                            elide: Text.ElideRight; width: Math.min(implicitWidth, 150)
                            maximumLineCount: 1; wrapMode: Text.NoWrap
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                    DankIcon {
                        id: expandIcon
                        anchors.right: parent.right; anchors.rightMargin: Theme.spacingM
                        anchors.verticalCenter: parent.verticalCenter
                        name: root.micExpanded ? "expand_less" : "expand_more"
                        size: 18; color: Theme.surfaceVariantText
                    }
                    MouseArea {
                        id: micHeaderMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.micExpanded = !root.micExpanded
                    }
                }
                Repeater {
                    model: root.micExpanded ? root.micList : []
                    delegate: Rectangle {
                        required property var modelData
                        width: parent.width
                        height: root._choiceH
                        radius: Theme.cornerRadius
                        color: micChoiceMouse.containsMouse ? Theme.primaryHoverLight : "transparent"
                        Behavior on color { ColorAnimation { duration: Theme.shorterDuration; easing.type: Theme.standardEasing } }
                        StyledText {
                            anchors.left: parent.left; anchors.leftMargin: Theme.spacingM + 26
                            anchors.right: micCheck.left; anchors.rightMargin: Theme.spacingS
                            anchors.verticalCenter: parent.verticalCenter
                            text: modelData.label
                            font.pixelSize: Theme.fontSizeNormal - 1
                            color: Theme.surfaceText
                            elide: Text.ElideRight
                            maximumLineCount: 1
                            wrapMode: Text.NoWrap
                        }
                        DankIcon {
                            id: micCheck
                            visible: modelData.name === root.currentDevice
                            anchors.right: parent.right; anchors.rightMargin: Theme.spacingM
                            anchors.verticalCenter: parent.verticalCenter
                            name: "check"; size: 16; color: Theme.primary
                        }
                        MouseArea {
                            id: micChoiceMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.setMic(modelData.name)
                        }
                    }
                }

                // Divider.
                Item {
                    width: parent.width
                    height: 12
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
                    height: root._rowH
                    radius: Theme.cornerRadius
                    color: toggleMouse.containsMouse ? Theme.primaryHoverLight : "transparent"
                    Behavior on color { ColorAnimation { duration: Theme.shorterDuration; easing.type: Theme.standardEasing } }
                    Row {
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.spacingM
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.spacingS
                        DankIcon { name: "layers"; size: 18; color: Theme.surfaceText; anchors.verticalCenter: parent.verticalCenter }
                        StyledText { text: "Recording overlay"; font.pixelSize: Theme.fontSizeNormal; color: Theme.surfaceText; anchors.verticalCenter: parent.verticalCenter }
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
