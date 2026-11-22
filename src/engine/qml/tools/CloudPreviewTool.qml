import QtQuick
import net.niuton.aurora.engine

// Vorschau einer Web-App im Cloud-Rechner: anmelden (PUT …/previews/{app}),
// warten bis das Zertifikat da ist (tlsReady; höchstens waitLimitMs), dann eine
// einmalige Adresse holen (…/open, 60 s gültig, an das Netz dieses Rechners
// gebunden) und sie im Standard-Browser öffnen. Ohne Browser-Funktion im
// Kontext (z. B. Routine im Hintergrund) bekommt das Modell nur die Adresse.
CloudBoxTool {
    id: tool
    name: "preview"
    permissionKey: "toolCloudPreview"
    property int pollIntervalMs: 5000
    property int waitLimitMs: 120000

    property int _run: 0                 // Lauf-Token: späte Antworten nach abort() verwerfen
    property var _next: null
    property Timer _timer: Timer {
        repeat: false
        onTriggered: { var f = tool._next; tool._next = null; if (f) f() }
    }

    definition: CloudBoxTexts.def("preview", CloudBoxTexts.preview(""), CloudBoxTexts.PREVIEW_PARAMS)
    function definitionFor(ctx) {
        return CloudBoxTexts.def("preview", CloudBoxTexts.preview(_domain(ctx)), CloudBoxTexts.PREVIEW_PARAMS)
    }
    function describe(args) { return "Vorschau zeigen: Port " + _str(args.port) }

    function _later(ms, run, f) {
        _next = function() { if (run === tool._run) f() }
        _timer.interval = Math.max(1, ms)
        _timer.restart()
    }

    function execute(args, ctx, done) {
        var port = parseInt(args.port)
        if (!(port >= 1024 && port <= 65535)) { done("Fehler: port muss 1024–65535 sein.", { "status": "error" }); return }
        var c = _client(ctx, done)
        if (!c) return
        var run = ++tool._run
        var deadline = Date.now() + tool.waitLimitMs
        c.preview(port, _str(args.name), function(r) {
            if (run !== tool._run) return
            if (!r.ok) { _fail(r.error, done); return }
            var p = r.preview
            var info = "Vorschau angemeldet: " + p.url + " (Port " + port + "). "
            if (!ctx.openUrl) {
                done(info + "Die Adresse ist privat (Anmeldung beim Aurora-Server nötig)."
                     + (p.tlsReady ? "" : " Das Zertifikat ist in etwa einer Minute bereit."), { "status": "ok" })
                return
            }
            var pending = function() {
                done(info + "Das Zertifikat der Adresse ist noch nicht fertig; der Browser wurde deshalb nicht geöffnet. "
                     + "Sag dem Nutzer, dass die Vorschau in etwa einer Minute bereit ist; rufe preview dann erneut auf "
                     + "(gleicher Name = gleiche Adresse). Den Server nicht neu starten.", { "status": "ok" })
            }
            var open = function() {
                c.openPreview(p.name, function(o) {
                    if (run !== tool._run) return
                    if (o.ok) {
                        ctx.openUrl(o.url)
                        done(info + "Sie wurde im Browser des Nutzers geöffnet. Läuft der Server nicht, zeigt die Seite einen Fehler.",
                             { "status": "ok" })
                    } else if (o.error && o.error.code === "preview_not_ready" && Date.now() < deadline) {
                        var wait = (o.error.retryAfterS !== undefined) ? o.error.retryAfterS * 1000 : tool.pollIntervalMs
                        tool._later(Math.min(wait, tool.pollIntervalMs), run, open)
                    } else if (o.error && o.error.code === "preview_not_ready") {
                        pending()
                    } else {
                        _fail(o.error, done)
                    }
                })
            }
            var poll = function() {
                if (Date.now() >= deadline) { pending(); return }
                c.previews(function(l) {
                    if (run !== tool._run) return
                    if (!l.ok) { _fail(l.error, done); return }
                    var list = l.previews || []
                    for (var i = 0; i < list.length; i++)
                        if (list[i].name === p.name && list[i].tlsReady) { open(); return }
                    tool._later(tool.pollIntervalMs, run, poll)
                })
            }
            if (p.tlsReady) open()
            else tool._later(tool.pollIntervalMs, run, poll)
        })
    }

    function abort() {
        _run++
        _next = null
        _timer.stop()
    }
}
