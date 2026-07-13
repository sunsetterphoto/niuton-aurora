import QtQuick
import net.niuton.aurora.engine

Tool {
    name: "run_command"
    category: "local"
    permissionKey: "toolRunCommand"
    minPermission: "confirm"          // harte Klammer
    property var _proc: null
    definition: ({
        "type": "function",
        "function": {
            "name": "run_command",
            "description": "Execute a bash command on the system. REQUIRES USER CONFIRMATION. Use when the user asks to run a command, install software, manage services, or perform system operations.",
            "parameters": {
                "type": "object",
                "properties": { "command": { "type": "string", "description": "The bash command to execute" } },
                "required": ["command"]
            }
        }
    })
    function describe(args) { return "Befehl ausführen:\n$ " + (args.command || "") }
    function execute(args, ctx, done) {
        var p = ctx.newProcess()
        p.timeoutMs = 30000
        p.mergeStderr = true          // stderr live in stdout falten (Parität zu main.qml-Fabrik)
        _proc = p
        p.finished.connect(function(code, out, err, trunc, timedOut) {
            _proc = null
            var text = out || ""
            // Unter mergeStderr ist err leer; der Fallback bleibt defensiv erhalten.
            if (err && err.length) text += (text.length ? "\n" : "") + err
            if (timedOut) text += "\n(abgebrochen: Zeitüberschreitung)"
            if (text.trim() === "") text = "(Keine Ausgabe)"
            done(text.substring(0, 5000), { exitCode: code, status: (timedOut || code !== 0) ? "error" : "ok" })
        })
        p.failed.connect(function(message) {
            _proc = null
            done("Fehler: " + message, { status: "error" })
        })
        // run_command ist bewusst beliebige Shell-Ausführung (hart hinter Freigabe)
        p.start("bash", ["-c", args.command || ""])
    }
    function abort() { if (_proc) _proc.terminate() }
}
