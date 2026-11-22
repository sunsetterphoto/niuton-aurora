import QtQuick
import net.niuton.aurora.engine

CloudBoxTool {
    name: "read_file"
    permissionKey: "toolCloudReadFile"
    definition: CloudBoxTexts.def("read_file", CloudBoxTexts.READ_FILE, CloudBoxTexts.READ_FILE_PARAMS)
    function describe(args) { return "Datei lesen (Cloud-Rechner): " + _str(args.path) }

    function execute(args, ctx, done) {
        var c = _client(ctx, done)
        if (!c) return
        c.read(_str(args.path), function(r) {
            if (!r.ok) { _fail(r.error, done); return }
            if (r.binary) {
                done("(Binärdatei, " + r.size + " Bytes — nicht als Text lesbar)", { "status": "error" })
                return
            }
            var text = r.text || ""
            if (text.length > 20000) text = text.substring(0, 20000) + "\n…(gekürzt, " + r.text.length + " Zeichen)"
            done(text === "" ? "(leere Datei)" : text, { "status": "ok" })
        }, 2000000)
    }
}
