import QtQuick
import Quickshell
import Quickshell.Io

// AuditorThread — levanta el helper Python del auditor y publica sus eventos.
//
// Lanza `audit/auditor.py watch <transcript>` como proceso de streaming y usa
// un SplitParser (como el plugin dankSoftwareDepot) para consumir cada línea
// JSONL que el helper emite por stdout: {type: enunciado|kb_hit|ai_answer|
// ai_error|info, ...}. Las traduce a un signal QML y mantiene una cola `events`
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
        root._enqueue(evt);
    }

    function _enqueue(evt) {
        if (evt.type === "info") return;   // metadatos no entran a la cola visual
        root.events = root.events.concat([evt]);
        if (root.events.length > root.maxEvents)
            root.events = root.events.slice(root.events.length - root.maxEvents);
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