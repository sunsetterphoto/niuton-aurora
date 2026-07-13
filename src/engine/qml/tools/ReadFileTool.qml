import QtQuick
import net.niuton.aurora.engine

Tool {
    name: "read_file"
    category: "local"
    permissionKey: "toolReadFile"
    definition: ({
        "type": "function",
        "function": {
            "name": "read_file",
            "description": "Read the contents of a file from the filesystem. Use when the user asks about file contents, config files, logs, or wants you to analyze a file.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": { "type": "string", "description": "Absolute path to the file" }
                },
                "required": ["path"]
            }
        }
    })
    function describe(args) { return "Datei lesen: " + (args.path || "") }
    function execute(args, ctx, done) {
        var rf = ctx.fileio.readText(args.path, 32768)
        var text = rf.ok ? rf.text : ("Fehler: " + rf.error)
        done(text.substring(0, 5000), { status: rf.ok ? "ok" : "error" })
    }
}
