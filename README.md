# VoxType Recording Overlay + Control Widget (DankMaterialShell plugin)

A native [DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell)
(DMS / Quickshell) plugin for [VoxType](https://github.com/peteonrails/voxtype),
in two halves you can use together or independently:

- **A recording overlay** — while VoxType is dictating it dims every monitor,
  cuts a clear hole around the window you were focused on (so you can see where
  your dictated text will land), draws a themed highlight border around it, and
  shows a pulsing mic. An optional **✕ button** (one per monitor) cancels the
  current dictation by mouse.
- **A bar widget** — a tray-style VoxType control that lives in your DMS bar: a
  status pill (left-click toggles dictation) and a popout to start/stop/restart
  the daemon, switch output mode, pick your microphone, view logs/config, and
  toggle the overlay. For DMS users this **replaces the external SNI tray app**.

Both are **state-reactive** — the plugin watches VoxType's state file and
reacts instantly. There's nothing to wire together: start recording and the
overlay appears and the pill lights up; stop and they clear.

> ## ⚠️ Compatibility — read first
>
> - **DankMaterialShell ≥ 1.5.0** — declared via `requires_dms` in `plugin.json`
>   (the bar-widget + control-center capabilities need 1.5.0). Built and tested
>   on DMS `v1.5.0-134-g069df80b`. It uses DMS's standard plugin API (a
>   `composite` plugin: daemon + widget, `PluginService`, the setting
>   components).
> - **Hyprland** is required only for the active-window **cutout** (the overlay
>   shells out to `hyprctl`). Your Hyprland config can be the classic `.conf`
>   **or** the new `.lua` — it makes no difference; the plugin never reads your
>   Hyprland config, only the `hyprctl` CLI. Without Hyprland the overlay still
>   dims + shows the mic, just no cutout, and the widget works fully.

## Requirements

