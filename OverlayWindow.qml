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

    // Auto-scroll del feed: ON = pegado abajo (siempre lo más reciente);
    // OFF = scroll libre, sin saltos. Persistido en pluginData (daemon).
    readonly property bool autoScrollFeed: (daemon && daemon.auditorAutoScroll !== undefined) ? daemon.auditorAutoScroll : true

    // Modo debug: refleja el toggle del daemon y controla la visibilidad de
    // las líneas de métricas. El backend solo emite eventos debug si el modo
    // estaba ON al iniciar la reunión.
    readonly property bool debugMode: (daemon && daemon.auditorDebug !== undefined) ? daemon.auditorDebug : false

    // Estado compartido de Sugerir: lo gestiona el daemon para que todas las
    // pantallas muestren la misma animación hasta que llegue la respuesta o
    // el error correspondiente a la solicitud activa.
    readonly property bool suggestBusy: daemon ? daemon.suggestBusy : false
    property int suggestDots: 0

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

    // Al reactivar el auto-scroll, bajar de inmediato al final.
    onAutoScrollFeedChanged: {
        if (autoScrollFeed)
            Qt.callLater(() => { if (qlist) qlist.positionViewAtEnd(); });
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
    // La lista del feed está anclada entre la cabecera y el borde inferior del
    // panel, así que SIEMPRE ocupa el 100% del alto disponible.
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

        // ── Contenido expandido ─────────────────────────────────────────────
        // Layout por ANCLAS (sin ColumnLayout): cabecera fija arriba; la lista
        // se ancla entre la cabecera y el borde inferior del panel, así que
        // ocupa SIEMPRE el 100% del alto disponible, sin importar el tamaño.
        Item {
            anchors.fill: parent
            anchors.margins: 12
            visible: !win.auditorCollapsed

            // ── Cabecera (arrastrable para mover el panel) ──
            Item {
                id: headerRow
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                height: 30

                // Zona de arrastre: ocupa desde la izquierda hasta el ✕.
                MouseArea {
                    id: headerDrag
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    anchors.left: parent.left
                    anchors.right: hideBtn.left
                    anchors.rightMargin: 6
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

                    Row {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        spacing: 8
                        DankIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: "groups"
                            size: 18
                            color: Theme.primary
                        }
                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Auditor — Reunión en vivo"
                            font.pixelSize: 14
                            font.bold: true
                            color: Theme.surfaceText
                        }
                        // Indicador "en vivo"
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 9
                            height: 9
                            radius: 4.5
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

                // Botón ocultar (✕) — el más a la derecha
                Rectangle {
                    id: hideBtn
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: 30
                    height: 30
                    radius: 7
                    color: hideMouse.containsMouse ? Qt.rgba(0.8, 0.2, 0.2, 0.35) : "transparent"
                    StyledText {
                        anchors.centerIn: parent
                        text: "✕"
                        font.pixelSize: 14
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

                // Botón colapsar (—) — a la izquierda del ✕
                Rectangle {
                    id: collapseBtn
                    anchors.right: hideBtn.left
                    anchors.rightMargin: 6
                    anchors.verticalCenter: parent.verticalCenter
                    width: 30
                    height: 30
                    radius: 7
                    color: collapseMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.15) : "transparent"
                    StyledText {
                        anchors.centerIn: parent
                        text: "—"
                        font.pixelSize: 17
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

                // Botón auto-scroll (switch): ON = feed pegado abajo; OFF = scroll
                // libre sin saltos. A la izquierda del colapsar.
                Rectangle {
                    id: autoScrollBtn
                    anchors.right: collapseBtn.left
                    anchors.rightMargin: 6
                    anchors.verticalCenter: parent.verticalCenter
                    width: 30
                    height: 30
                    radius: 7
                    color: win.autoScrollFeed
                           ? Qt.rgba(0.35, 0.8, 0.5, 0.30)
                           : (autoScrollMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.15) : "transparent")
                    DankIcon {
                        anchors.centerIn: parent
                        name: win.autoScrollFeed ? "vertical_align_bottom" : "swap_vert"
                        size: 16
                        color: win.autoScrollFeed ? Qt.rgba(0.5, 0.95, 0.65, 1) : Theme.surfaceVariantText
                    }
                    MouseArea {
                        id: autoScrollMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (win.daemon && win.daemon.setAuditorAutoScroll)
                                win.daemon.setAuditorAutoScroll(!win.autoScrollFeed);
                        }
                    }
                }
            }

            // ── Lista del feed: espacio entre cabecera y botón ────────────────
            Rectangle {
                id: qlistBox
                anchors.top: headerRow.bottom
                anchors.topMargin: 8
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: suggestBtn.top
                anchors.bottomMargin: 6
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

                    // Seguir el final con una animación corta cuando el modo
                    // auto-scroll está activo; no interfiere con el scroll libre.
                    Behavior on contentY {
                        enabled: win.autoScrollFeed
                        NumberAnimation {
                            duration: 120
                            easing.type: Easing.OutQuad
                        }
                    }

                    // Auto-scroll condicionado por el switch del panel:
                    //  - ON  → pegado abajo (siempre lo más reciente).
                    //  - OFF → scroll libre, no se mueve al llegar texto.
                    // (a) onCountChanged: entró una frase/evento nuevo.
                    // (b) onContentHeightChanged: el layout creció/ajustó (la
                    //     altura del delegate no está medida al llegar el evento;
                    //     sin esto el scroll quedaba a medias y luego "saltaba").
                    // Llamada diferida para posicionar tras medir el delegate.
                    function scrollToBottom() {
                        if (win.autoScrollFeed && qlist.count > 0)
                            qlist.positionViewAtEnd();
                    }
                    onCountChanged: Qt.callLater(scrollToBottom)
                    onContentHeightChanged: Qt.callLater(scrollToBottom)
                    Component.onCompleted: Qt.callLater(scrollToBottom)

                    delegate: Item {
                        property var e: modelData
                        width: ListView.view.width
                        height: e.type === "info"
                            ? (infoLine.implicitHeight + 8)
                            : e.type === "debug"
                            ? (debugLine.implicitHeight + 8)
                            : Math.max(rowC.implicitHeight + 12, 40)

                        // Info relevante (estado ask/IA/errores): línea sutil y
                        // centrada, sin barra de color ni etiqueta de speaker.
                        StyledText {
                            id: infoLine
                            visible: e.type === "info"
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left
                            anchors.leftMargin: 6
                            anchors.right: parent.right
                            anchors.rightMargin: 6
                            horizontalAlignment: Text.AlignHCenter
                            text: e.msg || ""
                            font.pixelSize: 12
                            font.italic: true
                            color: Qt.rgba(1, 1, 1, 0.5)
                            wrapMode: Text.WordWrap
                        }

                        // Métricas de debug: línea técnica con latencia, modelo,
                        // tokens y respuesta cruda recortada. Solo llega al feed
                        // cuando el modo debug estaba ON al iniciar la reunión.
                        StyledText {
                            id: debugLine
                            visible: e.type === "debug"
                            anchors.top: parent.top
                            anchors.topMargin: 4
                            anchors.left: parent.left
                            anchors.leftMargin: 6
                            anchors.right: parent.right
                            anchors.rightMargin: 6
                            text: "🐞 " + (e.line || "") + (e.detail ? "\n" + e.detail : "")
                            font.pixelSize: 12
                            color: Qt.rgba(0.65, 0.85, 1, 0.9)
                            wrapMode: Text.WordWrap
                        }

                        Column {
                            id: rowC
                            visible: e.type !== "info" && e.type !== "debug"
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
                                    height: Math.max(20, contentCol.implicitHeight)
                                    radius: 2
                                    color: (e.speaker === "you") ? Theme.primary : Qt.rgba(0.9, 0.6, 0.2, 0.9)
                                }
                                Column {
                                    id: contentCol
                                    width: parent.width - 10
                                    spacing: 3
                                    StyledText {
                                        width: parent.width
                                        text: (e.type === "kb_hit" || e.type === "ai_answer" || e.type === "ai_streaming") ? "Auditor" : (e.speaker === "you") ? "Tú" : "Remoto"
                                        font.pixelSize: 12
                                        font.bold: true
                                        color: (e.type === "kb_hit" || (e.type === "ai_streaming" && e.kind === "kb_hit")) ? Qt.rgba(0.35, 0.8, 0.5, 1) : (e.type === "ai_answer" || e.type === "ai_streaming") ? Qt.rgba(0.45, 0.7, 1, 1) : Theme.surfaceVariantText
                                    }
                                    StyledText {
                                        id: txt
                                        width: parent.width
                                        text: e.text || ""
                                        font.pixelSize: 15
                                        color: Theme.surfaceText
                                        wrapMode: Text.WordWrap
                                    }
                                }
                            }

                            StyledText {
                                width: parent.width
                                visible: e.type === "kb_hit" || e.type === "ai_answer" || e.type === "ai_streaming"
                                text: ((e.type === "kb_hit" || (e.type === "ai_streaming" && e.kind === "kb_hit")) ? "📚 " : "💡 ")
                                    + (e.type === "ai_streaming" && win.auditor
                                        ? win.auditor.streamText(e.request_id)
                                        : (e.answer || ""))
                                    + ((e.type === "ai_streaming" && e.streaming !== false) ? " ▍" : "")
                                font.pixelSize: 14
                                color: (e.type === "kb_hit" || (e.type === "ai_streaming" && e.kind === "kb_hit")) ? Qt.rgba(0.35, 0.8, 0.5, 1) : Qt.rgba(0.45, 0.7, 1, 1)
                                wrapMode: Text.WordWrap
                            }
                            StyledText {
                                width: parent.width
                                visible: e.type === "ai_error"
                                text: "⚠️ " + (e.error || "") + (e.partial ? "\nParcial: " + e.partial + (e.incomplete ? " [incompleta]" : "") : "")
                                font.pixelSize: 12
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

            // ── Botón Sugerir (Sprint 1 — un clic) ───────────────────────────
            Rectangle {
                id: suggestBtn
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                height: 36
                radius: 8
                color: suggestMouse.containsMouse ? Qt.rgba(0.6, 0.25, 0.9, 0.35)
                     : Qt.rgba(0.5, 0.2, 0.8, 0.2)
                border.width: 1
                border.color: win.suggestBusy ? Qt.rgba(0.85, 0.55, 1, 0.9)
                     : Qt.rgba(0.7, 0.4, 1, 0.4)

                Rectangle {
                    anchors.fill: parent
                    radius: 8
                    visible: win.suggestBusy
                    color: Qt.rgba(0.72, 0.38, 1, 0.35)
                    SequentialAnimation on opacity {
                        running: win.suggestBusy
                        loops: Animation.Infinite
                        PropertyAnimation { from: 0.2; to: 0.55; duration: 550 }
                        PropertyAnimation { from: 0.55; to: 0.2; duration: 550 }
                    }
                }

                StyledText {
                    anchors.centerIn: parent
                    text: win.suggestBusy
                        ? "💡 Sugiriendo" + "...".substring(0, win.suggestDots)
                        : "💡 Sugerir"
                    font.pixelSize: 13
                    font.bold: true
                    color: Qt.rgba(0.8, 0.6, 1, 0.9)
                }

                Timer {
                    id: suggestDotTimer
                    interval: 350
                    repeat: true
                    running: win.suggestBusy
                    onTriggered: win.suggestDots = (win.suggestDots + 1) % 4
                }

                MouseArea {
                    id: suggestMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    // Un clic crea una solicitud explícita y atómica. El
                    // backend la consume una vez y responde con la
                    // transcripción reciente + contexto; ya no hay que
                    // mantener nada presionado.
                    onClicked: {
                        const requestId = Date.now().toString(36) + "-" + Math.floor(Math.random() * 1679616).toString(36);
                        const issuedAt = Date.now();
                        win.suggestDots = 0;
                        const targetDir = "/tmp/voxtype-auditor";
                        const tmpPath = targetDir + "/.ask_request_" + requestId + ".tmp";
                        const finalPath = targetDir + "/ask_request_" + requestId + ".json";
                        const payload = "{\"id\":\"" + requestId + "\",\"ts\":" + issuedAt + ",\"context_phrases\":10}";
                        if (win.daemon && win.daemon.beginSuggest)
                            win.daemon.beginSuggest(requestId);
                        Proc.runCommand("voxtypeOverlay.suggest",
                            ["sh", "-c", "mkdir -p \"" + targetDir + "\" && printf '%s' '" + payload + "' > \"" + tmpPath + "\" && mv \"" + tmpPath + "\" \"" + finalPath + "\""],
                            () => {});
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
