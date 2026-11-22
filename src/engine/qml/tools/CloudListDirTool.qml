import QtQuick
import net.niuton.aurora.engine

// list_dir des Cloud-Rechners (lokal heißt das Werkzeug list_directory und
// ist im Modus „Cloud-Rechner" ausgeblendet).
CloudBoxTool {
    name: "list_dir"
    permissionKey: "toolCloudListDir"
    definition: CloudBoxTexts.def("list_dir", CloudBoxTexts.LIST_DIR, CloudBoxTexts.LIST_DIR_PARAMS)
    function describe(args) { return "Ordner anzeigen: /work/" + _str(args.path) }

    function execute(args, ctx, done) {
        var c = _client(ctx, done)
        if (!c) return
        var path = _str(args.path)
        c.list(path, function(r) {
            if (!r.ok) { _fail(r.error, done); return }
            var entries = r.entries || []
            if (entries.length === 0) { done("(/work/" + path + " ist leer)", { "status": "ok" }); return }
            var lines = []
            for (var i = 0; i < entries.length && i < 500; i++) {
                var e = entries[i]
                lines.push(e.type === "dir" ? e.name + "/" : e.name + "  (" + (e.size || 0) + " B)")
            }
            if (entries.length > 500) lines.push("…(" + (entries.length - 500) + " weitere)")
            done(lines.join("\n"), { "status": "ok" })
        })
    }
}
