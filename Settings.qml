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
        text: "Dims the screen and highlights the active window while VoxType is recording or transcribing. Audio (beeps/ducking) stays with the shell helper — set OVERLAY_ENABLED=false in ~/.config/voxtype-overlay/config.sh so it no longer launches the GTK overlay."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
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
}
