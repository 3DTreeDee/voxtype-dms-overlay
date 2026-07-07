# VoxType Recording Overlay (DankMaterialShell plugin)

A native [DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell)
(DMS / Quickshell) plugin that shows a recording overlay while
[VoxType](https://github.com/peteonrails/voxtype) is dictating. It dims every
monitor, cuts a clear hole around the window you were focused on (so you can see
where your dictated text will land), draws a themed highlight border around it,
and shows a pulsing mic. An optional **✕ button** (top-right, one per monitor)
cancels the current dictation by mouse.

It's **state-reactive** — the plugin watches VoxType's status and shows/hides
itself. There's nothing to wire together: whenever VoxType starts recording the
overlay appears, and when it stops the overlay disappears.

## Requirements

- **DankMaterialShell** (Quickshell) — this is a DMS plugin.
- **VoxType**, installed and running (the `voxtype` daemon, on your `PATH`).
- **Hyprland** — the active-window cutout uses `hyprctl activewindow`/`monitors`.
  Without Hyprland the overlay still dims + shows the mic, but there's no cutout.

## Install

```bash
git clone https://github.com/rdannenbring/voxtype-dms-overlay ~/Development/voxtype-dms-overlay
ln -sfn ~/Development/voxtype-dms-overlay ~/.config/DankMaterialShell/plugins/voxtypeOverlay
```

Then enable it in **DMS Settings → Plugins → VoxType Recording Overlay**.

> Editing the plugin later? DMS doesn't hot-reload plugin QML on save — reload
> just this plugin (no shell restart) with:
> `dms ipc call plugins reload voxtypeOverlay`

## Using it

The overlay reacts to VoxType's recording state, so all you need is a way to
start recording — either works:

- **VoxType's built-in hotkey** — on by default (`[hotkey]` in
  `~/.config/voxtype/config.toml`). Press it; the overlay appears.
- **A compositor keybind** bound to `voxtype record toggle` — recommended on
  Hyprland/Sway. Example (Hyprland Lua config):
  ```lua
  hl.bind("code:191", hl.dsp.exec_cmd("voxtype record toggle"))
  ```
  If you use a compositor bind, disable the built-in one: `[hotkey] enabled = false`.

Start recording and the overlay does the rest — no launch script, no watchdog.

### Audio feedback (optional)

This plugin is **pure-visual**. If you want start/stop beeps, VoxType has its own
`[audio.feedback]` section in `config.toml` — set `enabled = true`. No extra
tooling required.

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

All settings apply live — no restart required.

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
  dim fully. The focused monitor also shows the pulsing mic + label, and (if
  enabled) the ✕ button. The surface is click-through **except** the ✕ — its
  input `mask` is just that button's rect — so a stray click elsewhere passes
  through and recording never traps the pointer. The ✕ runs
  `voxtype record cancel` (discard, nothing typed) → state goes idle → hide.
- **Teardown** is declarative: each window's `visible` is bound to `active`, so
  Quickshell destroys the layer surface the instant recording ends or the plugin
  is disabled. Monitor hotplug is handled by the `Variants` over
  `Quickshell.screens`. Verify no leaks:
  ```bash
  hyprctl layers | grep voxtype-overlay   # empty when idle/disabled
  ```

## Not in this plugin (by design)

- **Audio** (beeps/ducking) — use VoxType's own `[audio.feedback]`.
- **VoxType daemon config** (engine, mic device, output mode) — configured in
  VoxType itself.
- VoxType's built-in **OSD** waveform sync — deferred to a possible follow-up.

---

## Also using the standalone overlay / tray? (optional)

**You don't need anything here to use this plugin** — it stands alone. This note
is only relevant if you *also* run the portable, cross-desktop VoxType tooling:

- [voxtype-hyprland-overlay](https://github.com/rdannenbring/voxtype-hyprland-overlay)
  — a standalone GTK4 recording overlay for any wlroots compositor. If you run
  **both** it and this plugin, disable its overlay so you don't get two dims:
  set `OVERLAY_ENABLED=false` in `~/.config/voxtype-overlay/config.sh` (it keeps
  its beeps/ducking, just stops drawing the GTK overlay).
- [voxtype-hyprland-overlay-tray](https://github.com/rdannenbring/voxtype-hyprland-overlay-tray)
  — a system-tray controller for any SNI bar (Waybar, KDE, …). Independent of
  this plugin; use either, both, or neither.
