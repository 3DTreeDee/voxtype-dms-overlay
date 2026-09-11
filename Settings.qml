import QtQuick
import Quickshell
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

// Settings panel shown in DMS Settings → Plugins → VoxType Recording Overlay.
// Every value is written to pluginData under `settingKey` and read live by
// OverlayDaemon.qml (via pluginData / pluginDataChanged) — no restart needed.
PluginSettings {
    id: root
    pluginId: "voxtypeOverlay"

    // ── Prueba de conexión IA (Fase 1 plan auditor v2) ─────────────────────
    // Estado del check: "idle" | "testing" | "ok" | "error"
    property string aiTestState: "idle"
    property string aiTestDetail: ""
    property var aiModels: []      // catálogo completo (para el dropdown Fase 2)
    property var aiAutoModels: []  // aliases auto/* (recomendados primero)

    // Resuelve el path al helper de check. Prefiere la config del daemon
    // (auditorScriptDir apunta al fork en dev) y cae al plugin instalado.
    function aiCheckScriptPath() {
        const dir = root.loadValue("auditorScriptDir", "");
        if (dir)
            return dir + "/audit/check_omniroute.py";
        const home = Quickshell.env("HOME") || "";
        return home + "/.config/DankMaterialShell/plugins/voxtypeOverlay/audit/check_omniroute.py";
    }

    function testAiConnection() {
        root.aiTestState = "testing";
        root.aiTestDetail = "";
        Proc.runCommand("voxtypeOverlay.aiTest", ["python3", root.aiCheckScriptPath()],
            (stdout, exitCode) => {
                let parsed = null;
                try { parsed = JSON.parse(stdout); } catch (e) { /* noop */ }
                if (exitCode === 0 && parsed && parsed.ok) {
                    root.aiTestState = "ok";
                    root.aiTestDetail = "✓ Conectado a " + parsed.base + " — "
                        + parsed.count + " modelos disponibles, "
                        + parsed.latency_ms + " ms";
                    root.aiModels = parsed.models || [];
                    root.aiAutoModels = parsed.auto || [];
                } else {
                    root.aiTestState = "error";
                    const msg = parsed && parsed.error ? parsed.error : ("exit " + exitCode);
                    root.aiTestDetail = "✗ " + msg;
                    root.aiModels = [];
                    root.aiAutoModels = [];
                }
            }, 0, 25000);
    }

    // Opciones para el dropdown del modelo: auto/* primero, luego el resto.
    readonly property var aiModelOptions: {
        const opts = [];
        const autos = root.aiAutoModels;
        const all = root.aiModels;
        if (autos.length > 0) {
            opts.push({ label: "auto/best-chat (recomendado)", value: "auto/best-chat" });
            for (let i = 0; i < autos.length; i++) {
                const m = autos[i];
                if (m !== "auto/best-chat")
                    opts.push({ label: m, value: m });
            }
            if (all.length > autos.length) {
                opts.push({ label: "─── otros modelos ───", value: "───────" });
                for (let i = 0; i < all.length; i++) {
                    const m = all[i];
                    if (!autos.includes(m))
                        opts.push({ label: m, value: m });
                }
            }
        }
        return opts;
    }

    StyledText {
        width: parent.width
        text: "VoxType Recording Overlay"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "Dims the screen and highlights the active window while VoxType is recording or transcribing. This is a pure-visual overlay — for start/stop beeps, enable VoxType's own [audio.feedback] in config.toml."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    ToggleSetting {
        settingKey: "overlayEnabled"
        label: "Recording overlay"
        description: "Show the full-screen dim + cutout while recording. Turn off to use only the bar widget (tray-style control) without the overlay."
        defaultValue: true
    }

    SliderSetting {
        settingKey: "dimOpacityPct"
        label: "Dim opacity"
        description: "How dark the overlay dims the screen."
        defaultValue: 55
        minimum: 0
        maximum: 100
        unit: "%"
        leftIcon: "opacity"
    }

    ToggleSetting {
        settingKey: "borderEnabled"
        label: "Highlight border"
        description: "Draw a border around the active window."
        defaultValue: true
    }

    SliderSetting {
        settingKey: "borderWidth"
        label: "Border width"
        defaultValue: 4
        minimum: 0
        maximum: 20
        unit: "px"
        leftIcon: "border_style"
    }

    ColorSetting {
        settingKey: "borderColor"
        label: "Border color"
        description: "Defaults to your theme accent color."
        defaultValue: Theme.primary
    }

    StringSetting {
        settingKey: "recordingLabel"
        label: "Label text"
        description: "Shown under the mic. Leave blank for no label."
        defaultValue: "RECORDING"
        placeholder: "RECORDING"
    }

    SliderSetting {
        settingKey: "labelFontSize"
        label: "Label font size"
        defaultValue: 18
        minimum: 8
        maximum: 48
        unit: "px"
        leftIcon: "format_size"
    }

    SliderSetting {
        settingKey: "micIconSize"
        label: "Mic icon size"
        defaultValue: 128
        minimum: 32
        maximum: 320
        unit: "px"
        leftIcon: "mic"
    }

    StringSetting {
        settingKey: "micIconPath"
        label: "Custom mic image"
        description: "Absolute path to a PNG/SVG to use instead of the themed mic icon. Blank = themed icon."
        defaultValue: ""
        placeholder: "/path/to/mic.svg"
    }

    ToggleSetting {
        settingKey: "pulseEnabled"
        label: "Pulse animation"
        description: "Fade the mic icon in and out while recording."
        defaultValue: true
    }

    SliderSetting {
        settingKey: "pulseMinPct"
        label: "Pulse min opacity"
        defaultValue: 35
        minimum: 0
        maximum: 100
        unit: "%"
    }

    SliderSetting {
        settingKey: "pulseMaxPct"
        label: "Pulse max opacity"
        defaultValue: 100
        minimum: 0
        maximum: 100
        unit: "%"
    }

    SliderSetting {
        settingKey: "pulsePeriodMs"
        label: "Pulse period"
        description: "Full fade-out-and-back cycle length."
        defaultValue: 2000
        minimum: 400
        maximum: 5000
        unit: "ms"
    }

    ToggleSetting {
        settingKey: "closeButtonEnabled"
        label: "Close button (✕)"
        description: "Show a ✕ in the top-right of each monitor to cancel the current dictation by mouse. The rest of the overlay stays click-through."
        defaultValue: true
    }

    SliderSetting {
        settingKey: "backstopSeconds"
        label: "Safety auto-hide"
        description: "Hide the overlay if VoxType's state can't be read for this many seconds (failsafe if the daemon dies mid-recording)."
        defaultValue: 5
        minimum: 2
        maximum: 30
        unit: "s"
        leftIcon: "timer"
    }

    StyledText {
        width: parent.width
        text: "Bar widget"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    ToggleSetting {
        settingKey: "widgetAutoPaste"
        label: "Widget capture auto-pastes"
        description: "Starting a recording from the bar widget shows only a mic (no dim/cutout — there's no target window when you click the bar) and sends text to the clipboard. Enable this to auto-paste it (clipboard + Ctrl+V) instead."
        defaultValue: false
    }

    ToggleSetting {
        settingKey: "engineSwitcherEnabled"
        label: "Show engine switcher"
        description: "Show an engine picker in the widget popout, built from your ~/.config/voxtype/use-*.sh preset scripts. Hidden automatically if you have none."
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "meetingEnabled"
        label: "Meeting controls"
        description: "Show meeting-mode controls (start / pause / resume / stop, ML diarization, open meetings folder) in the widget popout."
        defaultValue: false
    }

    // ── Auditor: IA para responder preguntas (RAG) ──────────────────────────
    StyledText {
        width: parent.width
        text: "Auditor IA (RAG)"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "Cuando está configurado, el auditor responde preguntas de ambos lados (Tú y Remoto) analizando la conversación, buscando en tu vault de Obsidian y, si no encuentra nada, respondiendo con su propio conocimiento. Sin configurar, funciona como hasta ahora (solo búsqueda por similitud en el vault)."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    // ── Respuestas automáticas (Fase 3) — default OFF, solo captions ──────
    ToggleSetting {
        settingKey: "auditorAutoReply"
        label: "Respuestas automáticas"
        description: "Cuando está OFF (default), el auditor SOLO muestra transcripción en vivo (closed captions) sin llamar a la IA. Cuando está ON, analiza cada enunciado automáticamente y responde preguntas buscando en el vault de Obsidian. Se recomienda mantenerlo OFF y activarlo solo cuando quieras respuestas sin preguntar explícitamente."
        defaultValue: false
    }

    // ── Búsqueda en vault (Fase 5) ─────────────────────────────────────────
    ToggleSetting {
        settingKey: "auditorVaultSearch"
        label: "Buscar en vault de Obsidian"
        description: "Cuando está ON, el auditor busca en tus notas de Obsidian antes de responder. Cuando está OFF, la IA responde solo con su conocimiento general."
        defaultValue: true
    }

    SliderSetting {
        settingKey: "auditorKbThreshold"
        label: "Umbral de similitud del vault"
        description: "Qué tan similar debe ser el resultado del vault para considerarlo relevante (0=relajado, 100=exigente). Recomendado: 70."
        defaultValue: 70
        minimum: 0
        maximum: 100
        unit: "%"
        leftIcon: "unfold_less"
        rightIcon: "unfold_more"
    }

    StringSetting {
        settingKey: "auditorAiBaseUrl"
        label: "API base URL"
        description: "Endpoint compatible con OpenAI. Ej: https://api.omniroute.ai/v1"
        defaultValue: "https://api.omniroute.ai/v1"
        placeholder: "https://api.omniroute.ai/v1"
    }

    StringSetting {
        settingKey: "auditorAiModel"
        label: "Modelo"
        description: "Ej: gpt-4o-mini (rápido/barato) o gpt-4o (precisión)"
        defaultValue: "gpt-4o-mini"
        placeholder: "gpt-4o-mini"
    }

    StringSetting {
        settingKey: "auditorAiApiKey"
        label: "API key"
        description: "Tu API key de OmniRoute/OpenAI — solo se guarda localmente y nunca aparece en procesos del sistema."
        defaultValue: ""
        placeholder: "sk-..."
    }

    // ── Modo debug del auditor (Sprint 1) ─────────────────────────────────
    ToggleSetting {
        settingKey: "auditorDebug"
        label: "Modo debug del auditor"
        description: "Cuando está ON, el feed muestra latencias por etapa (VAD, Whisper, IA), modelo, tokens y un resumen de la respuesta cruda. También guarda métricas JSONL/CSV por sesión en ~/.local/share/voxtype-auditor/metrics. Se aplica al iniciar la próxima reunión."
        defaultValue: false
    }

    // ── Probar conexión + estado (Fase 1) ──────────────────────────────────
    Item {
        width: parent.width
        height: Math.max(aiTestButton.height, aiTestStatus.implicitHeight + Theme.spacingS * 2)

        DankButton {
            id: aiTestButton
            anchors.left: parent.left
            anchors.leftMargin: Theme.spacingM
            anchors.verticalCenter: parent.verticalCenter
            text: root.aiTestState === "testing" ? "Probando…" : "Probar conexión"
            iconName: root.aiTestState === "ok" ? "check_circle" : (root.aiTestState === "error" ? "error" : "wifi_tethering")
            enabled: root.aiTestState !== "testing"
            onClicked: root.testAiConnection()
        }

        StyledText {
            id: aiTestStatus
            anchors.left: aiTestButton.right
            anchors.leftMargin: Theme.spacingM
            anchors.right: parent.right
            anchors.rightMargin: Theme.spacingM
            anchors.verticalCenter: parent.verticalCenter
            text: root.aiTestState === "idle"
                ? "Verifica que la base URL y la API key funcionan y lista los modelos disponibles."
                : root.aiTestDetail
            font.pixelSize: Theme.fontSizeSmall
            color: root.aiTestState === "ok" ? "#6fce7a"
                 : root.aiTestState === "error" ? "#ef8f8f"
                 : Theme.surfaceVariantText
            wrapMode: Text.WordWrap
        }
    }

    // ── Selector de modelo (Fase 2) — aparece tras check exitoso ──────────
    SelectionSetting {
        id: aiModelSelector
        settingKey: "auditorAiModel"
        label: "Modelo IA para el auditor"
        description: {
            if (root.aiTestState === "ok")
                return root.aiAutoModels.length + " recomendados (" + root.aiModels.length + " totales). Los alias auto/* se adaptan al mejor provider disponible.";
            if (root.aiTestState === "error")
                return "Corrige la conexión antes de seleccionar modelo.";
            return "Primero presiona \"Probar conexión\" para ver los modelos disponibles en tu servicio.";
        }
        options: root.aiTestState === "ok" ? root.aiModelOptions : [root.loadValue("auditorAiModel", "auto/best-chat")]
        defaultValue: "auto/best-chat"
    }

    // ── Dispositivos de audio del auditor (fijos, sin auto-switch) ────────
    // Requisito del usuario (2026-09-09): el auditor usa EXACTAMENTE estas
    // fuentes durante la reunión. NO re-resuelve el "default" de PipeWire en
    // cada arranque — los audífonos Bluetooth cambian el default al
    // reconectarse y la heurística elegía monitores equivocados (frases
    // duplicadas you→remote). "System default" = resolución única al arrancar
    // (comportamiento previo, sin fijar).
    property var audioMicOptions: []
    property var audioLoopOptions: []

    function refreshAudioDevices() {
        Proc.runCommand("voxtypeOverlay.audDevices", ["pactl", "-f", "json", "list", "sources"], (out, exit) => {
            const mics = [{ label: "System default", value: "" }];
            const loops = [{ label: "System default", value: "" }];
            if (exit === 0 && out) {
                try {
                    const arr = JSON.parse(out);
                    for (let i = 0; i < arr.length; i++) {
                        const s = arr[i];
                        if (!s || !s.name) continue;
                        const isMon = s.name.endsWith(".monitor");
                        const label = (s.description && s.description !== "") ? s.description : s.name;
                        if (isMon) {
                            // monitor de auto_null/silence no sirve
                            if (s.name.indexOf("auto_null") >= 0) continue;
                            loops.push({ label: label, value: s.name });
                        } else {
                            // Mics: EXCLUIR los Bluetooth (bluez_input): usarlos
                            // cambia el perfil BT a HFP (manos libres), degrada
                            // el audio y realimenta la voz del usuario al sink →
                            // captions duplicados/eco. Para reuniones del auditor
                            // solo mics físicos (webcam/USB).
                            if (s.name.indexOf("bluez_input") === 0) continue;
                            if (s.name.indexOf("echo") >= 0 || s.name.indexOf("aec") >= 0) continue;
                            if (s.name.indexOf("auto_null") >= 0) continue;
                            mics.push({ label: label, value: s.name });
                        }
                    }
                } catch (e) {
                    // JSON malformado → solo "System default"
                }
            }
            root.audioMicOptions = mics;
            root.audioLoopOptions = loops;
        }, 0);
    }

    Component.onCompleted: root.refreshAudioDevices()

    Item {
        width: parent.width
        height: Math.max(refreshAudioBtn.height, audioDevNote.implicitHeight + Theme.spacingS * 2)

        DankButton {
            id: refreshAudioBtn
            anchors.left: parent.left
            anchors.leftMargin: Theme.spacingM
            anchors.verticalCenter: parent.verticalCenter
            text: "Refrescar dispositivos"
            iconName: "refresh"
            onClicked: root.refreshAudioDevices()
        }

        StyledText {
            id: audioDevNote
            anchors.left: refreshAudioBtn.right
            anchors.leftMargin: Theme.spacingM
            anchors.right: parent.right
            anchors.rightMargin: Theme.spacingM
            anchors.verticalCenter: parent.verticalCenter
            text: "Detecta micrófonos y altavoces de PipeWire. Conecta tus audífonos Bluetooth ANTES de fijar la selección — el auditor no cambiará de dispositivo aunque PipeWire mueva el default."
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            wrapMode: Text.WordWrap
        }
    }

    SelectionSetting {
        settingKey: "auditorMicSource"
        label: "Micrófono del auditor (lado Tú)"
        description: "Fuente FIJA para tus captions en reuniones. No cambia aunque PipeWire altere el dispositivo por defecto."
        options: root.audioMicOptions
        defaultValue: ""
    }

    SelectionSetting {
        settingKey: "auditorLoopSource"
        label: "Altavoces del auditor (lado Remoto)"
        description: "Monitor de salida FIJO que captura lo que oyes del interlocutor remoto. Selecciónalo con tus audífonos/altavoces ya conectados."
        options: root.audioLoopOptions
        defaultValue: ""
    }
}
