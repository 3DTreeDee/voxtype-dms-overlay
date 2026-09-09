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
    property var auditor

    // Modo auditor: en vez del dim full-screen (que taparía la reunión), se
    // muestra SOLO el panel flotante del feed del auditor en la esquina.
    // El feed del auditor se muestra cuando el interruptor está ON y hay una
    // reunión en progreso. No requiere daemon.active (que es dictado ptt).
    readonly property bool auditorMode: daemon && daemon.auditorEnabled && daemon.meetingRunning

    color: "transparent"
    visible: auditorMode || (daemon ? daemon.active : false)

    WlrLayershell.namespace: "voxtype-overlay"
    WlrLayershell.layer: WlrLayershell.Overlay
    WlrLayershell.exclusiveZone: -1
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    // Input region: en modo auditor el panel flotante captura la rueda/clics
    // (para poder hacer scroll del feed); el resto sigue click-through. En
    // dictado, solo el ✕ (cuando está habilitado).
    mask: Region {
        item: win.auditorMode ? auditorPanel
             : (win.daemon && win.daemon.closeButtonEnabled) ? closeBtn : null
    }

    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }

    readonly property bool isCutScreen: daemon && daemon.cutValid && win.screen && daemon.cutMonitorName === win.screen.name
    readonly property bool isMicScreen: daemon && win.screen && daemon.micMonitorName === win.screen.name
    // Mic-only mode (widget quick-capture): show just the pulsing mic, no dim,
    // no cutout frame, no border.
    readonly property bool micOnly: daemon ? daemon.micOnly : false

    // ── Full-screen dim (non-cutout screens) ─────────────────────────────────
    Rectangle {
        anchors.fill: parent
        color: "black"
        opacity: win.daemon ? win.daemon.dimOpacity : 0
        visible: !win.isCutScreen && !win.micOnly && !win.auditorMode
    }

    // ── Four-rectangle dim frame around the active-window cutout ─────────────
    Item {
        id: frame
        anchors.fill: parent
        visible: win.isCutScreen && !win.micOnly && !win.auditorMode

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

    // ── Close button (✕) — manual escape hatch, one per monitor ──────────────
    // The ONLY interactive part of the surface (see `mask` above): the rest is
    // click-through. Clicking it cancels the current dictation (discard, no
    // text), which flips VoxType to idle and the overlay hides.
    Rectangle {
        id: closeBtn
        visible: win.daemon ? win.daemon.closeButtonEnabled : false
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.topMargin: 28
        anchors.rightMargin: 28
        width: 48
        height: 48
        radius: 24
        color: closeMouse.containsMouse ? Qt.rgba(0.8, 0.2, 0.2, 0.85) : Qt.rgba(0, 0, 0, 0.55)
        border.width: 2
        border.color: win.daemon ? win.daemon.borderColor : "white"

        DankIcon {
            anchors.centerIn: parent
            name: "close"
            size: 26
            color: "white"
        }

        MouseArea {
            id: closeMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: if (win.daemon) win.daemon.cancelRecording()
        }
    }

    // ── Auditor feed panel (esquina superior derecha) ────────────────────────
    // Se muestra SOLO en modo auditor (reunión activa + auditor on). Sustituye
    // el dim full-screen: lista los enunciados de ambos lados y las respuestas
    // del KB/IA del auditor en tiempo real.
    Item {
        id: auditorPanel
        visible: win.auditorMode
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.topMargin: 12
        anchors.rightMargin: 12
        width: 460
        height: Math.min(620, Math.max(300, feed.implicitHeight + 24))

        Rectangle {
            anchors.fill: parent
            radius: 14
            color: Qt.rgba(0.11, 0.11, 0.13, 0.92)
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.12)

            Column {
                id: feed
                anchors.fill: parent
                anchors.margins: 12
                spacing: 8

                // Cabecera
                Row {
                    width: parent.width
                    spacing: 8
                    DankIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "groups"
                        size: 16
                        color: Theme.primary
                    }
                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Auditor — Reunión en vivo"
                        font.pixelSize: 14
                        font.bold: true
                        color: Theme.surfaceText
                        elide: Text.ElideRight
                        width: parent.width - 30
                    }
                }
                StyledText {
                    text: "Enunciados de ambos lados · respuestas KB/IA"
                    font.pixelSize: 11
                    color: Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                    width: parent.width
                }

                // Lista de eventos
                Rectangle {
                    id: qlistBox
                    width: parent.width
                    height: Math.max(80, Math.min(480, qlist.implicitHeight))
                    color: "transparent"
                    clip: true

                    ListView {
                        id: qlist
                        anchors.fill: parent
                        model: win.auditor ? win.auditor.events : []
                        spacing: 10
                        cacheBuffer: 400
                        clip: true

                        // Auto-scroll: mantener lo MÁS RECIENTE visible abajo.
                        // (Sin esto los eventos nuevos quedan fuera de vista y
                        // parecen "no llegar" — el bug que reportó el usuario.)
                        onCountChanged: Qt.callLater(() => {
                            if (qlist.contentHeight > qlist.height)
                                qlist.positionViewAtEnd();
                        })
                        Component.onCompleted: Qt.callLater(() => qlist.positionViewAtEnd())

                        delegate: Item {
                            property var e: modelData
                            width: ListView.view.width
                            height: rowC.implicitHeight + 14

                            Column {
                                id: rowC
                                anchors.left: parent.left
                                anchors.leftMargin: 2
                                anchors.right: parent.right
                                anchors.rightMargin: 2
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 6

                                Row {
                                    width: parent.width
                                    spacing: 6
                                    Rectangle {
                                        width: 6
                                        height: txt.implicitHeight
                                        radius: 3
                                        color: (e.speaker === "you") ? Theme.primary : Qt.rgba(0.9, 0.6, 0.2, 0.9)
                                    }
                                    Column {
                                        width: parent.width - 12
                                        spacing: 2
                                        StyledText {
                                            width: parent.width
                                            text: (e.type === "kb_hit" || e.type === "ai_answer") ? "Auditor" : (e.speaker === "you") ? "Tú" : "Remoto"
                                            font.pixelSize: 10
                                            font.bold: true
                                            color: (e.type === "kb_hit") ? Qt.rgba(0.35, 0.8, 0.5, 1) : (e.type === "ai_answer") ? Qt.rgba(0.45, 0.7, 1, 1) : Theme.surfaceVariantText
                                        }
                                        StyledText {
                                            id: txt
                                            width: parent.width
                                            text: e.text || ""
                                            font.pixelSize: 13
                                            color: Theme.surfaceText
                                            wrapMode: Text.WordWrap
                                        }
                                    }
                                }

                                StyledText {
                                    width: parent.width
                                    visible: e.type === "kb_hit" || e.type === "ai_answer"
                                    text: (e.type === "kb_hit" ? "📚 " : "💡 ") + (e.answer || "")
                                    font.pixelSize: 12
                                    color: (e.type === "kb_hit") ? Qt.rgba(0.35, 0.8, 0.5, 1) : Qt.rgba(0.45, 0.7, 1, 1)
                                    wrapMode: Text.WordWrap
                                }
                                StyledText {
                                    width: parent.width
                                    visible: e.type === "ai_error"
                                    text: "⚠️ " + (e.error || "")
                                    font.pixelSize: 11
                                    color: Theme.errorText
                                    wrapMode: Text.WordWrap
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