- **DankMaterialShell** (Quickshell) ≥ 1.5.0 — see Compatibility above.
- **VoxType**, installed and running (the `voxtype` daemon, on your `PATH`).
- **Hyprland** — for the active-window cutout only (any config format).
- For the **widget's controls** (all optional, degrade gracefully if absent):
  - a **`voxtype.service`** systemd *user* unit — for start/stop/restart
    (VoxType's standard install provides this);
  - **`pactl`** (PipeWire or PulseAudio) — to populate the microphone list;
  - **`xdg-open`** — for "Open config" / "View logs".

## Install

```bash
git clone https://github.com/rdannenbring/voxtype-dms-overlay ~/Development/voxtype-dms-overlay
ln -sfn ~/Development/voxtype-dms-overlay ~/.config/DankMaterialShell/plugins/voxtypeOverlay
```

Then enable it in **DMS Settings → Plugins → VoxType Recording Overlay**, and
add the pill to your bar in **Settings → Dank Bar** (look for *VoxType*).

> Editing the plugin later? Edits to existing QML files hot-reload via the **↻
> refresh icon** in Settings → Plugins, or `dms ipc call plugins reload
> voxtypeOverlay`. **Adding a brand-new component file** (or changing the plugin
> `type`) needs a full **`dms restart`** — the QML engine only re-scans the
> plugin directory on a full restart.

## Using it

### Trigger recording (drives the overlay + pill)

Any way of starting VoxType works — the plugin just reacts:

- **VoxType's built-in hotkey** (`[hotkey]` in `~/.config/voxtype/config.toml`),
- **A compositor keybind** bound to `voxtype record toggle` (recommended on
  Hyprland/Sway):
  ```
  bind = , code:191, exec, voxtype record toggle
  ```
  (Hyprland's newer `.lua` config works too. If you use a compositor bind,
  disable the built-in one: `[hotkey] enabled = false`.)
- **The bar widget** — left-click the pill, or "Toggle recording" in its popout.

### The bar widget

- **Pill** — the mic icon reflects VoxType's state: `mic` when idle, **pulsing**
  while recording, `graphic_eq` while transcribing, `mic_off` (in the error
  colour) when the daemon isn't running. **Left-click** toggles dictation;
  **right- or middle-click** opens the control popout.
- **Popout** —
  - **Toggle recording**
  - **Start / Stop / Restart daemon** (`voxtype.service`)
  - **Open config** (`config.toml` in your default editor) · **View logs**
  - **Output** — switch `[output] mode` between *Active window* (type) /
    *Clipboard* / *Paste*
  - **Mic** — pick the `[audio] device` from your input sources (shown by
    PipeWire description, e.g. "Jabra Engage 75 Mono")
  - **Recording overlay** — master on/off for the visual overlay (below)

Changing the output mode or microphone edits `config.toml` and restarts the
VoxType daemon so the change takes effect (a brief model-reload pause).

### Overlay-only or widget-only

- Want **only the bar control**, no full-screen dim? Turn **Recording overlay**
  off (in the popout or Settings). The daemon still tracks state — the pill
  stays live — but no dim/cutout is drawn.
- Want **only the overlay**? Just don't add the pill to your bar.

### Audio feedback (optional)

The overlay is **pure-visual**. For start/stop beeps, use VoxType's own
`[audio.feedback]` in `config.toml` — no extra tooling required.

## Settings (Settings → Plugins → VoxType Recording Overlay)

| Setting | Key | Default |
|---|---|---|
| Recording overlay (master) | `overlayEnabled` | on |
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

This is a DMS **`composite`** plugin: one `plugin.json`, two components that
share state.

- **`OverlayDaemon.qml`** — the single daemon coordinator. Detection is
  **event-driven**: a `FileView` watches VoxType's state file
  (`$XDG_RUNTIME_DIR/voxtype/state`) and reacts on the inotify change, so the
  overlay/pill appear the moment VoxType flips to `recording` — no polling
  latency. A slow `voxtype status` poll remains as a backstop (liveness +
  hide-if-unreadable failsafe + fallback when the state file is absent). On the
  rising edge it captures the active-window rect once (`hyprctl activewindow -j`
  + `hyprctl monitors -j`, run concurrently) and drives one overlay window per
  monitor. It publishes VoxType's state to a plugin global var (`voxState`) so
  the widget's pill reflects it for free.
- **`OverlayWindow.qml`** — one `WlrLayershell.Overlay` `PanelWindow` per
  screen. The monitor with the active window draws a four-rectangle dim "frame"
  leaving the window clear (no shaders/masks) plus a highlight border; other
  monitors dim fully. The focused monitor shows the pulsing mic + label and (if
  enabled) the ✕ button. The surface is click-through **except** the ✕ — its
  input `mask` is just that button's rect — so a stray click passes through and
  recording never traps the pointer.
- **`VoxTypeWidget.qml`** — the bar pill + control popout. Simple actions are
  fire-and-forget (`voxtype record toggle`, `systemctl --user … voxtype.service`).
  Output-mode and mic changes go through **`scripts/voxtype-config-set`**, a
  section-aware POSIX `sh` + `awk` editor that replaces a key's value **in
  place** within its `[section]` (adding the key or section if missing),
  preserving all comments and other settings — never a blind append.
- **Teardown** is declarative: each overlay window's `visible` is bound to
  `active`, so Quickshell destroys the layer surface the instant recording ends
  or the plugin is disabled. Verify no leaks:
  ```bash
  hyprctl layers | grep voxtype-overlay   # empty when idle/disabled
  ```

## Not in this plugin (by design)

- **Audio** (beeps/ducking) — use VoxType's own `[audio.feedback]`.
- **Engine switching** and **meeting mode** — not (yet) surfaced in the widget.
- VoxType's built-in **OSD** waveform sync — deferred to a possible follow-up.

---

## Related VoxType tooling (optional)

The bar widget above **supersedes the standalone SNI tray app for DMS users**.
These portable, cross-desktop tools remain for non-DMS setups:

- [voxtype-hyprland-overlay](https://github.com/rdannenbring/voxtype-hyprland-overlay)
  — a standalone GTK4 recording overlay for any wlroots compositor. If you run
  **both** it and this plugin, disable its overlay so you don't get two dims:
  set `OVERLAY_ENABLED=false` in `~/.config/voxtype-overlay/config.sh`.
- [voxtype-hyprland-overlay-tray](https://github.com/rdannenbring/voxtype-hyprland-overlay-tray)
  — a system-tray controller for any SNI bar (Waybar, KDE, …), for desktops
  without the DMS bar.
