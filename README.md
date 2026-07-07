# VoxType Recording Overlay (DankMaterialShell plugin)

A native [DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell) (DMS /
Quickshell) plugin that reimplements the VoxType recording overlay **inside DMS**,
replacing the standalone Python/GTK4/`gtk4-layer-shell` app for DMS users.

While VoxType is recording or transcribing, it dims every monitor, cuts a clear
hole around the window you were focused on (so you can see where dictated text
will land), draws a themed highlight border around it, and shows a pulsing mic.
It is **state-reactive**: it watches VoxType's status and shows/hides itself —
no launch script and no watchdog. An optional **✕ button** (top-right, one per
monitor) is a mouse escape hatch that cancels the current dictation.

This coexists with (does not replace) the portable tray + GTK overlay projects —
[voxtype-hyprland-overlay](https://github.com/rdannenbring/voxtype-hyprland-overlay)
and
[voxtype-hyprland-overlay-tray](https://github.com/rdannenbring/voxtype-hyprland-overlay-tray)
— those stay the "any Wayland desktop / any SNI bar" option. This is the "DMS
user" option.

## Requirements

- DankMaterialShell (Quickshell)
- `voxtype` on `PATH`
- Hyprland (uses `hyprctl activewindow`/`monitors` for the cutout geometry)

## Install

```bash
git clone <this-repo> ~/Development/voxtype-dms-overlay
ln -sfn ~/Development/voxtype-dms-overlay ~/.config/DankMaterialShell/plugins/voxtypeOverlay
```

Then in **DMS Settings → Plugins**, enable **VoxType Recording Overlay**.

The plugin is **pure-visual**. Audio (start/stop beeps + volume ducking) stays
with the existing shell helper. To avoid two overlays, make the helper
audio-only:

1. Set `OVERLAY_ENABLED=false` in `~/.config/voxtype-overlay/config.sh`
   (keeps beeps/ducking, drops the GTK overlay launch).
2. Keep your keybind pointing at `voxtype-toggle.sh` (now audio-only).
3. Enable this plugin — it provides the visual, reactively.

## How it works

- **`OverlayDaemon.qml`** — the single daemon coordinator. Polls
  `voxtype status --format json` every ~400 ms. When the class becomes
  `recording`/`transcribing` it is *active*; it captures the active-window rect
  once (via `hyprctl activewindow -j` + `hyprctl monitors -j`) and drives one
  window per monitor. A safety backstop hides the overlay if state goes
  unreadable (e.g. the daemon is killed mid-recording).
- **`OverlayWindow.qml`** — one `WlrLayershell.Overlay` `PanelWindow` per screen.
  The monitor with the active window draws a four-rectangle dim "frame" leaving
  the window clear (no shaders/masks) plus a highlight border; other monitors
  dim fully. The focused monitor also shows the pulsing mic + label, and (if enabled) the
  ✕ button. The surface is click-through **except** the ✕: the input `mask` is
  set to just that button's rect, so a stray click elsewhere passes through and
  recording never traps the pointer. The ✕ runs `voxtype record cancel`
  (discard, nothing typed) → state goes idle → the overlay hides.
- **Teardown** is declarative: each window's `visible` is bound to `active`, so
  Quickshell destroys the layer surface the instant recording ends or the plugin
  is disabled. Monitor hotplug is handled by the `Variants` over
  `Quickshell.screens`. Verify no leaks with:

  ```bash
  hyprctl layers | grep voxtype-overlay   # empty when idle/disabled
  ```

## Settings (Settings → Plugins → VoxType Recording Overlay)

| Setting | Key | Default |
|---|---|---|
| Dim opacity | `dimOpacityPct` | 55% |
| Highlight border | `borderEnabled` | on |
| Border width | `borderWidth` | 4px |
| Border color | `borderColor` | theme accent |
| Label text | `recordingLabel` | `RECORDING` |
| Label font size | `labelFontSize` | 18px |
| Mic icon size | `micIconSize` | 128px |
| Custom mic image | `micIconPath` | (themed icon) |
| Pulse animation | `pulseEnabled` | on |
| Pulse min opacity | `pulseMinPct` | 35% |
| Pulse max opacity | `pulseMaxPct` | 100% |
| Pulse period | `pulsePeriodMs` | 2000ms |
| Close button (✕) | `closeButtonEnabled` | on |
| Safety auto-hide | `backstopSeconds` | 5s |

All settings apply live — no DMS restart required.

## Reloading after editing the plugin

DMS does **not** hot-reload plugin QML on file save. After editing any of the
`.qml` files, reload just this plugin from disk (no shell restart needed):

```bash
dms ipc call plugins reload voxtypeOverlay
```

## Not in this plugin (by design)

- **Audio** (beeps + ducking) — stays in the shell helper's `config.sh`.
- **VoxType daemon config** (engine, mic device, output mode, built-in OSD) —
  owned by the daemon/tray.
- The built-in VoxType **OSD** waveform sync is deferred to a possible follow-up.
