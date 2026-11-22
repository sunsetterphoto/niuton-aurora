import QtQuick
import QtTest
import net.niuton.aurora.engine

// Cloud-Rechner-Werkzeuge und die Umschaltung „Befehle und Dateien: dieser
// Rechner / Cloud-Rechner" je Werkzeugname. Kernforderung: Ist der
// Cloud-Rechner gewählt, startet NIE ein lokaler Prozess und keine lokale
// Datei-Operation — auch nicht als Rückfall bei Fehlern.
Item {
    QtObject {
        id: settingsMock
        property string sandboxTarget: "device"
        property bool cloudSelected: sandboxTarget === "cloud"
        property string toolWebSearch: "auto"
        property string toolReadFile: "auto"
        property string toolListDir: "auto"
        property string toolWebFetch: "auto"
        property string toolWriteFile: "confirm"
        property string toolRunCommand: "confirm"
        property string toolManageRoutines: "auto"
        property string toolCloudRunCommand: "auto"
        property string toolCloudReadFile: "auto"
        property string toolCloudWriteFile: "auto"
        property string toolCloudListDir: "auto"
        property string toolCloudPreview: "auto"
        property string toolCloudScreenshot: "auto"
    }

    ToolRegistry { id: reg; settings: settingsMock }

    // Attrappe des CloudBoxClient: zeichnet Aufrufe auf, Test antwortet von Hand
    QtObject {
        id: box
        property string previewDomain: ""
        property var calls: []
        property var execHandlers: null
        property bool execAborted: false
        function _rec(name, a, cb) { calls.push({ "name": name, "args": a, "cb": cb }) }
        function last() { return calls[calls.length - 1] }
        function answer(r) { calls[calls.length - 1].cb(r) }
        function exec(cmd, opts, handlers) {
            _rec("exec", { "cmd": cmd, "opts": opts }, null)
            execHandlers = handlers
            return { "abort": function() { box.execAborted = true } }
        }
        function read(path, cb, maxBytes) { _rec("read", { "path": path, "maxBytes": maxBytes }, cb) }
        function write(path, content, cb) { _rec("write", { "path": path, "content": content }, cb) }
        function list(path, cb) { _rec("list", { "path": path }, cb) }
        function preview(port, name, cb) { _rec("preview", { "port": port, "name": name }, cb) }
        function previews(cb) { _rec("previews", {}, cb) }
        function openPreview(name, cb) { _rec("openPreview", { "name": name }, cb) }
        function screenshot(url, dest, cb) { _rec("screenshot", { "url": url, "dest": dest }, cb) }
    }

    property int processCount: 0
    property int fileioCount: 0
    property var opened: []
    property var images: []

    function makeCtx(withBox) {
        return {
            "settings": settingsMock,
            "cloudBox": withBox === false ? null : box,
            "imagesDir": "/tmp/aurora-images",
            "openUrl": function(u) { opened.push(u) },
            "appendImage": function(p, label) { images.push({ "path": p, "label": label }) },
            "newProcess": function() { processCount++; return null },
            "fileio": {
                "readText": function() { fileioCount++; return { "ok": true, "text": "LOKAL" } },
                "writeText": function() { fileioCount++; return { "ok": true } },
                "listDir": function() { fileioCount++; return { "ok": true, "entries": [] } }
            }
        }
    }

    function names(defs) {
        var out = []
        for (var i = 0; i < defs.length; i++) out.push(defs[i]["function"].name)
        return out.sort()
    }
    function defOf(defs, name) {
        for (var i = 0; i < defs.length; i++) if (defs[i]["function"].name === name) return defs[i]["function"]
        return null
    }

    CloudPreviewTool { id: previewTool; pollIntervalMs: 20; waitLimitMs: 300 }

    TestCase {
        name: "CloudTools"

        function init() {
            settingsMock.sandboxTarget = "device"
            settingsMock.toolCloudRunCommand = "auto"
            box.calls = []
            box.previewDomain = ""
            box.execHandlers = null
            box.execAborted = false
            processCount = 0
            fileioCount = 0
            opened = []
            images = []
        }

        // ---------- Umschaltung ----------

        function test_ohneCloudBleibtAllesWieBisher() {
            var n = names(reg.definitions(makeCtx()))
            verify(n.indexOf("list_directory") >= 0)
            verify(n.indexOf("run_command") >= 0)
            verify(n.indexOf("preview") < 0)
            verify(n.indexOf("screenshot") < 0)
            verify(n.indexOf("list_dir") < 0)
            compare(reg.permissionFor("run_command"), "confirm")   // lokale harte Klammer
            compare(reg.categoryOf("run_command"), "local")
            verify(defOf(reg.definitions(makeCtx()), "run_command").description.indexOf("/work") < 0)
        }

        function test_cloudModusTauschtJeWerkzeugname() {
            settingsMock.sandboxTarget = "cloud"
            var defs = reg.definitions(makeCtx())
            compare(names(defs), ["list_dir", "manage_routines", "preview", "read_file",
                                  "run_command", "screenshot", "web_fetch", "web_search", "write_file"])
            // genau EIN run_command, und zwar das des Cloud-Rechners
            compare(defs.filter(function(d) { return d["function"].name === "run_command" }).length, 1)
            var rc = defOf(defs, "run_command")
            verify(rc.description.indexOf("/work") >= 0)
            verify(rc.description.indexOf("0.0.0.0") >= 0)
            compare(rc.parameters.required, ["cmd"])
            compare(reg.permissionFor("run_command"), "auto")       // Cloud-Vorgabe
            compare(reg.categoryOf("run_command"), "box")
            compare(reg.toolByName("list_directory"), null)
            verify(reg.promptSection(makeCtx()).indexOf("preview(port, name)") >= 0)
        }

        function test_cloudRechteKonfigurierbar() {
            settingsMock.sandboxTarget = "cloud"
            settingsMock.toolCloudRunCommand = "confirm"
            compare(reg.permissionFor("run_command"), "confirm")
            settingsMock.toolCloudRunCommand = "off"
            verify(names(reg.definitions(makeCtx())).indexOf("run_command") < 0)
        }

        function test_vorschauDomainInDenBeschreibungen() {
            settingsMock.sandboxTarget = "cloud"
            box.previewDomain = "preview.aurora.example"
            var defs = reg.definitions(makeCtx())
            verify(defOf(defs, "run_command").description.indexOf("['.preview.aurora.example']") >= 0)
            verify(defOf(defs, "preview").description.indexOf("*.preview.aurora.example") >= 0)
        }

        // ---------- kein lokaler Prozess, keine lokale Datei ----------

        function test_cloudRunCommandStartetKeinenLokalenProzess() {
            settingsMock.sandboxTarget = "cloud"
            var out = null, extra = null
            reg.execute("run_command", { "cmd": "npm test", "cwd": "app", "timeout_s": 60 }, makeCtx(),
                        function(t, e) { out = t; extra = e })
            compare(processCount, 0)
            compare(box.last().name, "exec")
            compare(box.last().args.cmd, "npm test")
            compare(box.last().args.opts.cwd, "app")
            compare(box.last().args.opts.timeoutS, 60)
            box.execHandlers.onOut("stdout", "ok 1\n")
            box.execHandlers.onOut("stderr", "warn\n")
            box.execHandlers.onEnd({ "exitCode": 0, "timedOut": false, "truncated": false })
            verify(out.indexOf("Exit-Code 0.") === 0)
            verify(out.indexOf("ok 1\nwarn\n") >= 0)
            compare(extra.status, "ok")
            compare(processCount, 0)
        }

        function test_cloudDateiwerkzeugeOhneLokaleDateien() {
            settingsMock.sandboxTarget = "cloud"
            var ctx = makeCtx()
            var out = null
            reg.execute("read_file", { "path": "a.txt" }, ctx, function(t) { out = t })
            box.answer({ "ok": true, "text": "INHALT", "binary": false, "size": 6 })
            compare(out, "INHALT")
            reg.execute("write_file", { "path": "b.txt", "content": "hä" }, ctx, function(t) { out = t })
            compare(box.last().args.content, "hä")
            box.answer({ "ok": true })
            compare(out, "Geschrieben: b.txt (3 Bytes).")
            reg.execute("list_dir", { "path": "" }, ctx, function(t) { out = t })
            box.answer({ "ok": true, "path": "", "entries": [
                { "name": "src", "type": "dir", "size": 0 }, { "name": "a.txt", "type": "file", "size": 6 }] })
            compare(out, "src/\na.txt  (6 B)")
            compare(fileioCount, 0)
            compare(processCount, 0)
        }

        // Fehler (Schlüssel widerrufen) -> klare Meldung, KEIN Rückfall auf lokal
        function test_cloudFehlerOhneRueckfall() {
            settingsMock.sandboxTarget = "cloud"
            var out = null, extra = null
            reg.execute("run_command", { "cmd": "ls" }, makeCtx(), function(t, e) { out = t; extra = e })
            box.execHandlers.onError({ "status": 401, "code": "unauthorized", "message": "x" })
            verify(out.indexOf("Geräte-Schlüssel") >= 0)
            compare(extra.status, "error")
            reg.execute("read_file", { "path": "a" }, makeCtx(), function(t, e) { out = t; extra = e })
            box.answer({ "ok": false, "error": { "status": 423, "code": "box_blocked", "message": "x" } })
            verify(out.indexOf("gesperrt") >= 0)
            compare(fileioCount, 0)
            compare(processCount, 0)
        }

        function test_cloudOhneEinrichtungKeinRueckfall() {
            settingsMock.sandboxTarget = "cloud"
            var texts = []
            var ctx = makeCtx(false)
            reg.execute("run_command", { "cmd": "ls" }, ctx, function(t) { texts.push(t) })
            reg.execute("read_file", { "path": "a" }, ctx, function(t) { texts.push(t) })
            reg.execute("write_file", { "path": "a", "content": "x" }, ctx, function(t) { texts.push(t) })
            reg.execute("list_dir", {}, ctx, function(t) { texts.push(t) })
            compare(texts.length, 4)
            for (var i = 0; i < texts.length; i++) verify(texts[i].indexOf("nicht eingerichtet") >= 0)
            compare(processCount, 0)
            compare(fileioCount, 0)
        }

        function test_runCommandAusgabeWirdGekuerzt() {
            settingsMock.sandboxTarget = "cloud"
            var out = null
            reg.execute("run_command", { "cmd": "x" }, makeCtx(), function(t) { out = t })
            var big = ""
            for (var i = 0; i < 1000; i++) big += "zeile " + i + " ............\n"
            box.execHandlers.onOut("stdout", big)
            box.execHandlers.onEnd({ "exitCode": 2, "timedOut": false, "truncated": false })
            verify(out.indexOf("Exit-Code 2.") === 0)
            verify(out.indexOf("…(gekürzt)") >= 0)
            verify(out.indexOf("zeile 999") >= 0)
            verify(out.length < 8200)
        }

        function test_runCommandZeitueberschreitungUndAbbruch() {
            settingsMock.sandboxTarget = "cloud"
            var out = null, extra = null
            reg.execute("run_command", { "cmd": "sleep 999" }, makeCtx(), function(t, e) { out = t; extra = e })
            box.execHandlers.onEnd({ "exitCode": null, "timedOut": true, "truncated": false })
            verify(out.indexOf("Zeitüberschreitung") === 0)
            compare(extra.status, "error")
            reg.execute("run_command", { "cmd": "sleep 999" }, makeCtx(), function() {})
            reg.abortRunning()
            verify(box.execAborted)
        }

        function test_readFileBinaerUndKappe() {
            settingsMock.sandboxTarget = "cloud"
            var out = null, extra = null
            reg.execute("read_file", { "path": "bild.png" }, makeCtx(), function(t, e) { out = t; extra = e })
            compare(box.last().args.maxBytes, 2000000)
            box.answer({ "ok": true, "text": "", "binary": true, "size": 1234 })
            verify(out.indexOf("Binärdatei, 1234 Bytes") >= 0)
            compare(extra.status, "error")
        }

        // ---------- Screenshot ----------

        function test_screenshotErscheintAlsBild() {
            settingsMock.sandboxTarget = "cloud"
            var out = null
            reg.execute("screenshot", { "url": "http://localhost:5173/" }, makeCtx(), function(t) { out = t })
            compare(box.last().name, "screenshot")
            verify(box.last().args.dest.indexOf("/tmp/aurora-images/cloud-screenshot-") === 0)
            box.answer({ "ok": true, "path": box.last().args.dest })
            compare(images.length, 1)
            compare(images[0].label, "Screenshot: http://localhost:5173/")
            verify(out.indexOf("im Chat gezeigt") >= 0)
        }

        function test_screenshotPrueftUrl() {
            settingsMock.sandboxTarget = "cloud"
            var out = null
            reg.execute("screenshot", { "url": "ftp://x" }, makeCtx(), function(t) { out = t })
            compare(box.calls.length, 0)
            verify(out.indexOf("file:///work/") >= 0)
        }

        // ---------- Vorschau: anmelden, auf Zertifikat warten, im Browser öffnen ----------

        function test_vorschauSofortBereit() {
            var out = null
            previewTool.execute({ "port": 5173 }, makeCtx(), function(t) { out = t })
            compare(box.last().name, "preview")
            compare(box.last().args.port, 5173)
            box.answer({ "ok": true, "preview": { "name": "app-1a2b3c", "url": "https://app-1a2b3c.example",
                                                  "port": 5173, "tlsReady": true } })
            compare(box.last().name, "openPreview")
            compare(box.last().args.name, "app-1a2b3c")
            box.answer({ "ok": true, "url": "https://einmal.example/t" })
            compare(opened, ["https://einmal.example/t"])
            verify(out.indexOf("https://app-1a2b3c.example") >= 0)
            verify(out.indexOf("Browser") >= 0)
        }

        function test_vorschauWartetAufZertifikat() {
            var out = null
            previewTool.execute({ "port": 3000, "name": "shop" }, makeCtx(), function(t) { out = t })
            compare(box.last().args.name, "shop")
            box.answer({ "ok": true, "preview": { "name": "shop-abcdef", "url": "https://shop-abcdef.example",
                                                  "port": 3000, "tlsReady": false } })
            tryVerify(function() { return box.last().name === "previews" }, 1000)
            box.answer({ "ok": true, "previews": [{ "name": "shop-abcdef", "tlsReady": false }] })
            tryVerify(function() { return box.calls.length === 3 }, 1000)
            compare(box.last().name, "previews")
            box.answer({ "ok": true, "previews": [{ "name": "shop-abcdef", "tlsReady": true }] })
            compare(box.last().name, "openPreview")
            // Zertifikat gemeldet, open aber noch 409 -> nach retryAfterS erneut
            box.answer({ "ok": false, "error": { "status": 409, "code": "preview_not_ready", "retryAfterS": 0 } })
            tryVerify(function() { return box.calls.length === 5 }, 1000)
            compare(box.last().name, "openPreview")
            box.answer({ "ok": true, "url": "https://einmal.example/s" })
            compare(opened, ["https://einmal.example/s"])
            verify(out !== null)
        }

        function test_vorschauGibtNachWartezeitAuf() {
            var out = null
            previewTool.execute({ "port": 3000 }, makeCtx(), function(t) { out = t })
            box.answer({ "ok": true, "preview": { "name": "app-1", "url": "https://app-1.example",
                                                  "port": 3000, "tlsReady": false } })
            // jede Abfrage: noch nicht bereit
            tryVerify(function() {
                if (out !== null) return true
                var c = box.last()
                if (c.name === "previews" && !c.done) { c.done = true; c.cb({ "ok": true, "previews": [] }) }
                return false
            }, 3000)
            compare(opened.length, 0)
            verify(out.indexOf("https://app-1.example") >= 0)
            verify(out.indexOf("Zertifikat") >= 0)
        }

        function test_vorschauOhneBrowserGibtAdresseZurueck() {
            var out = null
            var ctx = makeCtx()
            ctx.openUrl = null
            previewTool.execute({ "port": 8080 }, ctx, function(t) { out = t })
            box.answer({ "ok": true, "preview": { "name": "app-2", "url": "https://app-2.example",
                                                  "port": 8080, "tlsReady": true } })
            compare(box.calls.length, 1)            // kein open ohne Browser
            verify(out.indexOf("https://app-2.example") >= 0)
        }

        function test_vorschauPortPruefung() {
            var out = null
            previewTool.execute({ "port": 80 }, makeCtx(), function(t) { out = t })
            compare(box.calls.length, 0)
            verify(out.indexOf("1024") >= 0)
        }

        function test_vorschauAbbruch() {
            var out = null
            previewTool.execute({ "port": 3000 }, makeCtx(), function(t) { out = t })
            box.answer({ "ok": true, "preview": { "name": "app-3", "url": "u", "port": 3000, "tlsReady": false } })
            previewTool.abort()
            wait(100)
            compare(box.calls.length, 1)            // keine weiteren Abfragen
        }
    }
}
