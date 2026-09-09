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
    readonly property bool widgetAutoPaste: (pluginData && pluginData.widgetAutoPaste !== undefined) ? pluginData.widgetAutoPaste : false
    readonly property bool engineSwitcherEnabled: (pluginData && pluginData.engineSwitcherEnabled !== undefined) ? pluginData.engineSwitcherEnabled : true
    readonly property bool meetingEnabled: (pluginData && pluginData.meetingEnabled !== undefined) ? pluginData.meetingEnabled : false
    // Auditor toggle state (read live from pluginData; written by setAuditorEnabled).
    readonly property bool auditorEnabled_: (pluginData && pluginData.auditorEnabled !== undefined) ? pluginData.auditorEnabled : false

    PluginGlobalVar {
        id: voxStateGlobal
        varName: "voxState"
        defaultValue: "idle"
    }

    // ── Current VoxType config (refreshed when the popout opens) ───────────────
    property string currentMode: "type"      // type | clipboard | paste
    property string currentDevice: "default"
    property string currentEngine: ""
    property var micList: []
    property var engineList: []               // ~/.config/voxtype/use-*.sh presets
    property bool outputExpanded: false
    property bool micExpanded: false
    property bool engineExpanded: false
    // Meeting state (parsed from `voxtype meeting status`; text-only, no JSON).
    property bool meetingActive: false
    property bool meetingPaused: false
    property bool meetingExpanded: false
    // Left-click during a meeting opens a focused pause/stop dropdown instead of
    // starting a quick capture.
    property bool meetingQuickMode: false
    // True from the moment "Start meeting" is clicked until the daemon reports it
    // active (VoxType takes a second or two). During this window the pill shows a
    // "starting" icon and left-click is blocked from starting a manual recording.
    property bool meetingStarting: false
    readonly property bool meetingBusy: meetingActive || meetingStarting
    onMeetingActiveChanged: {
        if (meetingActive)
            meetingStarting = false;
        else
            meetingQuickMode = false;

        // Sync con el daemon: escribir pluginData.auditorMeetingActive para que
        // el OverlayDaemon (que lo lee) dispare startAuditor()/stopAuditor().
        if (typeof pluginService !== "undefined" && pluginService)
            pluginService.savePluginData(pluginId, "auditorMeetingActive", meetingActive);
    }
    // Pill pulses while dictating, or while a meeting is actively running.
    readonly property bool pillPulsing: recording || (meetingActive && !meetingPaused)

    // Bundled TOML editor. DMS always loads plugins from <config>/DankMaterialShell
    // /plugins/<id>/, so resolve the helper there (works through the dev symlink).
    readonly property string configSetScript: {
        const cfg = Quickshell.env("XDG_CONFIG_HOME") || ((Quickshell.env("HOME") || "") + "/.config");
        return cfg + "/DankMaterialShell/plugins/" + pluginId + "/scripts/voxtype-config-set";
    }

    // ── Simple actions (fire-and-forget) ──────────────────────────────────────
    // Quick capture: starting from the widget shows a mic-only overlay and sends
    // output to the clipboard (or auto-paste) — there's no target window when you
    // click the bar. The captureMode global var tells the daemon to go mic-only;
    // the daemon clears it when recording ends. Stop is a plain toggle.
    function pillToggle() {
        if (root.recording) {
            Quickshell.execDetached(["voxtype", "record", "toggle"]);
        } else {
            if (pluginService)
                pluginService.savePluginData(pluginId, "captureMode", "widget");
            Quickshell.execDetached(["voxtype", "record", "toggle", root.widgetAutoPaste ? "--paste" : "--clipboard"]);
        }
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
    // Toggle del auditor: activa/desactiva el análisis en vivo + swap de modelo.
    function setAuditorEnabled(on) {
        if (pluginService)
            pluginService.savePluginData(pluginId, "auditorEnabled", on);
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
            let eng = root.currentEngine;
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
                } else if (sec === "engine") {
                    const em = line.match(/^engine\s*=\s*"?([A-Za-z]+)"?/);
                    if (em) eng = em[1].toLowerCase();
                }
            }
            root.currentMode = mode;
            root.currentDevice = dev;
            root.currentEngine = eng;
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
    // Engine switching is machine-specific (it can require swapping the VoxType
    // binary variant, not just the config `engine` key), so — like the tray app
    // — we drive it through the user's own ~/.config/voxtype/use-*.sh presets if
    // they exist, and hide the section otherwise. Each script owns the full
    // switch (binary override + config + daemon restart).
    function refreshEngines() {
        Proc.runCommand("voxtypeOverlay.engines", ["sh", "-c", "ls -1 \"$HOME\"/.config/voxtype/use-*.sh 2>/dev/null"], (out, exit) => {
            const list = [];
            if (exit === 0 && out) {
                const lines = out.trim().split("\n");
                for (let i = 0; i < lines.length; i++) {
                    const path = lines[i].trim();
                    if (!path)
                        continue;
                    const base = path.substring(path.lastIndexOf("/") + 1);
                    const m = base.match(/^use-(.+)\.sh$/);
                    if (!m)
                        continue;
                    const words = m[1].split("-");
                    const label = words.map(w => w.charAt(0).toUpperCase() + w.slice(1)).join(" ");
                    list.push({ path: path, label: label });
                }
            }
            root.engineList = list;
        }, 0);
    }
    function setEngine(path) {
        Quickshell.execDetached([path]);   // executable; owns override + config + restart
        closePopout();
    }

    // ── Meeting mode (text-only status; controls are fire-and-forget) ──────────
    function refreshMeeting() {
        Proc.runCommand("voxtypeOverlay.meeting", ["voxtype", "meeting", "status"], (out, exit) => {
            const t = (out || "").toLowerCase();
            root.meetingActive = (exit === 0) && t !== "" && (t.indexOf("no meeting currently in progress") === -1);
            root.meetingPaused = root.meetingActive && (t.indexOf("paus") !== -1);
        }, 0);
    }
    function meetingCmd(args) {
        Quickshell.execDetached(["voxtype", "meeting"].concat(args));
        meetingRefreshTimer.restart();
    }
    function meetingDispatch(act) {
        switch (act) {
        case "start":   root.meetingStarting = true; meetingStartTimeout.restart(); meetingCmd(["start"]); break;
        case "startml": root.meetingStarting = true; meetingStartTimeout.restart(); meetingCmd(["start", "--diarization", "ml"]); break;
        case "pause":   meetingCmd(["pause"]); break;
        case "resume":  meetingCmd(["resume"]); break;
        case "stop":    root.meetingStarting = false; meetingStartTimeout.stop(); meetingCmd(["stop"]); break;
        case "folder":  Quickshell.execDetached(["sh", "-c", "xdg-open \"$HOME/.local/share/voxtype/meetings\""]); break;
        }
        closePopout();
    }
    function meetingStatusLabel() {
        if (root.meetingStarting)
            return "Starting…";
        if (!root.meetingActive)
            return "Idle";
        return root.meetingPaused ? "Paused" : "In progress";
    }

    Timer {
        id: meetingRefreshTimer
        interval: 700
        repeat: false
        onTriggered: root.refreshMeeting()
    }

    // Keep meeting state fresh for the pill (icon + animation) while enabled,
    // even when the popout is closed and regardless of how the meeting started.
    Timer {
        interval: 4000
        running: root.meetingEnabled
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refreshMeeting()
    }
    // While a meeting is starting up, poll faster so the pill flips from
    // "starting" to active promptly.
    Timer {
        interval: 1000
        running: root.meetingStarting
        repeat: true
        onTriggered: root.refreshMeeting()
    }
    // Safety: if a meeting never reports active (start failed), drop the
    // "starting" state after a bit so the pill/left-click return to normal.
    Timer {
        id: meetingStartTimeout
        interval: 15000
        repeat: false
        onTriggered: root.meetingStarting = false
    }

    function refreshAll() {
        refreshConfig();
        refreshMics();
        if (engineSwitcherEnabled)
            refreshEngines();
        else
            engineList = [];
        if (meetingEnabled)
            refreshMeeting();
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
        if (meetingStarting) return Theme.surfaceVariantText;
        if (meetingActive) return Theme.primary;
        if (recording) return Theme.primary;
        if (voxState === "stopped" || voxState === "") return Theme.errorText;
        return Theme.surfaceText;
    }
    function stateIcon() {
        if (meetingStarting) return "pending";
        if (meetingActive) return "groups";
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
        case "record":  pillToggle();  break;
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

    // Contextual meeting controls (full section), recomputed as state changes.
    readonly property var meetingItems: root.meetingBusy
        ? (root.meetingActive
            ? [ (root.meetingPaused ? { icon: "play_arrow", label: "Resume meeting", act: "resume" }
                                    : { icon: "pause", label: "Pause meeting", act: "pause" }),
                { icon: "stop_circle", label: "Stop meeting", act: "stop" },
                { icon: "folder_open", label: "Open meetings folder", act: "folder" } ]
            : [ { icon: "stop_circle", label: "Stop meeting", act: "stop" },
                { icon: "folder_open", label: "Open meetings folder", act: "folder" } ])
        : [ { icon: "groups", label: "Start meeting", act: "start" },
            { icon: "record_voice_over", label: "Start (ML diarization)", act: "startml" },
            { icon: "folder_open", label: "Open meetings folder", act: "folder" } ]

    // Focused controls for the left-click dropdown. While still starting up, only
    // Stop is offered (you can't pause a meeting that isn't active yet).
    readonly property var meetingControlItems: !root.meetingActive
        ? [ { icon: "stop_circle", label: "Stop meeting", act: "stop" } ]
        : (root.meetingPaused
            ? [ { icon: "play_arrow", label: "Resume meeting", act: "resume" },
                { icon: "stop_circle", label: "Stop meeting", act: "stop" } ]
            : [ { icon: "pause", label: "Pause meeting", act: "pause" },
                { icon: "stop_circle", label: "Stop meeting", act: "stop" } ])

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
                        if (root.meetingBusy) {
                            // During (or starting) a meeting, left-click opens a
                            // focused dropdown instead of a quick capture — this
                            // blocks an accidental recording during the ~1-2s
                            // meeting startup window.
                            root.meetingQuickMode = true;
                            root.refreshMeeting();
                            root.triggerPopout();
                        } else {
                            root.pillToggle();
                        }
                    } else {
                        root.meetingQuickMode = false;
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
                running: root.pillPulsing
                loops: Animation.Infinite
                NumberAnimation { target: pillIcon; property: "opacity"; from: 1.0; to: 0.4; duration: 700; easing.type: Easing.InOutSine }
                NumberAnimation { target: pillIcon; property: "opacity"; from: 0.4; to: 1.0; duration: 700; easing.type: Easing.InOutSine }
            }
            Binding {
                target: pillIcon
                property: "opacity"
                value: 1.0
                when: !root.pillPulsing
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
                        if (root.meetingBusy) {
                            // During (or starting) a meeting, left-click opens a
                            // focused dropdown instead of a quick capture — this
                            // blocks an accidental recording during the ~1-2s
                            // meeting startup window.
                            root.meetingQuickMode = true;
                            root.refreshMeeting();
                            root.triggerPopout();
                        } else {
                            root.pillToggle();
                        }
                    } else {
                        root.meetingQuickMode = false;
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
                running: root.pillPulsing
                loops: Animation.Infinite
                NumberAnimation { target: vIcon; property: "opacity"; from: 1.0; to: 0.4; duration: 700; easing.type: Easing.InOutSine }
                NumberAnimation { target: vIcon; property: "opacity"; from: 0.4; to: 1.0; duration: 700; easing.type: Easing.InOutSine }
            }
            Binding {
                target: vIcon
                property: "opacity"
                value: 1.0
                when: !root.pillPulsing
            }
        }
    }

    // ── Control popout (right-click / middle-click) ───────────────────────────
    popoutWidth: 268
    readonly property int _rowH: 40
    readonly property int _choiceH: 34
    popoutHeight: root.meetingQuickMode
        ? (84 + meetingControlItems.length * _rowH)
        : (92
            + menuActions.length * _rowH
            + 36 + (outputExpanded ? outputModes.length * _choiceH : 0)
            + 36 + (micExpanded ? Math.min(micList.length, 6) * _choiceH : 0)
            + ((engineList.length > 0 && engineSwitcherEnabled) ? 36 + (engineExpanded ? engineList.length * _choiceH : 0) : 0)
            + (meetingEnabled ? 36 + (meetingExpanded ? meetingItems.length * _choiceH : 0) : 0)
            + 12 + _rowH + 12)

    popoutContent: Component {
        PopoutComponent {
            width: root.popoutWidth
            headerText: "VoxType"
            detailsText: root.meetingQuickMode ? ("Meeting: " + root.meetingStatusLabel()) : root.stateLabel()
            showCloseButton: false
            closePopout: () => root.closePopout()

            Column {
                width: parent.width
                spacing: 0

                // ── Focused meeting controls (left-click during a meeting) ────
                Column {
                    width: parent.width
                    visible: root.meetingQuickMode
                    spacing: Theme.spacingXXS
                    Repeater {
                        model: root.meetingQuickMode ? root.meetingControlItems : []
                        delegate: Rectangle {
                            required property var modelData
                            width: parent.width
                            height: root._rowH
                            radius: Theme.cornerRadius
                            color: mqMouse.containsMouse ? Theme.primaryHoverLight : "transparent"
                            Behavior on color { ColorAnimation { duration: Theme.shorterDuration; easing.type: Theme.standardEasing } }
                            Row {
                                anchors.left: parent.left; anchors.leftMargin: Theme.spacingM
                                anchors.verticalCenter: parent.verticalCenter; spacing: Theme.spacingS
                                DankIcon { name: modelData.icon; size: 18; color: Theme.surfaceText; anchors.verticalCenter: parent.verticalCenter }
                                StyledText { text: modelData.label; font.pixelSize: Theme.fontSizeNormal; color: Theme.surfaceText; anchors.verticalCenter: parent.verticalCenter }
                            }
                            MouseArea {
                                id: mqMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.meetingDispatch(modelData.act)
                            }
                        }
                    }
                }

                // ── Full control menu (right/middle-click, or no meeting) ─────
                Column {
                    width: parent.width
                    visible: !root.meetingQuickMode
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

                // ── Engine (expandable; only shown if use-*.sh presets exist) ──
                Rectangle {
                    width: parent.width
                    visible: root.engineList.length > 0 && root.engineSwitcherEnabled
                    height: visible ? root._rowH : 0
                    radius: Theme.cornerRadius
                    color: engHeaderMouse.containsMouse ? Theme.primaryHoverLight : "transparent"
                    Behavior on color { ColorAnimation { duration: Theme.shorterDuration; easing.type: Theme.standardEasing } }
                    Row {
                        anchors.left: parent.left; anchors.leftMargin: Theme.spacingM
                        anchors.verticalCenter: parent.verticalCenter; spacing: Theme.spacingS
                        DankIcon { name: "memory"; size: 18; color: Theme.surfaceText; anchors.verticalCenter: parent.verticalCenter }
                        StyledText {
                            text: "Engine: " + (root.currentEngine ? (root.currentEngine.charAt(0).toUpperCase() + root.currentEngine.slice(1)) : "—")
                            font.pixelSize: Theme.fontSizeNormal; color: Theme.surfaceText
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                    DankIcon {
                        anchors.right: parent.right; anchors.rightMargin: Theme.spacingM
                        anchors.verticalCenter: parent.verticalCenter
                        name: root.engineExpanded ? "expand_less" : "expand_more"
                        size: 18; color: Theme.surfaceVariantText
                    }
                    MouseArea {
                        id: engHeaderMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.engineExpanded = !root.engineExpanded
                    }
                }
                Repeater {
                    model: (root.engineList.length > 0 && root.engineExpanded) ? root.engineList : []
                    delegate: Rectangle {
                        required property var modelData
                        width: parent.width
                        height: root._choiceH
                        radius: Theme.cornerRadius
                        color: engChoiceMouse.containsMouse ? Theme.primaryHoverLight : "transparent"
                        Behavior on color { ColorAnimation { duration: Theme.shorterDuration; easing.type: Theme.standardEasing } }
                        StyledText {
                            anchors.left: parent.left; anchors.leftMargin: Theme.spacingM + 26
                            anchors.right: parent.right; anchors.rightMargin: Theme.spacingM
                            anchors.verticalCenter: parent.verticalCenter
                            text: modelData.label
                            font.pixelSize: Theme.fontSizeNormal - 1
                            color: Theme.surfaceText
                            elide: Text.ElideRight; maximumLineCount: 1; wrapMode: Text.NoWrap
                        }
                        MouseArea {
                            id: engChoiceMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.setEngine(modelData.path)
                        }
                    }
                }

                // ── Meeting (expandable; only if enabled in settings) ─────────
                Rectangle {
                    width: parent.width
                    visible: root.meetingEnabled
                    height: visible ? root._rowH : 0
                    radius: Theme.cornerRadius
                    color: meetHeaderMouse.containsMouse ? Theme.primaryHoverLight : "transparent"
                    Behavior on color { ColorAnimation { duration: Theme.shorterDuration; easing.type: Theme.standardEasing } }
                    Row {
                        anchors.left: parent.left; anchors.leftMargin: Theme.spacingM
                        anchors.verticalCenter: parent.verticalCenter; spacing: Theme.spacingS
                        DankIcon { name: "groups"; size: 18; color: root.meetingBusy ? Theme.primary : Theme.surfaceText; anchors.verticalCenter: parent.verticalCenter }
                        StyledText {
                            text: "Meeting: " + root.meetingStatusLabel()
                            font.pixelSize: Theme.fontSizeNormal
                            color: root.meetingBusy ? Theme.primary : Theme.surfaceText
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                    DankIcon {
                        anchors.right: parent.right; anchors.rightMargin: Theme.spacingM
                        anchors.verticalCenter: parent.verticalCenter
                        name: root.meetingExpanded ? "expand_less" : "expand_more"
                        size: 18; color: Theme.surfaceVariantText
                    }
                    MouseArea {
                        id: meetHeaderMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.meetingExpanded = !root.meetingExpanded
                    }
                }
                Repeater {
                    model: (root.meetingEnabled && root.meetingExpanded) ? root.meetingItems : []
                    delegate: Rectangle {
                        required property var modelData
                        width: parent.width
                        height: root._choiceH
                        radius: Theme.cornerRadius
                        color: meetChoiceMouse.containsMouse ? Theme.primaryHoverLight : "transparent"
                        Behavior on color { ColorAnimation { duration: Theme.shorterDuration; easing.type: Theme.standardEasing } }
                        Row {
                            anchors.left: parent.left; anchors.leftMargin: Theme.spacingM + 26
                            anchors.verticalCenter: parent.verticalCenter; spacing: Theme.spacingS
                            DankIcon { name: modelData.icon; size: 16; color: Theme.surfaceText; anchors.verticalCenter: parent.verticalCenter }
                            StyledText { text: modelData.label; font.pixelSize: Theme.fontSizeNormal - 1; color: Theme.surfaceText; anchors.verticalCenter: parent.verticalCenter }
                        }
                        MouseArea {
                            id: meetChoiceMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.meetingDispatch(modelData.act)
                        }
                    }
                }

                // ── Auditor switch (toggle dentro del bloque de reunión) ──────
                // Activa/desactiva el auditor: análisis en vivo de ambos lados +
                // swap automático de modelo al entrar en reunión.
                Rectangle {
                    width: parent.width
                    height: root._rowH
                    radius: Theme.cornerRadius
                    color: auditorRowMouse.containsMouse ? Theme.primaryHoverLight : "transparent"
                    Behavior on color { ColorAnimation { duration: Theme.shorterDuration; easing.type: Theme.standardEasing } }
                    Row {
                        anchors.left: parent.left; anchors.leftMargin: Theme.spacingM + 26
                        anchors.right: parent.right; anchors.rightMargin: Theme.spacingM
                        anchors.verticalCenter: parent.verticalCenter; spacing: Theme.spacingS
                        DankIcon { name: "psychology"; size: 16; color: root.auditorEnabled_ ? Theme.primary : Theme.surfaceText; anchors.verticalCenter: parent.verticalCenter }
                        StyledText {
                            text: "Auditor"
                            font.pixelSize: Theme.fontSizeNormal - 1
                            color: root.auditorEnabled_ ? Theme.primary : Theme.surfaceText
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Item { width: 8; height: 1 }
                        // Toggle visual sencillo
                        Rectangle {
                            width: 34; height: 20; radius: 10
                            color: root.auditorEnabled_ ? Theme.primary : Theme.surfaceVariant
                            anchors.verticalCenter: parent.verticalCenter
                            Rectangle {
                                width: 16; height: 16; radius: 8
                                color: "white"
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.left: parent.left; anchors.leftMargin: root.auditorEnabled_ ? 16 : 2
                                Behavior on anchors.leftMargin { NumberAnimation { duration: 120 } }
                            }
                        }
                    }
                    MouseArea {
                        id: auditorRowMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.setAuditorEnabled(!root.auditorEnabled_)
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
}
