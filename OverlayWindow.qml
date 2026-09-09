import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
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

    // Estado del panel del auditor (colapsado/oculto). No persisten entre
    // reuniones: cada reunión nueva arranca con el panel expandido.
    property bool auditorCollapsed: false
    property bool auditorHidden: false

    // Cada reunión nueva: re-aplicar geometría guardada (el Item solo se crea
    // una vez al cargar el plugin) y resetear colapso/oculto.
    onAuditorModeChanged: {
        if (!auditorMode) return;
        auditorCollapsed = false;
        auditorHidden = false;
        Qt.callLater(() => {
            const d = win.daemon || {};
            const defW = Math.max(420, Math.min(win.width * 0.48, 980));
            const defH = Math.max(360, Math.min(win.height * 0.60, 900));
            const dw = Math.max(340, Math.min(d.auditorPanelW > 0 ? d.auditorPanelW : defW, win.width - 32));
            const dh = Math.max(200, Math.min(d.auditorPanelH > 0 ? d.auditorPanelH : defH, win.height - 32));
            auditorPanel.width = dw;
            auditorPanel.height = dh;
            auditorPanel.x = (d.auditorPanelX >= 0) ? Math.min(d.auditorPanelX, win.width - dw - 8)
                                                    : win.width - dw - 12;
            auditorPanel.y = (d.auditorPanelY >= 0) ? Math.min(d.auditorPanelY, win.height - 32)
                                                    : Math.max(12, (win.height - dh) * 0.08);
        });
    }

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
        item: win.auditorMode ? (win.auditorHidden ? auditorMini : auditorPanel)
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

    // ── Auditor feed panel ───────────────────────────────────────────────────
    // Modo auditor: en lugar del dim full-screen, un panel GRANDE y
    // redimensionable (arrastra la esquina ▼), movible (arrastra la cabecera),
    // colapsable a una mini-barra (botón —) y ocultable (botón ✕, reaparece el
    // pill "Auditor" para restaurarlo). Tamaño/posición persisten en pluginData.
    Item {
        id: auditorPanel
        visible: win.auditorMode && !win.auditorHidden
        // Sin anchors: posición libre (x/y) para poder moverlo; defaults en
        // onCompleted según el tamaño de pantalla.
        property real startX: 0
        property real startY: 0

        Component.onCompleted: {
            const d = win.daemon || {};
            const defW = Math.max(420, Math.min(win.width * 0.48, 980));
            const defH = Math.max(360, Math.min(win.height * 0.60, 900));
            const dw = Math.max(340, Math.min(d.auditorPanelW > 0 ? d.auditorPanelW : defW, win.width - 32));
            const dh = Math.max(200, Math.min(d.auditorPanelH > 0 ? d.auditorPanelH : defH, win.height - 32));
            width = dw;
            height = win.auditorCollapsed ? 44 : dh;
            x = (d.auditorPanelX >= 0) ? Math.min(d.auditorPanelX, win.width - width - 8)
                                       : win.width - width - 12;
            y = (d.auditorPanelY >= 0) ? Math.min(d.auditorPanelY, win.height - 32)
                                       : Math.max(12, (win.height - dh) * 0.08);
        }

        // Fondo
        Rectangle {
            anchors.fill: parent
            radius: 12
            color: Qt.rgba(0.09, 0.09, 0.12, 0.94)
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.14)
        }

        // Colapso: solo cabecera visible en una mini-barra; clic re-expande.
        MouseArea {
            anchors.fill: parent
            visible: win.auditorCollapsed
            cursorShape: Qt.PointingHandCursor
            onClicked: win.auditorCollapsed = false
        }
        Row {
            anchors.fill: parent
            anchors.margins: 12
            visible: win.auditorCollapsed
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
                font.pixelSize: 13
                font.bold: true
                color: Theme.surfaceText
                width: parent.width - 70
                elide: Text.ElideRight
            }
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: "…"
                font.pixelSize: 16
                color: Theme.surfaceVariantText
            }
        }

        // Contenido expandido
        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 12
            spacing: 6
            visible: !win.auditorCollapsed

            // ── Cabecera (arrastrable para mover el panel) ──
            RowLayout {
                Layout.fillWidth: true
                spacing: 6

                MouseArea {
                    id: headerDrag
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    cursorShape: Qt.ClosedHandCursor
                    onPressed: {
                        headerDrag.cursorShape = Qt.ClosedHandCursor;
                        auditorPanel.startX = mouse.x - auditorPanel.x;
                        auditorPanel.startY = mouse.y - auditorPanel.y;
                    }
                    onPositionChanged: {
                        if (!pressed) return;
                        var nx = Math.max(4, Math.min(win.width - auditorPanel.width - 4, mouse.x - auditorPanel.startX + auditorPanel.x));
                        var ny = Math.max(4, Math.min(win.height - 40, mouse.y - auditorPanel.startY + auditorPanel.y));
                        auditorPanel.x = nx;
                        auditorPanel.y = ny;
                    }
                    onReleased: {
                        const d = win.daemon;
                        if (d && d.saveAuditorPanel)
                            d.saveAuditorPanel(auditorPanel.width, auditorPanel.height, auditorPanel.x, auditorPanel.y);
                    }

                    RowLayout {
                        anchors.fill: parent
                        spacing: 8
                        DankIcon {
                            Layout.preferredWidth: 18
                            name: "groups"
                            size: 18
                            color: Theme.primary
                        }
                        StyledText {
                            Layout.fillWidth: true
                            text: "Auditor — Reunión en vivo"
                            font.pixelSize: 14
                            font.bold: true
                            color: Theme.surfaceText
                            elide: Text.ElideRight
                        }
                        // Indicador "en vivo"
                        Rectangle {
                            Layout.preferredWidth: 8
                            Layout.preferredHeight: 8
                            radius: 4
                            color: Qt.rgba(0.9, 0.2, 0.2, 0.95)
                            SequentialAnimation on color {
                                running: win.auditorMode
                                loops: Animation.Infinite
                                PropertyAnimation { to: Qt.rgba(0.9, 0.4, 0.2, 0.95); duration: 700 }
                                PropertyAnimation { to: Qt.rgba(0.9, 0.2, 0.2, 0.95); duration: 700 }
                            }
                        }
                    }
                }

                // Botón colapsar (—)
                Rectangle {
                    Layout.preferredWidth: 26
                    Layout.preferredHeight: 26
                    radius: 6
                    color: collapseMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.15) : "transparent"
                    StyledText {
                        anchors.centerIn: parent
                        text: "—"
                        font.pixelSize: 15
                        color: Theme.surfaceText
                    }
                    MouseArea {
                        id: collapseMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: win.auditorCollapsed = true
                    }
                }

                // Botón ocultar (✕)
                Rectangle {
                    Layout.preferredWidth: 26
                    Layout.preferredHeight: 26
                    radius: 6
                    color: hideMouse.containsMouse ? Qt.rgba(0.8, 0.2, 0.2, 0.35) : "transparent"
                    StyledText {
                        anchors.centerIn: parent
                        text: "✕"
                        font.pixelSize: 13
                        color: Theme.errorText
                    }
                    MouseArea {
                        id: hideMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: win.auditorHidden = true
                    }
                }
            }

            StyledText {
                Layout.fillWidth: true
                text: "Enunciados de ambos lados · respuestas KB/IA"
                font.pixelSize: 11
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
            }

            // ── Lista (ocupa TODO el espacio restante) ──
            Rectangle {
                id: qlistBox
                Layout.fillWidth: true
                Layout.fillHeight: true
                color: "transparent"
                clip: true

                ListView {
                    id: qlist
                    anchors.fill: parent
                    model: win.auditor ? win.auditor.events : []
                    spacing: 10
                    cacheBuffer: 600
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    // Auto-scroll: mantener lo MÁS RECIENTE visible abajo.
                    onCountChanged: Qt.callLater(() => {
                        if (qlist.contentHeight > qlist.height)
                            qlist.positionViewAtEnd();
                    })
                    Component.onCompleted: Qt.callLater(() => qlist.positionViewAtEnd())

                    delegate: Item {
                        property var e: modelData
                        width: ListView.view.width
                        height: rowC.implicitHeight + 12

                        Column {
                            id: rowC
                            anchors.left: parent.left
                            anchors.leftMargin: 2
                            anchors.right: parent.right
                            anchors.rightMargin: 2
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 5

                            Row {
                                width: parent.width
                                spacing: 6
                                Rectangle {
                                    width: 4
                                    height: txt.implicitHeight
                                    radius: 2
                                    color: (e.speaker === "you") ? Theme.primary : Qt.rgba(0.9, 0.6, 0.2, 0.9)
                                }
                                Column {
                                    width: parent.width - 10
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

                // Scrollbar sutil (visible cuando hay scroll)
                ScrollBar.vertical: ScrollBar {
                    policy: qlist.contentHeight > qlist.height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
                    width: 6
                    background: Rectangle { color: "transparent" }
                    contentItem: Rectangle {
                        radius: 3
                        color: Qt.rgba(1, 1, 1, 0.25)
                    }
                }
            }
        }

        // ── Handle de redimensionado (esquina inferior IZQUIERDA) ──
        // El panel vive pegado al borde derecho de la pantalla: la esquina que
        // puede tirar hacia afuera es la inferior-izquierda (arrastra hacia la
        // izquierda para agrandar; el borde derecho queda fijo). Vertical:
        // arrastra hacia abajo para más alto.
        Rectangle {
            id: resizeHandle
            visible: !win.auditorCollapsed
            width: 18
            height: 18
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            anchors.margins: 2
            color: resizeMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.12) : "transparent"
            radius: 4

            Canvas {
                anchors.centerIn: parent
                width: 8
                height: 8
                onPaint: {
                    const ctx = getContext("2d");
                    ctx.strokeStyle = "rgba(255,255,255,0.45)";
                    ctx.lineWidth = 1.4;
                    for (let i = 0; i < 2; i++) {
                        ctx.beginPath();
                        ctx.moveTo(7, 1 + i * 3.2);
                        ctx.lineTo(1 + i * 3.2, 7);
                        ctx.stroke();
                    }
                }
            }

            MouseArea {
                id: resizeMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.SizeBDiagCursor

                property real baseRight: 0   // borde derecho fijo (global)
                property real baseY: 0
                property real pressX: 0
                property real pressY: 0

                onPressed: {
                    baseRight = auditorPanel.x + auditorPanel.width;
                    baseY = auditorPanel.y;
                    pressX = mouse.x;
                    pressY = mouse.y;
                }
                onPositionChanged: {
                    if (!pressed) return;
                    const minW = 340, minH = 220;
                    // Borde izquierdo sigue al cursor; derecho fijo.
                    let nx = Math.max(8, Math.min(baseRight - minW, auditorPanel.x + (mouse.x - pressX)));
                    auditorPanel.x = nx;
                    auditorPanel.width = baseRight - nx;
                    // Borde superior fijo; inferior sigue al cursor.
                    auditorPanel.height = Math.max(minH, Math.min(win.height - 24, auditorPanel.height + (mouse.y - pressY)));
                }
                onReleased: {
                    const d = win.daemon;
                    if (d && d.saveAuditorPanel)
                        d.saveAuditorPanel(auditorPanel.width, auditorPanel.height, auditorPanel.x, auditorPanel.y);
                }
            }
        }
    }

    // Pill "Auditor" cuando el panel está oculto (✕) — clic para restaurar.
    Rectangle {
        id: auditorMini
        visible: win.auditorMode && win.auditorHidden
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.topMargin: 12
        anchors.rightMargin: 12
        width: miniRow.implicitWidth + 20
        height: 34
        radius: 17
        color: Qt.rgba(0.09, 0.09, 0.12, 0.94)
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 0.14)
        z: 10

        Row {
            id: miniRow
            anchors.centerIn: parent
            spacing: 6
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 8
                height: 8
                radius: 4
                color: Qt.rgba(0.9, 0.2, 0.2, 0.95)
                SequentialAnimation on color {
                    running: true
                    loops: Animation.Infinite
                    PropertyAnimation { to: Qt.rgba(0.9, 0.4, 0.2, 0.95); duration: 700 }
                    PropertyAnimation { to: Qt.rgba(0.9, 0.2, 0.2, 0.95); duration: 700 }
                }
            }
            StyledText {
                text: "Auditor"
                font.pixelSize: 12
                font.bold: true
                color: Theme.surfaceText
            }
        }
        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                win.auditorHidden = false;
                win.auditorCollapsed = false;
            }
        }
    }
}
