import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Common
import qs.Widgets

// One full-screen layer-shell surface per monitor. It draws:
//   • a full-screen dim (screens without the active window), OR
//   • a four-rectangle dim "frame" leaving the active-window rect clear, plus a
//     themed highlight border (the monitor holding the active window), and
//   • a pulsing mic + optional label (the focused monitor only).
//
// The surface is purely visual: an empty input `mask` makes it fully
// click-through, so recording never traps the pointer. `visible` is bound to
// the daemon's `active`, so Quickshell destroys the wayland surface the moment
// dictation ends or the plugin is disabled — no leaked layers.
PanelWindow {
    id: win

    property var daemon

    color: "transparent"
    visible: daemon ? daemon.active : false

    WlrLayershell.namespace: "voxtype-overlay"
    WlrLayershell.layer: WlrLayershell.Overlay
    WlrLayershell.exclusiveZone: -1
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    // Empty input region → fully click-through (pure-visual overlay).
    mask: Region {}

    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }

    readonly property bool isCutScreen: daemon && daemon.cutValid && win.screen && daemon.cutMonitorName === win.screen.name
    readonly property bool isMicScreen: daemon && win.screen && daemon.micMonitorName === win.screen.name

    // ── Full-screen dim (non-cutout screens) ─────────────────────────────────
    Rectangle {
        anchors.fill: parent
        color: "black"
        opacity: win.daemon ? win.daemon.dimOpacity : 0
        visible: !win.isCutScreen
    }

    // ── Four-rectangle dim frame around the active-window cutout ─────────────
    Item {
        id: frame
        anchors.fill: parent
        visible: win.isCutScreen

        readonly property int cx: win.daemon ? win.daemon.cutX : 0
        readonly property int cy: win.daemon ? win.daemon.cutY : 0
        readonly property int cw: win.daemon ? win.daemon.cutW : 0
        readonly property int ch: win.daemon ? win.daemon.cutH : 0
        readonly property real op: win.daemon ? win.daemon.dimOpacity : 0

        Rectangle {   // top strip
            color: "black"
            opacity: frame.op
            x: 0
            y: 0
            width: win.width
            height: Math.max(0, frame.cy)
        }
        Rectangle {   // bottom strip
            color: "black"
            opacity: frame.op
            x: 0
            y: frame.cy + frame.ch
            width: win.width
            height: Math.max(0, win.height - (frame.cy + frame.ch))
        }
        Rectangle {   // left strip
            color: "black"
            opacity: frame.op
            x: 0
            y: frame.cy
            width: Math.max(0, frame.cx)
            height: frame.ch
        }
        Rectangle {   // right strip
            color: "black"
            opacity: frame.op
            x: frame.cx + frame.cw
            y: frame.cy
            width: Math.max(0, win.width - (frame.cx + frame.cw))
            height: frame.ch
        }

        Rectangle {   // highlight border hugging the cutout
            visible: win.daemon && win.daemon.borderEnabled && win.daemon.borderWidth > 0
            x: frame.cx
            y: frame.cy
            width: frame.cw
            height: frame.ch
            color: "transparent"
            border.width: win.daemon ? win.daemon.borderWidth : 0
            border.color: win.daemon ? win.daemon.borderColor : "transparent"
        }
    }

    // ── Mic widget (focused monitor only) ────────────────────────────────────
    Item {
        anchors.centerIn: parent
        visible: win.isMicScreen
        width: micCol.implicitWidth
        height: micCol.implicitHeight

        Column {
            id: micCol
            anchors.centerIn: parent
            spacing: 24

            Item {
                id: micGlyph
                anchors.horizontalCenter: parent.horizontalCenter
                width: win.daemon ? win.daemon.micIconSize : 128
                height: width

                DankIcon {
                    anchors.centerIn: parent
                    visible: !win.daemon || win.daemon.micIconPath === ""
                    name: "mic"
                    size: win.daemon ? win.daemon.micIconSize : 128
                    color: win.daemon ? win.daemon.borderColor : Theme.primary
                }

                Image {
                    anchors.fill: parent
                    visible: win.daemon && win.daemon.micIconPath !== ""
                    source: (win.daemon && win.daemon.micIconPath !== "") ? ("file://" + win.daemon.micIconPath) : ""
                    fillMode: Image.PreserveAspectFit
                    smooth: true
                    asynchronous: true
                }
            }

            StyledText {
                anchors.horizontalCenter: parent.horizontalCenter
                visible: win.daemon && win.daemon.recordingLabel !== ""
                text: win.daemon ? win.daemon.recordingLabel : ""
                color: "white"
                font.pixelSize: win.daemon ? win.daemon.labelFontSize : 18
                font.bold: true
            }
        }

        // Pulse: fade the mic glyph between the configured min/max opacity.
        SequentialAnimation {
            running: win.visible && win.isMicScreen && win.daemon && win.daemon.pulseEnabled
            loops: Animation.Infinite

            NumberAnimation {
                target: micGlyph
                property: "opacity"
                from: win.daemon ? win.daemon.pulseMin : 0.35
                to: win.daemon ? win.daemon.pulseMax : 1.0
                duration: win.daemon ? win.daemon.pulsePeriodMs / 2 : 1000
                easing.type: Easing.InOutSine
            }
            NumberAnimation {
                target: micGlyph
                property: "opacity"
                from: win.daemon ? win.daemon.pulseMax : 1.0
                to: win.daemon ? win.daemon.pulseMin : 0.35
                duration: win.daemon ? win.daemon.pulsePeriodMs / 2 : 1000
                easing.type: Easing.InOutSine
            }
        }

        // When pulsing is off, hold the glyph fully opaque.
        Binding {
            target: micGlyph
            property: "opacity"
            value: 1.0
            when: !(win.daemon && win.daemon.pulseEnabled)
        }
    }
}
