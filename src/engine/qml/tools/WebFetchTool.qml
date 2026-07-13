import QtQuick
import net.niuton.aurora.engine

Tool {
    name: "web_fetch"
    category: "network"
    permissionKey: "toolWebFetch"
    property var _proc: null
    definition: ({
        "type": "function",
        "function": {
            "name": "web_fetch",
            "description": "Fetch and read the content of a web page URL. Use when the user provides a specific URL to read, or when you need to read a web page for detailed information.",
            "parameters": {
                "type": "object",
                "properties": { "url": { "type": "string", "description": "The URL to fetch" } },
                "required": ["url"]
            }
        }
    })
    function describe(args) { return "URL abrufen: " + (args.url || "") }
    function execute(args, ctx, done) {
        var p = ctx.newProcess()
        p.timeoutMs = 15000
        p.mergeStderr = true          // stderr live in stdout falten (Parität zu main.qml-Fabrik)
        _proc = p
        // url als eigenes Argument -> keine Shell-Injection
        p.finished.connect(function(code, out, err, trunc, timedOut) {
            _proc = null
            var text = out || ""
            if (timedOut) text += "\n(abgebrochen: Zeitüberschreitung)"
            if (text.trim() === "") text = "(Keine Ausgabe)"
            done(text.substring(0, 5000), { exitCode: code, status: (timedOut || code !== 0) ? "error" : "ok" })
        })
        p.failed.connect(function(message) {
            _proc = null
            done("Fehler: " + message, { status: "error" })
        })
        p.start("curl", ["-sL", "--max-time", "10", args.url || ""])
    }
    function abort() { if (_proc) _proc.terminate() }
}
