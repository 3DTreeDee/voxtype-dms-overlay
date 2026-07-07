import QtQuick
import Quickshell
import qs.Common
import qs.Modules.Plugins

// Root component of the "voxtypeOverlay" daemon plugin.
//
// A daemon-type PluginComponent is instantiated exactly ONCE (not per-screen),
// so it acts as its own coordinator: it polls VoxType's state, captures the
// active-window geometry when a dictation session starts, and drives one
// OverlayWindow per Quickshell.screens via a Variants. The per-screen surfaces
// are created/destroyed declaratively by binding their `visible` to `active` —
// when idle/disabled, no layer surface exists (verify with `hyprctl layers`).
PluginComponent {
    id: root

    layerNamespacePlugin: "voxtype-overlay"

    // ── Live settings (read from pluginData, refreshed on pluginDataChanged) ──
    // Opacities are stored as integer percents so the DMS SliderSetting can use
    // plain integer sliders; divided back to 0.0–1.0 here.
    readonly property real dimOpacity: (pluginData && pluginData.dimOpacityPct !== undefined ? pluginData.dimOpacityPct : 55) / 100
    readonly property bool borderEnabled: (pluginData && pluginData.borderEnabled !== undefined) ? pluginData.borderEnabled : true
    readonly property int borderWidth: (pluginData && pluginData.borderWidth !== undefined) ? pluginData.borderWidth : 4
    readonly property color borderColor: (pluginData && pluginData.borderColor !== undefined && pluginData.borderColor !== "") ? pluginData.borderColor : Theme.primary
    readonly property string recordingLabel: (pluginData && pluginData.recordingLabel !== undefined) ? pluginData.recordingLabel : "RECORDING"
    readonly property int labelFontSize: (pluginData && pluginData.labelFontSize !== undefined) ? pluginData.labelFontSize : 18
    readonly property int micIconSize: (pluginData && pluginData.micIconSize !== undefined) ? pluginData.micIconSize : 128
    readonly property string micIconPath: (pluginData && pluginData.micIconPath !== undefined) ? pluginData.micIconPath : ""
    readonly property bool pulseEnabled: (pluginData && pluginData.pulseEnabled !== undefined) ? pluginData.pulseEnabled : true
    readonly property real pulseMin: (pluginData && pluginData.pulseMinPct !== undefined ? pluginData.pulseMinPct : 35) / 100
    readonly property real pulseMax: (pluginData && pluginData.pulseMaxPct !== undefined ? pluginData.pulseMaxPct : 100) / 100
    readonly property int pulsePeriodMs: (pluginData && pluginData.pulsePeriodMs !== undefined) ? pluginData.pulsePeriodMs : 2000
    readonly property int backstopSeconds: (pluginData && pluginData.backstopSeconds !== undefined) ? pluginData.backstopSeconds : 5

    // ── State ────────────────────────────────────────────────────────────────
    property string statusClass: "idle"
    property bool backstopTripped: false
    property double lastGoodReadMs: 0

    // Visible while VoxType reports it is capturing or transcribing, unless the
    // safety backstop has tripped because state went unreadable.
    readonly property bool recordingActive: statusClass === "recording" || statusClass === "transcribing"
    readonly property bool active: recordingActive && !backstopTripped

    // ── Cutout geometry (captured once, at recording start) ──────────────────
    property bool cutValid: false
    property string cutMonitorName: ""   // monitor whose active window is cut out
    property string micMonitorName: ""   // monitor the mic widget renders on
    property int cutX: 0                  // all in target-monitor-local coordinates
    property int cutY: 0
    property int cutW: 0
    property int cutH: 0
    readonly property int cutPadding: 8  // px breathing room around the window (matches the GTK overlay)

    readonly property int pollIntervalMs: 400

    // ── State polling ─────────────────────────────────────────────────────────
    function fetchStatus() {
        Proc.runCommand("voxtypeOverlay.status", ["voxtype", "status", "--format", "json"], (stdout, exitCode) => {
            if (exitCode === 0 && stdout && stdout.trim() !== "") {
                try {
                    const s = JSON.parse(stdout.trim());
                    root.statusClass = s.class || s.alt || "idle";
                    root.lastGoodReadMs = Date.now();
                    root.backstopTripped = false;
                    return;
                } catch (e) {
                    // malformed payload → treat like an unreadable state
                }
            }
            root._handleUnreadable();
        }, 250);
    }

    // Backstop: if we're currently showing but can no longer read VoxType's
    // state (daemon killed, socket gone, …), hide after `backstopSeconds`.
    function _handleUnreadable() {
        if (root.recordingActive && root.lastGoodReadMs > 0 && (Date.now() - root.lastGoodReadMs) > root.backstopSeconds * 1000) {
            root.backstopTripped = true;
        }
    }

    Timer {
        interval: root.pollIntervalMs
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.fetchStatus()
    }

    // ── Cutout capture ────────────────────────────────────────────────────────
    // Captured on the rising edge of `active` (i.e. dictation start). Because
    // recording → transcribing keeps `active` true, the cutout is captured once
    // and preserved through transcription; it is cleared when the overlay hides.
    onActiveChanged: {
        if (active)
            captureCutout();
        else
            cutValid = false;
    }

    function captureCutout() {
        Proc.runCommand("voxtypeOverlay.activewindow", ["hyprctl", "activewindow", "-j"], (awOut, awExit) => {
            let aw = null;
            try {
                aw = (awExit === 0 && awOut && awOut.trim() !== "") ? JSON.parse(awOut.trim()) : null;
            } catch (e) {
                aw = null;
            }
            Proc.runCommand("voxtypeOverlay.monitors", ["hyprctl", "monitors", "-j"], (monOut, monExit) => {
                let mons = [];
                try {
                    mons = (monExit === 0 && monOut && monOut.trim() !== "") ? JSON.parse(monOut.trim()) : [];
                } catch (e) {
                    mons = [];
                }
                root._applyCapture(aw, mons);
            }, 250);
        }, 250);
    }

    function _applyCapture(aw, mons) {
        // Focused monitor → where the mic widget renders (independent of whether
        // a window rect was resolvable).
        let focused = null;
        for (let i = 0; i < mons.length; i++) {
            if (mons[i].focused) {
                focused = mons[i];
                break;
            }
        }

        let valid = false;
        if (aw && aw.at && aw.size && aw.size[0] > 0 && aw.size[1] > 0) {
            let awMon = null;
            for (let i = 0; i < mons.length; i++) {
                if (mons[i].id === aw.monitor) {
                    awMon = mons[i];
                    break;
                }
            }
            if (awMon) {
                root.cutMonitorName = awMon.name;
                root.cutX = aw.at[0] - awMon.x - root.cutPadding;
                root.cutY = aw.at[1] - awMon.y - root.cutPadding;
                root.cutW = aw.size[0] + root.cutPadding * 2;
                root.cutH = aw.size[1] + root.cutPadding * 2;
                valid = true;
            }
        }
        root.cutValid = valid;
        if (!valid)
            root.cutMonitorName = "";

        // Prefer the focused monitor for the mic; fall back to the cutout
        // monitor, then the first screen.
        root.micMonitorName = focused ? focused.name : (valid ? root.cutMonitorName : (Quickshell.screens.length > 0 ? Quickshell.screens[0].name : ""));
    }

    // ── Per-screen overlay surfaces ───────────────────────────────────────────
    // One OverlayWindow per monitor. Variants adds/removes delegates on monitor
    // hotplug automatically; each window's surface only exists while visible.
    Variants {
        model: Quickshell.screens

        OverlayWindow {
            required property var modelData
            screen: modelData
            daemon: root
        }
    }
}
