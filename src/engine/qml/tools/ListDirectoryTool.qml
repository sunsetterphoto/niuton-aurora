import QtQuick
import net.niuton.aurora.engine

Tool {
    name: "list_directory"
    category: "local"
    permissionKey: "toolListDir"
    definition: ({
        "type": "function",
        "function": {
            "name": "list_directory",
            "description": "List files and directories at a given path. Use when the user asks what files exist, wants to explore directories, or needs to find files.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": { "type": "string", "description": "Absolute path to the directory, defaults to home directory" },
                    "show_hidden": { "type": "boolean", "description": "Whether to show hidden files (dotfiles)" }
                },
                "required": ["path"]
            }
        }
    })
    function describe(args) { return "Verzeichnis: " + (args.path || "") }
    function execute(args, ctx, done) {
        var ld = ctx.fileio.listDir(args.path, args.show_hidden !== false)
        if (!ld.ok) { done("Fehler: " + ld.error, { status: "error" }); return }
        var lines = []
        for (var i = 0; i < ld.entries.length; i++) {
            var e = ld.entries[i]
            lines.push((e.isDir ? "d " : "- ") + e.name
                       + (e.isDir ? "/" : " (" + e.size + " B)"))
        }
        done((lines.length ? lines.join("\n") : "(leer)").substring(0, 5000))
    }
}
