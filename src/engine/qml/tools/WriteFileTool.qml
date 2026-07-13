import QtQuick
import net.niuton.aurora.engine

Tool {
    name: "write_file"
    category: "local"
    permissionKey: "toolWriteFile"
    minPermission: "confirm"          // harte Klammer: nie auto
    definition: ({
        "type": "function",
        "function": {
            "name": "write_file",
            "description": "Write content to a file. REQUIRES USER CONFIRMATION. Use when the user explicitly asks to create or modify a file.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": { "type": "string", "description": "Absolute path to the file" },
                    "content": { "type": "string", "description": "The content to write" }
                },
                "required": ["path", "content"]
            }
        }
    })
    function describe(args) {
        return "Datei schreiben: " + (args.path || "") + "\n\n"
             + (args.content || "").substring(0, 300)
    }
    function execute(args, ctx, done) {
        var wr = ctx.fileio.writeText(args.path, args.content || "")
        if (wr.ok) done("OK: Datei geschrieben", { status: "ok" })
        else done("FEHLER: " + wr.error, { status: "error" })
    }
}
