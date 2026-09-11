import QtQuick
import Quickshell
import Quickshell.Io

// AuditorThread — levanta el helper Python del auditor y publica sus eventos.
//
// Lanza `audit/auditor.py watch <transcript>` como proceso de streaming y usa
// un SplitParser (como el plugin dankSoftwareDepot) para consumir cada línea
// JSONL que el helper emite por stdout: {type: enunciado|kb_hit|ai_answer|
// ai_error|info|ai_stream_start|ai_stream_delta|ai_stream_done|ai_stream_error, ...}.
// Las traduce a un signal QML y mantiene una cola `events`
// para que la UI (AuditorOverlay / widget) la pinte.
//
// Arranque/parada: set `command` + `running` (API Quickshell verificada).

Item {
    id: root

    // ── Config ───────────────────────────────────────────────────────────────
    // Comando completo del helper. Usamos `command` (array) como API real de
    // Quickshell Process. Setear desde el daemon al iniciar una reunión.
    property var commandModel: []
    property bool autoStart: false

    // ── Estado ───────────────────────────────────────────────────────────────
    property bool running: false
    property string status: "stopped"     // stopped | starting | running | error

    // Cola de eventos recientes para que la UI haga binding (sin stream).
    property var events: []
    readonly property int maxEvents: 40

    // Texto parcial por request_id. Los deltas actualizan este mapa y una
    // revisión, sin reemplazar todo el arreglo por cada token.
    property var streamTexts: ({})
    property int streamRevision: 0

    // El daemon enlaza esta propiedad al toggle de debug. Los eventos de
    // debug se reciben pero no se guardan en el feed cuando está OFF.
    property bool debugMode: false

    // Signal que emite CADA evento parseado (para consumidores en vivo).
    signal eventReceived(var evt)

    // El proceso Quickshell. API real (verificada en dankSoftwareDepot):
    //  - command: array
    //  - running: true/false para arrancar/parar
    //  - stdout: SplitParser { onRead } — por línea (perfecto JSONL)
    //  - stderr: StdioCollector { onStreamFinished }
    //  - onExited: (exitCode, exitStatus)
    Process {
        id: proc
        command: root.commandModel
        running: false   // arrancamos manualmente via root.start()

        stdout: SplitParser {
            onRead: line => root._handleLine(line)
        }

        stderr: StdioCollector {
            onStreamFinished: {
                const t = (text || "").trim();
                if (t !== "") root.status = "error: " + t;
            }
        }

        onExited: (exitCode, exitStatus) => {
            root.running = false;
            root.status = "error";
            root._failActiveStreams("proceso terminado");
            root._emitInfo("auditor_process_exit(" + exitCode + ")");
        }
    }

    function resolveHelperScript() {
        // El helper vive en el directorio del plugin. DMS resuelve desde
        // <config>/DankMaterialShell/plugins/<id>/. Podemos construirlo desde
        // una env/property; por defecto tomamos el path absoluto del script.
        // (Se setea desde el daemon; placeholder para portabilidad.)
        return root.auditorScriptPath;
    }

    property string auditorScriptPath: ""

    function start() {
        if (root.running) return;
        // Resolver script si no lo dieron absoluto.
        let cmd = [];
        if (root.auditorScriptPath === "") {
            cmd = root.commandModel;   // ya seteado completo
        } else {
            // Añadir el path del script al principio del comando base.
            cmd = [root.resolveHelperScript()].concat(root.auditorArgs);
        }
        if (cmd.length === 0) {
            root.status = "error: no command";
            return;
        }

        root.events = [];
        root.streamTexts = ({});
        root.streamRevision = 0;
        root.status = "starting";
        proc.command = cmd;
        proc.running = true;
        root.running = true;
        startTimer.restart();
    }

    function stop() {
        proc.running = false;
        root.running = false;
        root.status = "stopped";
        // No arrastrar el feed de la reunión anterior (evita que texto viejo
        // reaparezca en el panel si se vuelve a abrir).
        root.events = [];
        root.streamTexts = ({});
        root.streamRevision = 0;
    }

    function restart() {
        stop();
        start();
    }

    // Modo manual: inyectar un enunciado (si el helper no escucha transcript).
    function feedUtterance(speaker, text, ts) {
        root._handleLine(JSON.stringify({
            type: "enunciado",
            speaker: speaker,
            speaker_raw: speaker,
            text: text,
            ts: ts || ""
        }));
    }

    // Núcleo: parsear una línea JSONL emitida por el proceso.
    function _handleLine(line) {
        const s = (line || "").trim();
        if (s === "") return;
        let evt;
        try {
            evt = JSON.parse(s);
        } catch (e) {
            root.status = "error: bad json";
            return;
        }
        if (!evt || typeof evt !== "object") return;

        // Marcar running en la primera línea útil (proceso realmente vivo).
        if (root.status === "starting")
            root.status = "running";

        root.eventReceived(evt);
        if (root._handleSuggestStream(evt)) return;
        root._enqueue(evt);
    }

    function streamText(requestId) {
        // Leer streamRevision crea la dependencia del binding: el delegate se
        // repinta cuando llega otro lote, sin reemplazar todo el modelo.
        root.streamRevision;
        const text = root.streamTexts[requestId];
        return text ? text : "";
    }

    function _findStreamIndex(requestId) {
        if (!requestId) return -1;
        for (let i = 0; i < root.events.length; i++) {
            const evt = root.events[i];
            if (evt && evt.request_id === requestId && evt.type === "ai_streaming")
                return i;
        }
        return -1;
    }

    function _trimStreamEvents(events) {
        while (events.length > root.maxEvents)
            events.shift();
        return events;
    }

    function _replaceStreamAt(index, evt) {
        const events = root.events.slice();
        events[index] = evt;
        root.events = _trimStreamEvents(events);
    }

    function _upsertStreamPlaceholder(requestId, source) {
        const index = _findStreamIndex(requestId);
        const previous = index >= 0 ? root.events[index] : null;
        const previousSources = previous && previous.sources ? previous.sources : [];
        const placeholder = {
            type: "ai_streaming",
            kind: source.kind || (previous ? previous.kind : "ai_answer") || "ai_answer",
            speaker: source.speaker || (previous ? previous.speaker : "you") || "you",
            speaker_raw: source.speaker_raw || (previous ? previous.speaker_raw : "You") || "You",
            text: source.text || (previous ? previous.text : "") || "",
            answer: root.streamText(requestId),
            sources: (source.sources && source.sources.length) ? source.sources : previousSources,
            model: source.model || (previous ? previous.model : "") || "",
            request_id: requestId,
            streaming: true,
            ts: source.ts || (previous ? previous.ts : "") || ""
        };
        if (index >= 0) {
            _replaceStreamAt(index, placeholder);
        } else {
            root.events = _trimStreamEvents(root.events.concat([placeholder]));
        }
    }

    function _ensureStreamPlaceholder(requestId, source) {
        // Los deltas ya repintan mediante streamTexts/streamRevision. No
        // reemplazar el placeholder en cada lote: eso reconstruía el modelo y
        // provocaba saltos en la vista.
        if (_findStreamIndex(requestId) < 0)
            _upsertStreamPlaceholder(requestId, source);
    }

    function _finalizeStream(requestId, finalEvt) {
        finalEvt.request_id = requestId;
        finalEvt.streaming = false;
        const index = _findStreamIndex(requestId);
        if (index >= 0) {
            _replaceStreamAt(index, finalEvt);
        } else {
            root._enqueue(finalEvt);
        }
        if (root.streamTexts[requestId] !== undefined) {
            delete root.streamTexts[requestId];
            root.streamRevision++;
        }
    }

    function _failActiveStreams(message) {
        for (const requestId in root.streamTexts) {
            const partial = root.streamText(requestId);
            const evt = {
                type: "ai_error",
                speaker: "you",
                speaker_raw: "You",
                text: "",
                error: message,
                partial: partial,
                incomplete: true,
                request_id: requestId,
                ts: ""
            };
            root.eventReceived(evt);
            _finalizeStream(requestId, evt);
        }
    }

    function _handleSuggestStream(evt) {
        const requestId = evt ? evt.request_id : "";
        if (!requestId) return false;
        if (evt.type === "ai_stream_start") {
            root.streamTexts[requestId] = "";
            root.streamRevision++;
            _upsertStreamPlaceholder(requestId, evt);
            return true;
        }
        if (evt.type === "ai_stream_delta") {
            if (root.streamTexts[requestId] === undefined)
                root.streamTexts[requestId] = "";
            root.streamTexts[requestId] += evt.delta || "";
            root.streamRevision++;
            _ensureStreamPlaceholder(requestId, evt);
            return true;
        }
        if (evt.type === "ai_stream_done") {
            _finalizeStream(requestId, {
                type: evt.kind === "kb_hit" ? "kb_hit" : "ai_answer",
                speaker: "you",
                speaker_raw: "You",
                text: "",
                answer: evt.answer || root.streamText(requestId),
                sources: evt.sources || [],
                model: evt.model || "",
                ts: evt.ts || ""
            });
            return true;
        }
        if (evt.type === "ai_stream_error") {
            _finalizeStream(requestId, {
                type: "ai_error",
                speaker: "you",
                speaker_raw: "You",
                text: "",
                error: evt.error || "stream interrumpido",
                partial: evt.partial || root.streamText(requestId),
                incomplete: true,
                ts: evt.ts || ""
            });
            return true;
        }
        if ((evt.type === "ai_answer" || evt.type === "kb_hit" || evt.type === "ai_error")
                && _findStreamIndex(requestId) >= 0) {
            // Terminal sincrónica de fallback para una solicitud que ya mostró
            // placeholder: reemplazar en su lugar, no duplicar la respuesta.
            const index = _findStreamIndex(requestId);
            const terminal = {
                type: evt.type,
                speaker: evt.speaker || "you",
                speaker_raw: evt.speaker_raw || "You",
                text: evt.text || "",
                answer: evt.answer || root.streamText(requestId),
                sources: evt.sources || [],
                model: evt.model || "",
                error: evt.error || "",
                partial: root.streamText(requestId),
                request_id: requestId,
                ts: evt.ts || ""
            };
            _replaceStreamAt(index, terminal);
            if (root.streamTexts[requestId] !== undefined) {
                delete root.streamTexts[requestId];
                root.streamRevision++;
            }
            return true;
        }
        return false;
    }

    function _enqueue(evt) {
        // Los "info" del sistema (captura por frase, pw-record terminó, etc.)
        // ensucian el feed; solo pasan los relevantes al flujo ask/IA/errores.
        if (evt.type === "info" && !_isRelevantInfo(evt)) return;
        // Las métricas de debug solo entran al feed cuando el modo está ON.
        if (evt.type === "debug" && !root.debugMode) return;
        root.events = root.events.concat([evt]);
        if (root.events.length > root.maxEvents)
            root.events = root.events.slice(root.events.length - root.maxEvents);
    }

    // Info relevantes: estado de Sugerir/IA/errores y advertencias del motor
    // de transcripción. Todo lo demás (metadatos de captura) queda fuera.
    function _isRelevantInfo(evt) {
        if (!evt || evt.type !== "info" || !evt.msg) return false;
        return /Suger|Pregunt|Pensando|Aún no hay transcripción|No se detect|whisper-server no disponible|Motor whisper/i.test(String(evt.msg));
    }

    function _emitInfo(msg) {
        root.status = msg;
    }

    Component.onCompleted: {
        if (root.autoStart) start();
    }

    Timer {
        id: startTimer
        interval: 1500
        repeat: false
        onTriggered: { root.status = root.running ? "running" : "error"; }
    }
}