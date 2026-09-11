import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Modules.Plugins

// Auditor components (same-dir QML used by the daemon).
import "./auditor_components"

// Root component of the "voxtypeOverlay" daemon plugin.
//
// A daemon-type PluginComponent is instantiated exactly ONCE (not per-screen),
// so it acts as its own coordinator: it polls VoxType's state, captures the
// active-window geometry when a dictation session starts, and drives one
// OverlayWindow per Quickshell.screens via a Variants. The per-screen surfaces
// are created/destroyed declaratively by binding their `visible` to `active` —
// when idle/disabled, no layer surface exists (verify with `hyprctl layers`).
PluginComponent {
    id: root

    layerNamespacePlugin: "voxtype-overlay"

    // ── Live settings (read from pluginData, refreshed on pluginDataChanged) ──
    // Opacities are stored as integer percents so the DMS SliderSetting can use
    // plain integer sliders; divided back to 0.0–1.0 here.
    readonly property real dimOpacity: (pluginData && pluginData.dimOpacityPct !== undefined ? pluginData.dimOpacityPct : 55) / 100
    readonly property bool borderEnabled: (pluginData && pluginData.borderEnabled !== undefined) ? pluginData.borderEnabled : true
    readonly property int borderWidth: (pluginData && pluginData.borderWidth !== undefined) ? pluginData.borderWidth : 4
    readonly property color borderColor: (pluginData && pluginData.borderColor !== undefined && pluginData.borderColor !== "") ? pluginData.borderColor : Theme.primary
    readonly property string recordingLabel: (pluginData && pluginData.recordingLabel !== undefined) ? pluginData.recordingLabel : "RECORDING"
    readonly property int labelFontSize: (pluginData && pluginData.labelFontSize !== undefined) ? pluginData.labelFontSize : 18
    readonly property int micIconSize: (pluginData && pluginData.micIconSize !== undefined) ? pluginData.micIconSize : 128
    readonly property string micIconPath: (pluginData && pluginData.micIconPath !== undefined) ? pluginData.micIconPath : ""
    readonly property bool pulseEnabled: (pluginData && pluginData.pulseEnabled !== undefined) ? pluginData.pulseEnabled : true
    readonly property real pulseMin: (pluginData && pluginData.pulseMinPct !== undefined ? pluginData.pulseMinPct : 35) / 100
    readonly property real pulseMax: (pluginData && pluginData.pulseMaxPct !== undefined ? pluginData.pulseMaxPct : 100) / 100
    readonly property int pulsePeriodMs: (pluginData && pluginData.pulsePeriodMs !== undefined) ? pluginData.pulsePeriodMs : 2000
    readonly property int backstopSeconds: (pluginData && pluginData.backstopSeconds !== undefined) ? pluginData.backstopSeconds : 5
    readonly property bool closeButtonEnabled: (pluginData && pluginData.closeButtonEnabled !== undefined) ? pluginData.closeButtonEnabled : true
    // Master switch for the visual overlay. When off, the daemon still tracks
    // VoxType state (so the bar widget's pill stays live) but never shows the
    // dim/cutout — for users who want only the tray-style widget control.
    readonly property bool overlayEnabled: (pluginData && pluginData.overlayEnabled !== undefined) ? pluginData.overlayEnabled : true

    // ── State ────────────────────────────────────────────────────────────────
    property string statusClass: "idle"
    property bool backstopTripped: false
    property double lastGoodReadMs: 0
    // True while VoxType's status is cleanly readable. Goes false when the
    // command errors/times out (voxtype absent, config broken, daemon down).
    property bool statusReadable: true
    // True once we've successfully read VoxType's state file. When live, the
    // FileView below drives detection event-driven (near-zero latency) and the
    // poll drops to a slow liveness/backstop cadence.
    property bool stateFileLive: false

    // Visible while VoxType reports it is capturing or transcribing, unless the
    // safety backstop has tripped because state went unreadable, or the user has
    // disabled the visual overlay entirely (widget-only mode).
    readonly property bool recordingActive: statusClass === "recording" || statusClass === "transcribing"
    readonly property bool active: recordingActive && !backstopTripped && overlayEnabled

    // Publish VoxType's coarse state to a plugin-global var so the bar widget's
    // pill can reflect it without running its own poll/watch.
    onStatusClassChanged: if (typeof pluginService !== "undefined" && pluginService) pluginService.setGlobalVar(pluginId, "voxState", statusClass)

    // Quick-capture flag written by the bar widget via pluginData: "widget" =>
    // the recording was started from the widget icon, so show a minimal mic-only
    // overlay (no dim/cutout — there's no meaningful target window when you click
    // the bar). Empty/absent => full overlay (hotkey/compositor-initiated).
    // (pluginData is used rather than a PluginGlobalVar because that type isn't
    // resolvable in a daemon component's context — only in the widget's.)
    readonly property bool micOnly: recordingActive && pluginData && pluginData.captureMode === "widget"

    // ── Cutout geometry (captured once, at recording start) ──────────────────
    property bool cutValid: false
    property string cutMonitorName: ""   // monitor whose active window is cut out
    property string micMonitorName: ""   // monitor the mic widget renders on
    property int cutX: 0                  // all in target-monitor-local coordinates
    property int cutY: 0
    property int cutW: 0
    property int cutH: 0
    readonly property int cutPadding: 8  // px breathing room around the window (matches the GTK overlay)

    // Detection is primarily event-driven off VoxType's state file (see the
    // FileView below), so the poll is just a backstop: slow when the state file
    // is live (only to keep `lastGoodReadMs` fresh and catch daemon death), fast
    // when the file is unavailable (poll is then the sole detection path), and
    // right off when VoxType is unreadable and we're idle (so a missing/broken
    // VoxType doesn't spawn a failing process forever).
    readonly property int fastPollMs: 400
    readonly property int livePollMs: 1000
    readonly property int idleErrorPollMs: 3000
    readonly property int pollIntervalMs: (!statusReadable && !recordingActive) ? idleErrorPollMs
                                        : (stateFileLive ? livePollMs : fastPollMs)

    // VoxType's state file: $XDG_RUNTIME_DIR/voxtype/state — a single word
    // ("idle"/"recording"/"transcribing") the daemon rewrites on every state
    // change. Watching it gives instant, subprocess-free detection.
    readonly property string voxStatePath: {
        const rt = Quickshell.env("XDG_RUNTIME_DIR");
        return rt ? (rt + "/voxtype/state") : "";
    }

    function _applyStateWord(t) {
        const word = (t === undefined || t === null) ? "" : ("" + t).trim();
        if (word === "")
            return;
        root.statusClass = word;
        root.lastGoodReadMs = Date.now();
        root.statusReadable = true;
        root.backstopTripped = false;
        root.stateFileLive = true;
    }

    // Event-driven state detection. onFileChanged (inotify) → reload → onLoaded.
    FileView {
        id: stateView
        path: root.voxStatePath
        blockLoading: false
        watchChanges: true
        onLoaded: root._applyStateWord(text())
        onFileChanged: stateView.reload()
        onLoadFailed: root.stateFileLive = false
    }

    // ── State polling (backstop / fallback) ────────────────────────────────────
    function fetchStatus() {
        Proc.runCommand("voxtypeOverlay.status", ["voxtype", "status", "--format", "json"], (stdout, exitCode) => {
            if (exitCode === 0 && stdout && stdout.trim() !== "") {
                try {
                    const s = JSON.parse(stdout.trim());
                    root.statusClass = s.class || s.alt || "idle";
                    root.lastGoodReadMs = Date.now();
                    root.backstopTripped = false;
                    root.statusReadable = true;
                    // Bridge: if the state file wasn't loadable yet (e.g. VoxType
                    // started after us), try again now that it's clearly running.
                    if (!root.stateFileLive && root.voxStatePath !== "")
                        stateView.reload();
                    return;
                } catch (e) {
                    // malformed payload → treat like an unreadable state
                }
            }
            root._handleUnreadable();
        }, 0);
    }

    // Backstop: if we're currently showing but can no longer read VoxType's
    // state (daemon killed, socket gone, …), hide after `backstopSeconds`.
    function _handleUnreadable() {
        root.statusReadable = false;
        if (root.recordingActive && root.lastGoodReadMs > 0 && (Date.now() - root.lastGoodReadMs) > root.backstopSeconds * 1000) {
            root.backstopTripped = true;
        }
    }

    Timer {
        interval: root.pollIntervalMs
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.fetchStatus()
    }

    // ── Cutout capture ────────────────────────────────────────────────────────
    // Captured on the rising edge of `active` (i.e. dictation start). Because
    // recording → transcribing keeps `active` true, the cutout is captured once
    // and preserved through transcription; it is cleared when the overlay hides.
    onActiveChanged: {
        if (active) {
            captureCutout();
        } else {
            cutValid = false;
            // Clear the widget quick-capture flag so the next hotkey-initiated
            // recording gets the full overlay again.
            if (typeof pluginService !== "undefined" && pluginService && pluginData && pluginData.captureMode === "widget")
                pluginService.savePluginData(pluginId, "captureMode", "");
        }
    }

    // Fire both hyprctl queries concurrently (they're independent) and apply
    // once both have returned. `undefined` = "not back yet"; a resolved query is
    // null / [] which is still !== undefined, so the join fires exactly once.
    function captureCutout() {
        let aw = undefined;
        let mons = undefined;
        function tryApply() {
            if (aw !== undefined && mons !== undefined)
                root._applyCapture(aw, mons);
        }
        Proc.runCommand("voxtypeOverlay.activewindow", ["hyprctl", "activewindow", "-j"], (awOut, awExit) => {
            try {
                aw = (awExit === 0 && awOut && awOut.trim() !== "") ? JSON.parse(awOut.trim()) : null;
            } catch (e) {
                aw = null;
            }
            tryApply();
        }, 0);
        Proc.runCommand("voxtypeOverlay.monitors", ["hyprctl", "monitors", "-j"], (monOut, monExit) => {
            try {
                mons = (monExit === 0 && monOut && monOut.trim() !== "") ? JSON.parse(monOut.trim()) : [];
            } catch (e) {
                mons = [];
            }
            tryApply();
        }, 0);
    }

    function _applyCapture(aw, mons) {
        // Focused monitor → where the mic widget renders (independent of whether
        // a window rect was resolvable).
        let focused = null;
        for (let i = 0; i < mons.length; i++) {
            if (mons[i].focused) {
                focused = mons[i];
                break;
            }
        }

        let valid = false;
        if (aw && aw.at && aw.size && aw.size[0] > 0 && aw.size[1] > 0) {
            let awMon = null;
            for (let i = 0; i < mons.length; i++) {
                if (mons[i].id === aw.monitor) {
                    awMon = mons[i];
                    break;
                }
            }
            if (awMon) {
                root.cutMonitorName = awMon.name;
                root.cutX = aw.at[0] - awMon.x - root.cutPadding;
                root.cutY = aw.at[1] - awMon.y - root.cutPadding;
                root.cutW = aw.size[0] + root.cutPadding * 2;
                root.cutH = aw.size[1] + root.cutPadding * 2;
                valid = true;
            }
        }
        root.cutValid = valid;
        if (!valid)
            root.cutMonitorName = "";

        // Prefer the focused monitor for the mic; fall back to the cutout
        // monitor, then the first screen.
        root.micMonitorName = focused ? focused.name : (valid ? root.cutMonitorName : (Quickshell.screens.length > 0 ? Quickshell.screens[0].name : ""));
    }

    // Manual escape hatch (the ✕ button): cancel the current recording/
    // transcription without output. State flips to idle → the overlay hides.
    function cancelRecording() {
        Proc.runCommand("voxtypeOverlay.cancel", ["voxtype", "record", "cancel"], (stdout, exitCode) => {});
    }

    // ── Per-screen overlay surfaces ───────────────────────────────────────────
    // One OverlayWindow per monitor. Variants adds/removes delegates on monitor
    // hotplug automatically; each window's surface only exists while visible.
    Variants {
        model: Quickshell.screens

        OverlayWindow {
            required property var modelData
            screen: modelData
            daemon: root
            auditor: auditorThread
        }
    }

    // ── Auditor de reuniones (milestone 3) ────────────────────────────────────
    // Live settings para el auditor (leídos de pluginData, refresh automático).
    readonly property bool auditorEnabled: (pluginData && pluginData.auditorEnabled !== undefined) ? pluginData.auditorEnabled : false
    // Swap de modelo OFF por defecto: cambiarlo ejecuta `systemctl restart
    // voxtype`, y como el widget YA arrancó la reunión, el restart la MATA
    // (la ventana del auditor aparece y desaparece). Las captions en vivo del
    // auditor usan su propio whisper-server (large-v3-turbo) independiente del
    // `whisper.model` de voxtype; el respaldo de voxtype queda con `small`.
    readonly property bool auditorSwapModel: (pluginData && pluginData.auditorSwapModel !== undefined) ? pluginData.auditorSwapModel : false
    readonly property string auditorModelMeeting: (pluginData && pluginData.auditorModelMeeting !== undefined && pluginData.auditorModelMeeting !== "") ? pluginData.auditorModelMeeting : "large-v3-turbo"
    readonly property string auditorModelDictado: (pluginData && pluginData.auditorModelDictado !== undefined && pluginData.auditorModelDictado !== "") ? pluginData.auditorModelDictado : "small"
    // auditorVault: null/undefined/"" en pluginData → "" (default del helper:
    // ~/Documentos/vault). NUNCA pasar null al comando (rompe la KB).
    readonly property string auditorVault: {
        const v = (pluginData && pluginData.auditorVault !== undefined && pluginData.auditorVault !== null) ? pluginData.auditorVault : "";
        return (typeof v === "string") ? v : "";
    }
    readonly property string auditorScriptDir: {
        const d = (pluginData && pluginData.auditorScriptDir !== undefined && pluginData.auditorScriptDir !== null) ? pluginData.auditorScriptDir : "";
        return (typeof d === "string") ? d : "";
    }
    // Fuentes de audio FIJAS del auditor (Settings → VoxType): "" = resolver
    // el default del sistema UNA vez al arrancar; si vienen definidas se usan
    // tal cual (--mic-source/--loop-source), SIN re-resolver ni switchear.
    readonly property string auditorMicSource: (pluginData && pluginData.auditorMicSource !== undefined && pluginData.auditorMicSource !== null) ? pluginData.auditorMicSource : ""
    readonly property string auditorLoopSource: (pluginData && pluginData.auditorLoopSource !== undefined && pluginData.auditorLoopSource !== null) ? pluginData.auditorLoopSource : ""

    // Una sola fuente de verdad: `meetingRunning` lo sincroniza el widget via
    // pluginData.auditorMeetingActive (mismo canal que el resto de config).
    property bool meetingRunning: false

    // Swap + arranque del auditor al ENTRAR en reunión; revertir + parar al salir.
    onMeetingRunningChanged: {
        if (meetingRunning) startAuditor();
        else stopAuditor();
    }

    // Sincronizar `meetingRunning` desde pluginData (el widget lo escribe cuando
    // detecta que una reunión empieza/termina). La PRIMERA vez reconciliamos
    // contra el estado real de voxtype: si el flag quedó pegado en `true` por
    // una reunión interrumpida (DMS matado a mitad), el panel del auditor se
    // mostraría durante el dictado normal con el feed viejo.
    property bool meetingReconciled: false
    onPluginDataChanged: {
        if (pluginData && pluginData.auditorMeetingActive !== undefined)
            root.meetingRunning = pluginData.auditorMeetingActive;
        if (!root.meetingReconciled && pluginData && pluginData.auditorMeetingActive !== undefined) {
            root.meetingReconciled = true;
            root.reconcileMeetingState();
        }
    }

    function reconcileMeetingState() {
        Proc.runCommand("voxtypeOverlay.meetingReconcile", ["voxtype", "meeting", "status"],
            (out, exit) => {
                const t = (out || "").trim();
                const active = (exit === 0) && t !== "" && t.indexOf("no meeting currently in progress") === -1;
                if (!active && root.meetingRunning) {
                    root.meetingRunning = false;
                    if (typeof pluginService !== "undefined" && pluginService)
                        pluginService.savePluginData(pluginId, "auditorMeetingActive", false);
                }
            }, 0, 5000);
    }

    // Resolver path al launcher del auditor (run.sh: gestiona venv propio,
    // portable a cualquier máquina sin depender del venv de Hermes).
    function auditorScript() {
        if (root.auditorScriptDir !== "")
            return root.auditorScriptDir + "/audit/run.sh";
        const home = Quickshell.env("HOME") || "";
        return home + "/.config/DankMaterialShell/plugins/voxtypeOverlay/audit/run.sh";
    }

    function swapScript() {
        const py = root.auditorScript();
        return py.replace(/\/audit\/run\.sh$/, "/scripts/voxtype-model-swap.sh");
    }

    // El thread que vigila el auditor (levanta el helper, parsea JSONL).
    AuditorThread {
        id: auditorThread
        autoStart: false
        debugMode: root.auditorDebug
    }

    // Estado compartido de Sugerir: un clic en cualquier pantalla marca el ID
    // activo y todas las superficies muestran la misma animación/ocupado.
    property string activeSuggestId: ""
    property bool suggestBusy: false

    function beginSuggest(requestId) {
        root.activeSuggestId = requestId;
        root.suggestBusy = true;
        suggestTimeout.restart();
    }

    function clearSuggest(requestId) {
        if (requestId && requestId !== root.activeSuggestId)
            return;
        root.activeSuggestId = "";
        root.suggestBusy = false;
        suggestTimeout.stop();
    }

    function clearSuggestIfDone(evt) {
        if (!root.suggestBusy || !evt || evt.request_id !== root.activeSuggestId)
            return;
        if (evt.type === "ai_answer" || evt.type === "kb_hit" || evt.type === "ai_error"
                || evt.type === "ai_stream_done" || evt.type === "ai_stream_error")
            root.clearSuggest(evt.request_id);
        else if (evt.type === "info" && evt.msg === "Aún no hay transcripción para sugerir.")
            root.clearSuggest(evt.request_id);
    }

    Connections {
        target: auditorThread
        function onEventReceived(evt) {
            root.clearSuggestIfDone(evt);
        }
    }

    Timer {
        id: suggestTimeout
        interval: 65000
        repeat: false
        onTriggered: root.clearSuggest("")
    }

    // El feed del auditor se integra dentro de OverlayWindow (PanelWindow ya
    // registrado y mostrado por Variants más arriba) — le pasamos el thread.
    // (Un PanelWindow nuevo `AuditorOverlay` no se registra como tipo en DMS
    // sin reinstalar el plugin; reutilizar OverlayWindow evita ese problema.)

    function startAuditor() {
        if (!root.auditorEnabled) return;

        // NO se hace swap de modelo aquí: cambiar `whisper.model` ejecuta
        // `systemctl restart voxtype`, y como el widget ya arrancó la reunión,
        // el restart la mata → la ventana aparece y desaparece. Las captions en
        // vivo usan el whisper-server propio del auditor (large-v3-turbo), así
        // que el modelo de dictado de voxtype se queda intacto (`small`).

        // 1) Arrancar primero el auditor en modo capture (Fase 6): la captura
        // continua y whisper-server arrancan en paralelo con la grabación de
        // respaldo, reduciendo la primera frase perdida.
        auditorThread.stop();
        let args = [root.auditorScript()];
        if (root.auditorVault !== "")
            args = args.concat(["--vault", root.auditorVault]);
        // OJO: --mic-source/--loop-source pertenecen al SUBPARSER
        // `capture` (argparse) → SIEMPRE después de "capture"; antes
        // provoca "unrecognized arguments" y el proceso muere (exit 2).
        args = args.concat(["capture"]);
        if (root.auditorDebug)
            args = args.concat(["--debug"]);
        if (root.auditorMicSource !== "")
            args = args.concat(["--mic-source", root.auditorMicSource]);
        if (root.auditorLoopSource !== "")
            args = args.concat(["--loop-source", root.auditorLoopSource]);
        auditorThread.commandModel = args;
        auditorThread.start();

        // 2) Arrancar voxtype meeting (grabación COMPLETA de respaldo → transcript.json
        //    al hacer stop; es la que se exporta/indexa para RAG)
        Proc.runCommand("voxtypeOverlay.startMeeting", ["voxtype", "meeting", "start"],
            (stdout, exitCode) => {}, 0, 10000);
    }

    function stopAuditor() {
        root.clearSuggest("");
        auditorThread.stop();

        // Detener voxtype meeting
        Proc.runCommand("voxtypeOverlay.stopMeeting", ["voxtype", "meeting", "stop"],
            (stdout, exitCode) => {}, 0, 10000);
    }

    function setAuditorEnabled(v) {
        if (typeof pluginService !== "undefined" && pluginService)
            pluginService.savePluginData(pluginId, "auditorEnabled", v);
    }

    // Auto-scroll del feed del auditor: ON = el feed queda pegado abajo con
    // cada frase nueva; OFF = scroll libre (no salta). Persistido en pluginData.
    readonly property bool auditorAutoScroll: (pluginData && pluginData.auditorAutoScroll !== undefined) ? pluginData.auditorAutoScroll : true

    // Modo debug del auditor: muestra métricas por etapa en el feed y guarda
    // JSONL/CSV de la sesión. El proceso auditor lo lee al arrancar.
    readonly property bool auditorDebug: (pluginData && pluginData.auditorDebug !== undefined) ? pluginData.auditorDebug : false

    function setAuditorAutoScroll(v) {
        if (typeof pluginService !== "undefined" && pluginService)
            pluginService.savePluginData(pluginId, "auditorAutoScroll", !!v);
    }

    // ── Persistencia del panel del auditor (tamaño/posición) ─────────────────
    // El usuario redimensiona/mueve el feed; guardamos para la siguiente
    // reunión. 0/negativo = sin preferencia (defaults por tamaño de pantalla).
    readonly property int auditorPanelW: (pluginData && pluginData.auditorPanelW !== undefined) ? pluginData.auditorPanelW : 0
    readonly property int auditorPanelH: (pluginData && pluginData.auditorPanelH !== undefined) ? pluginData.auditorPanelH : 0
    readonly property int auditorPanelX: (pluginData && pluginData.auditorPanelX !== undefined) ? pluginData.auditorPanelX : -1
    readonly property int auditorPanelY: (pluginData && pluginData.auditorPanelY !== undefined) ? pluginData.auditorPanelY : -1

    function saveAuditorPanel(w, h, x, y) {
        if (typeof pluginService === "undefined" || !pluginService) return;
        pluginService.savePluginData(pluginId, "auditorPanelW", Math.max(0, Math.round(w)));
        pluginService.savePluginData(pluginId, "auditorPanelH", Math.max(0, Math.round(h)));
        pluginService.savePluginData(pluginId, "auditorPanelX", Math.max(-1, Math.round(x)));
        pluginService.savePluginData(pluginId, "auditorPanelY", Math.max(-1, Math.round(y)));
    }
}
