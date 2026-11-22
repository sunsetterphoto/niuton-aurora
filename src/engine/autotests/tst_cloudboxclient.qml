import QtQuick
import QtTest
import net.niuton.aurora.engine
import "../qml/CloudBoxTexts.js" as CloudBoxTexts

// CloudBoxClient: App-API des Aurora-Servers (Cloud-Rechner), API.md §15.
// Mock-Muster wie tst_videoclient: Http.request und der SSE-Strom werden
// aufgezeichnet und von Hand beantwortet. Gegen den echten Test-HTTP-Server
// läuft zusätzlich tst_cloudboxclient_http (C++-Harness).
Item {
    QtObject {
        id: mockHttp
        property var calls: []
        function request(opts, cb) { calls.push({ "opts": opts, "cb": cb }) }
        function answer(result) { calls[calls.length - 1].cb(result) }
        function last() { return calls[calls.length - 1].opts }
    }

    QtObject {
        id: mockKeyring
        property var reads: []
        property string secret: "nk_test"
        function readSecret(keyRef, cb) {
            reads.push(keyRef)
            cb({ "ok": true, "secret": mockKeyring.secret })
        }
    }

    // Strom-Attrappe mit der Signal-Fläche von NdjsonStream
    property var streams: []
    Component {
        id: streamComp
        QtObject {
            property bool sse: false
            property int idleTimeoutMs: 0
            property string url: ""
            property var body: null
            property var headers: null
            property bool aborted: false
            signal objectReceived(var obj)
            signal finished(bool ok, int status, string error)
            function post(u, b, h) { url = u; body = b; headers = h }
            function abort() { aborted = true }
            Component.onCompleted: streams.push(this)
        }
    }

    CloudBoxClient {
        id: client
        endpoint: "https://aurora.example/"
        http: mockHttp
        keyring: mockKeyring
        streamFactory: streamComp
    }

    TestCase {
        name: "CloudBoxClient"

        function init() {
            client.endpoint = "https://aurora.example/"
            client.resetKey()
            client.previewDomain = ""
            mockHttp.calls = []
            mockKeyring.reads = []
            mockKeyring.secret = "nk_test"
            streams = []
        }

        // ---------- Grundlagen ----------

        function test_basisOhneSchraegstrichUndMitApiV1() {
            compare(client.base, "https://aurora.example/api/v1")
            client.endpoint = "  https://aurora.example  "
            compare(client.base, "https://aurora.example/api/v1")
        }

        function test_meSendetBearerUndLiefertKonto() {
            var out = null
            client.me(function(r) { out = r })
            compare(mockKeyring.reads, ["cloudbox"])
            var o = mockHttp.last()
            compare(o.method, "GET")
            compare(o.url, "https://aurora.example/api/v1/me")
            compare(o.headers["Authorization"], "Bearer nk_test")
            mockHttp.answer({ "ok": true, "status": 200, "data": {
                "username": "anna", "displayName": "Anna", "tier": "normal",
                "features": { "box": true }, "device": { "id": "d1", "name": "Laptop" },
                "previewDomain": "preview.aurora.example" } })
            verify(out.ok)
            compare(out.me.username, "anna")
            compare(out.me.displayName, "Anna")
            compare(out.me.tier, "normal")
            compare(out.me.box, true)
            compare(out.me.deviceName, "Laptop")
            compare(client.previewDomain, "preview.aurora.example")
        }

        // „Verbindung prüfen" vor dem Speichern: Adresse und Schlüssel aus den Feldern
        function test_meMitUebersteuerung() {
            client.me(function(r) {}, { "endpoint": "https://other.example", "key": "nk_feld" })
            compare(mockKeyring.reads.length, 0)
            compare(mockHttp.last().url, "https://other.example/api/v1/me")
            compare(mockHttp.last().headers["Authorization"], "Bearer nk_feld")
        }

        function test_schluesselWirdGecacht() {
            client.status(function() {})
            client.status(function() {})
            compare(mockKeyring.reads.length, 1)
        }

        function test_ohneSchluessel_keinAufruf() {
            mockKeyring.secret = ""
            var out = null
            client.status(function(r) { out = r })
            compare(mockHttp.calls.length, 0)
            verify(!out.ok)
            compare(out.error.code, "no_key")
        }

        function test_ohneAdresse_nichtEingerichtet() {
            client.endpoint = ""
            var out = null
            client.list("", function(r) { out = r })
            compare(mockHttp.calls.length, 0)
            compare(out.error.code, "not_configured")
        }

        function test_ungueltigeAdresse() {
            var out = null
            client.me(function(r) { out = r }, { "endpoint": "aurora.example", "key": "nk_x" })
            compare(mockHttp.calls.length, 0)
            compare(out.error.code, "invalid_endpoint")
        }

        // ---------- Fehlerform ----------

        function test_401_ungueltigUndCacheGeleert() {
            var out = null
            client.status(function(r) { out = r })
            mockHttp.answer({ "ok": false, "status": 401, "error": "HTTP 401",
                              "data": { "error": { "code": "unauthorized", "message": "Schlüssel ungültig" } } })
            verify(!out.ok)
            compare(out.error.status, 401)
            compare(out.error.code, "unauthorized")
            // nächster Aufruf liest den Schlüssel neu (evtl. inzwischen ersetzt)
            client.status(function() {})
            compare(mockKeyring.reads.length, 2)
        }

        function test_423_gesperrt() {
            var out = null
            client.list("", function(r) { out = r })
            mockHttp.answer({ "ok": false, "status": 423, "error": "HTTP 423",
                              "data": { "error": { "code": "box_blocked", "message": "gesperrt" } } })
            compare(out.error.code, "box_blocked")
            verify(CloudBoxTexts.errorText(out.error).indexOf("gesperrt") >= 0)
        }

        function test_429_mitRetryAfter() {
            var out = null
            client.list("", function(r) { out = r })
            mockHttp.answer({ "ok": false, "status": 429, "error": "HTTP 429",
                              "data": { "error": { "code": "too_many_requests", "message": "x", "retryAfterS": 7 } } })
            compare(out.error.retryAfterS, 7)
            verify(CloudBoxTexts.errorText(out.error).indexOf("in 7 Sekunden") >= 0)
        }

        function test_nichtErreichbarUndZeitlimit() {
            var out = null
            client.list("", function(r) { out = r })
            mockHttp.answer({ "ok": false, "status": 0, "error": "Connection refused" })
            compare(out.error.code, "unreachable")
            verify(out.error.message.indexOf("Connection refused") >= 0)
            client.list("", function(r) { out = r })
            mockHttp.answer({ "ok": false, "status": 0, "error": "timeout" })
            compare(out.error.code, "timeout")
        }

        function test_fehlerOhneJsonKoerper() {
            var out = null
            client.list("", function(r) { out = r })
            mockHttp.answer({ "ok": false, "status": 502, "error": "HTTP 502" })
            compare(out.error.code, "http_502")
            compare(out.error.status, 502)
        }

        // ---------- Dateien ----------

        function test_listKodiertPfad() {
            var out = null
            client.list("mein ordner/ä", function(r) { out = r })
            compare(mockHttp.last().url, "https://aurora.example/api/v1/box/files?path=mein%20ordner%2F%C3%A4")
            mockHttp.answer({ "ok": true, "status": 200, "data": { "path": "mein ordner/ä",
                "entries": [{ "name": "a.txt", "type": "file", "size": 3, "modifiedAt": "x" }] } })
            verify(out.ok)
            compare(out.entries.length, 1)
            compare(out.entries[0].name, "a.txt")
        }

        function test_readLiefertTextMitKappe() {
            var out = null
            client.read("a.txt", function(r) { out = r })
            var o = mockHttp.last()
            compare(o.method, "GET")
            compare(o.url, "https://aurora.example/api/v1/box/file?path=a.txt")
            compare(o.maxBytes, 2000000)
            mockHttp.answer({ "ok": true, "status": 200, "text": "hallo", "binary": false, "size": 5 })
            verify(out.ok)
            compare(out.text, "hallo")
            compare(out.binary, false)
        }

        function test_readZuGross() {
            var out = null
            client.read("big.bin", function(r) { out = r })
            mockHttp.answer({ "ok": false, "status": 200, "error": "too_large" })
            compare(out.error.code, "too_large")
        }

        function test_writeSendetRohenInhaltPerPut() {
            var out = null
            client.write("src/a.js", "console.log(1)", function(r) { out = r })
            var o = mockHttp.last()
            compare(o.method, "PUT")
            compare(o.url, "https://aurora.example/api/v1/box/file?path=src%2Fa.js")
            compare(o.body, "console.log(1)")
            compare(o.contentType, "application/octet-stream")
            mockHttp.answer({ "ok": true, "status": 204 })
            verify(out.ok)
        }

        function test_removeUndMkdir() {
            client.remove("a.txt", function() {})
            compare(mockHttp.last().method, "DELETE")
            compare(mockHttp.last().url, "https://aurora.example/api/v1/box/file?path=a.txt")
            client.mkdir("neu", function() {})
            compare(mockHttp.last().method, "POST")
            compare(mockHttp.last().url, "https://aurora.example/api/v1/box/dir?path=neu")
        }

        // ---------- Vorschau / Screenshot ----------

        function test_previewMeldetAn() {
            var out = null
            client.preview(5173, "", function(r) { out = r })
            var o = mockHttp.last()
            compare(o.method, "PUT")
            compare(o.url, "https://aurora.example/api/v1/box/previews/app")
            compare(o.body.port, 5173)
            mockHttp.answer({ "ok": true, "status": 200, "data": { "name": "app-1a2b3c",
                "url": "https://app-1a2b3c.preview.aurora.example", "port": 5173, "tlsReady": false } })
            verify(out.ok)
            compare(out.preview.name, "app-1a2b3c")
            compare(out.preview.tlsReady, false)
            client.preview(3000, "mein shop", function() {})
            compare(mockHttp.last().url, "https://aurora.example/api/v1/box/previews/mein%20shop")
        }

        function test_previewsUndOpen() {
            var out = null
            client.previews(function(r) { out = r })
            compare(mockHttp.last().url, "https://aurora.example/api/v1/box/previews")
            mockHttp.answer({ "ok": true, "status": 200, "data": { "previews": [
                { "name": "app-1a2b3c", "url": "u", "port": 5173, "tlsReady": true }] } })
            compare(out.previews[0].tlsReady, true)
            client.openPreview("app-1a2b3c", function(r) { out = r })
            compare(mockHttp.last().method, "POST")
            compare(mockHttp.last().url, "https://aurora.example/api/v1/box/previews/app-1a2b3c/open")
            mockHttp.answer({ "ok": true, "status": 200, "data": { "url": "https://einmal.example/t" } })
            compare(out.url, "https://einmal.example/t")
            client.openPreview("app-1a2b3c", function(r) { out = r })
            mockHttp.answer({ "ok": false, "status": 409, "error": "HTTP 409", "data": { "error": {
                "code": "preview_not_ready", "message": "x", "retryAfterS": 5 } } })
            compare(out.error.code, "preview_not_ready")
            compare(out.error.retryAfterS, 5)
        }

        function test_screenshotSpeichertPngUndPrueftSignatur() {
            var out = null
            client.screenshot("http://localhost:5173/", "/tmp/x.png", function(r) { out = r })
            var o = mockHttp.last()
            compare(o.method, "POST")
            compare(o.url, "https://aurora.example/api/v1/box/screenshot")
            compare(o.body.url, "http://localhost:5173/")
            compare(o.saveTo, "/tmp/x.png")
            mockHttp.answer({ "ok": true, "status": 200, "path": "/tmp/x.png", "head": "89504e470d0a1a0a" })
            verify(out.ok)
            compare(out.path, "/tmp/x.png")
            client.screenshot("http://localhost:5173/", "/tmp/y.png", function(r) { out = r })
            mockHttp.answer({ "ok": true, "status": 200, "path": "/tmp/y.png", "head": "3c68746d6c3e" })
            verify(!out.ok)
            compare(out.error.code, "bad_response")
        }

        // ---------- exec (SSE) ----------

        function _exec(cmd, opts) {
            var log = { "out": [], "end": null, "error": null }
            var h = client.exec(cmd, opts || {}, {
                "onOut": function(s, d) { log.out.push(s + ":" + d) },
                "onEnd": function(e) { log.end = e },
                "onError": function(e) { log.error = e }
            })
            log.handle = h
            return log
        }

        function test_execGutfall() {
            var log = _exec("ls", { "cwd": "app", "timeoutS": 30 })
            compare(streams.length, 1)
            var s = streams[0]
            compare(s.sse, true)
            compare(s.url, "https://aurora.example/api/v1/box/exec")
            compare(s.body.cmd, "ls")
            compare(s.body.cwd, "app")
            compare(s.body.timeoutS, 30)
            compare(s.headers["Authorization"], "Bearer nk_test")
            // stille Befehle: Leerlauf-Grenze über dem Befehls-Zeitlimit
            compare(s.idleTimeoutMs, 90000)
            s.objectReceived({ "stream": "stdout", "data": "a\n" })
            s.objectReceived({ "stream": "stderr", "data": "b\n" })
            s.objectReceived({ "exitCode": 0, "timedOut": false, "truncated": false })
            s.finished(true, 200, "")
            compare(log.out, ["stdout:a\n", "stderr:b\n"])
            compare(log.end.exitCode, 0)
            compare(log.error, null)
        }

        function test_execTimeoutWirdGeklammert() {
            _exec("x", { "timeoutS": 5000 })
            compare(streams[0].body.timeoutS, 900)
            _exec("x", {})
            compare(streams[1].body.timeoutS, 120)
        }

        function test_execEndeMitNullExitCode() {
            var log = _exec("sleep 999", {})
            streams[0].objectReceived({ "exitCode": null, "timedOut": true, "truncated": false })
            streams[0].finished(true, 200, "")
            compare(log.end.exitCode, null)
            compare(log.end.timedOut, true)
        }

        function test_execFehlerEreignisImStrom() {
            var log = _exec("x", {})
            streams[0].objectReceived({ "stream": "stdout", "data": "teil" })
            streams[0].objectReceived({ "code": "unauthorized", "message": "widerrufen" })
            streams[0].finished(true, 200, "")
            compare(log.end, null)
            compare(log.error.code, "unauthorized")
            // widerrufener Schlüssel: Cache geleert
            client.status(function() {})
            compare(mockKeyring.reads.length, 2)
        }

        function test_execAbgerissenOhneEnde() {
            var log = _exec("x", {})
            streams[0].objectReceived({ "stream": "stdout", "data": "teil" })
            streams[0].finished(true, 200, "")
            compare(log.error.code, "stream_broken")
            compare(log.end, null)
        }

        function test_execTransportfehlerMittendrin() {
            var log = _exec("x", {})
            streams[0].finished(false, 200, "Remote host closed")
            compare(log.error.code, "stream_broken")
        }

        function test_execFehlerstatusVorDemStrom() {
            var log = _exec("x", {})
            streams[0].objectReceived({ "error": { "code": "box_blocked", "message": "gesperrt" } })
            streams[0].finished(false, 423, "HTTP 423")
            compare(log.error.status, 423)
            compare(log.error.code, "box_blocked")
        }

        function test_execNichtErreichbarUndLeerlauf() {
            var log = _exec("x", {})
            streams[0].finished(false, 0, "Connection refused")
            compare(log.error.code, "unreachable")
            log = _exec("x", {})
            streams[1].finished(false, 0, "timeout")
            compare(log.error.code, "timeout")
        }

        function test_execGenauEinAbschluss() {
            var log = _exec("x", {})
            var errors = 0
            streams[0].objectReceived({ "exitCode": 1, "timedOut": false, "truncated": false })
            streams[0].objectReceived({ "code": "spaet", "message": "zu spät" })
            streams[0].finished(false, 200, "irgendwas")
            compare(log.end.exitCode, 1)
            compare(log.error, null)
        }

        function test_execAbbruchIstStill() {
            var log = _exec("x", {})
            log.handle.abort()
            verify(streams[0].aborted)
            streams[0].finished(false, 0, "cancelled")
            compare(log.end, null)
            compare(log.error, null)
        }

        function test_execOhneSchluessel() {
            mockKeyring.secret = ""
            var log = _exec("x", {})
            compare(streams.length, 0)
            compare(log.error.code, "no_key")
        }

        // ---------- Texte ----------

        function test_fehlertexteUndNutzermeldung() {
            verify(CloudBoxTexts.errorText({ "status": 401, "code": "unauthorized" }).indexOf("Geräte-Schlüssel") >= 0)
            verify(CloudBoxTexts.errorText({ "code": "no_key" }).indexOf("nicht eingerichtet") >= 0)
            verify(CloudBoxTexts.errorText({ "code": "stream_broken" }).indexOf("abgerissen") >= 0)
            compare(CloudBoxTexts.userMessage({ "code": "unreachable" }), "Server nicht erreichbar")
            verify(CloudBoxTexts.userMessage({ "status": 401, "code": "unauthorized" }).indexOf("Geräte") >= 0)
        }

        function test_werkzeugtexteMitVorschauDomain() {
            verify(CloudBoxTexts.runCommand("").indexOf("server.allowedHosts: true") >= 0)
            verify(CloudBoxTexts.runCommand("preview.aurora.example").indexOf("['.preview.aurora.example']") >= 0)
            verify(CloudBoxTexts.runCommand("").indexOf("/work") >= 0)
            verify(CloudBoxTexts.runCommand("").indexOf("0.0.0.0") >= 0)
            var d = CloudBoxTexts.def("preview", "x", CloudBoxTexts.PREVIEW_PARAMS)
            compare(d["function"].name, "preview")
            compare(d["function"].parameters.required, ["port"])
        }
    }
}
