import QtQuick
import net.niuton.aurora.engine

// run_command im Cloud-Rechner: Ausgabe kommt als Strom (exec, SSE); behalten
// wird das Ende (Server kürzt ebenfalls). Rechte: Vorgabe auto, der Rechner ist
// isoliert — die harte confirm-Klammer gilt nur für die lokale Fassung.
CloudBoxTool {
    id: tool
    name: "run_command"
    permissionKey: "toolCloudRunCommand"
    property var _handle: null

    definition: CloudBoxTexts.def("run_command", CloudBoxTexts.runCommand(""), CloudBoxTexts.RUN_COMMAND_PARAMS)
    function definitionFor(ctx) {
        return CloudBoxTexts.def("run_command", CloudBoxTexts.runCommand(_domain(ctx)), CloudBoxTexts.RUN_COMMAND_PARAMS)
    }
    function describe(args) { return "Befehl im Cloud-Rechner:\n$ " + _str(args.cmd || args.command) }

    function execute(args, ctx, done) {
        var c = _client(ctx, done)
        if (!c) return
        var cmd = _str(args.cmd || args.command)
        if (cmd.trim() === "") { done("Fehler: cmd fehlt.", { "status": "error" }); return }
        var t = parseInt(args.timeout_s)
        t = (t > 0) ? Math.min(900, t) : 120
        var out = ""
        var shown = function() {
            var s = out.length > 8000 ? "…(gekürzt)\n" + out.substring(out.length - 8000) : out
            return s.trim() === "" ? "(Keine Ausgabe)" : s
        }
        tool._handle = c.exec(cmd, { "cwd": args.cwd || "", "timeoutS": t }, {
            "onOut": function(stream, data) {
                out += data
                if (out.length > 64000) out = out.substring(out.length - 32000)
            },
            "onEnd": function(e) {
                tool._handle = null
                var head = e.timedOut ? "Zeitüberschreitung (Befehl beendet)."
                         : (e.exitCode === null ? "Befehl abgebrochen." : "Exit-Code " + e.exitCode + ".")
                done(head + "\n" + shown(), { "exitCode": e.exitCode,
                     "status": (e.exitCode === 0 && !e.timedOut) ? "ok" : "error" })
            },
            "onError": function(e) {
                tool._handle = null
                done(CloudBoxTexts.errorText(e) + (out !== "" ? "\nBisherige Ausgabe:\n" + shown() : ""),
                     { "status": "error" })
            }
        })
    }

    function abort() { if (_handle) { _handle.abort(); _handle = null } }
}
