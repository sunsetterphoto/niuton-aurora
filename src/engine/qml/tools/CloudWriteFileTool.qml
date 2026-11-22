import QtQuick
import net.niuton.aurora.engine

CloudBoxTool {
    name: "write_file"
    permissionKey: "toolCloudWriteFile"
    definition: CloudBoxTexts.def("write_file", CloudBoxTexts.WRITE_FILE, CloudBoxTexts.WRITE_FILE_PARAMS)
    function describe(args) {
        return "Datei schreiben (Cloud-Rechner): " + _str(args.path) + "\n\n" + _str(args.content).substring(0, 300)
    }

    function _utf8Length(s) { return unescape(encodeURIComponent(s)).length }

    function execute(args, ctx, done) {
        var c = _client(ctx, done)
        if (!c) return
        var path = _str(args.path)
        if (path === "") { done("Fehler: path fehlt.", { "status": "error" }); return }
        var content = _str(args.content)
        if (content.length > 2000000) { done("Fehler: Inhalt zu groß (höchstens 2 MB je Aufruf).", { "status": "error" }); return }
        c.write(path, content, function(r) {
            if (!r.ok) { _fail(r.error, done); return }
            var shownPath = path.replace(/^\/+/, "").replace(/^work\//, "")
            done("Geschrieben: " + shownPath + " (" + _utf8Length(content) + " Bytes).", { "status": "ok" })
        })
    }
}
