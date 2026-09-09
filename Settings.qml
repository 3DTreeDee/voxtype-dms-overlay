import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

// Settings panel shown in DMS Settings → Plugins → VoxType Recording Overlay.
// Every value is written to pluginData under `settingKey` and read live by
// OverlayDaemon.qml (via pluginData / pluginDataChanged) — no restart needed.
PluginSettings {
    id: root
    pluginId: "voxtypeOverlay"

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
}
