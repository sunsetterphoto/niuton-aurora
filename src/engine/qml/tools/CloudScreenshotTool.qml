import QtQuick
import net.niuton.aurora.engine

// Screenshot einer Seite mit Chromium im Cloud-Rechner; das PNG landet im
// Bildordner und erscheint wie ein erzeugtes Bild im Chat (ctx.appendImage).
CloudBoxTool {
    name: "screenshot"
    permissionKey: "toolCloudScreenshot"
    definition: CloudBoxTexts.def("screenshot", CloudBoxTexts.SCREENSHOT, CloudBoxTexts.SCREENSHOT_PARAMS)
    function describe(args) { return "Screenshot: " + _str(args.url) }

    function execute(args, ctx, done) {
        var url = _str(args.url).trim()
        if (!(url.indexOf("http://") === 0 || url.indexOf("https://") === 0 || url.indexOf("file:///work/") === 0)) {
            done("Fehler: url muss mit http://, https:// oder file:///work/ beginnen.", { "status": "error" })
            return
        }
        var c = _client(ctx, done)
        if (!c) return
        var dir = String((ctx && ctx.imagesDir) || "").replace(/\/+$/, "")
        if (dir === "") { done("Fehler: kein Bildordner verfügbar.", { "status": "error" }); return }
        var dest = dir + "/cloud-screenshot-" + Date.now() + ".png"
        c.screenshot(url, dest, function(r) {
            if (!r.ok) { _fail(r.error, done); return }
            if (ctx.appendImage) ctx.appendImage(r.path || dest, "Screenshot: " + url)
            done("Screenshot von " + url + " erstellt und im Chat gezeigt.", { "status": "ok" })
        })
    }
}
