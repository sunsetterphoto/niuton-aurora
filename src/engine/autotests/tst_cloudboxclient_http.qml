import QtQuick
import QtTest
import net.niuton.aurora.engine

// CloudBoxClient gegen den echten Test-HTTP-Server (testServer kommt aus dem
// C++-Harness tst_cloudboxclient_http.cpp). Nur der Schlüsselbund ist eine
// Attrappe — die D-Bus-Strecke prüft test_keyring.
TestCase {
    name: "CloudBoxClientHttp"

    QtObject {
        id: keyring
        property string secret: "nk_test"
        function readSecret(ref, cb) { cb({ "ok": true, "secret": keyring.secret }) }
    }

    CloudBoxClient {
        id: client
        keyring: keyring
    }

    property var result: null
    function cb(r) { result = r }

    function init() {
        client.endpoint = testServer.baseUrl
        client.timeoutMs = 30000
        client.execIdleTimeoutMs = 0
        client.resetKey()
        keyring.secret = "nk_test"
        result = null
    }

    function waitResult() { tryVerify(function() { return result !== null }, 5000) }

    function test_meGutfallMitBearer() {
        testServer.respond(200, JSON.stringify({ "username": "anna", "displayName": "Anna", "tier": "guest",
            "locale": "de", "features": { "box": true }, "device": { "id": "d1", "name": "Laptop" },
            "previewDomain": "preview.aurora.example" }))
        client.me(cb)
        waitResult()
        verify(result.ok)
        compare(result.me.displayName, "Anna")
        compare(result.me.tier, "guest")
        compare(result.me.deviceName, "Laptop")
        var head = testServer.lastHead().toLowerCase()
        verify(head.indexOf("get /api/v1/me ") === 0)
        verify(head.indexOf("authorization: bearer nk_test") >= 0)
    }

    function test_401_423_429() {
        testServer.respond(401, '{"error":{"code":"unauthorized","message":"Schlüssel ungültig"}}')
        client.status(cb)
        waitResult()
        compare(result.error.status, 401)
        compare(result.error.code, "unauthorized")
        result = null
        testServer.respond(423, '{"error":{"code":"box_blocked","message":"gesperrt"}}')
        client.list("", cb)
        waitResult()
        compare(result.error.code, "box_blocked")
        result = null
        testServer.respond(429, '{"error":{"code":"too_many_requests","message":"langsam","retryAfterS":4}}')
        client.list("", cb)
        waitResult()
        compare(result.error.status, 429)
        compare(result.error.retryAfterS, 4)
    }

    function test_nichtErreichbar() {
        client.endpoint = testServer.closedUrl()
        client.list("", cb)
        waitResult()
        compare(result.error.code, "unreachable")
    }

    function test_zeitlimit() {
        client.timeoutMs = 300
        testServer.stall(200)
        client.list("", cb)
        waitResult()
        compare(result.error.code, "timeout")
    }

    function test_dateiLesenUndSchreiben() {
        testServer.respond(200, "hallo\nwelt", "application/octet-stream")
        client.read("notiz.txt", cb)
        waitResult()
        verify(result.ok)
        compare(result.text, "hallo\nwelt")
        compare(result.binary, false)
        result = null
        testServer.respond(204, "")
        client.write("a/b.txt", "inhalt ä", cb)
        waitResult()
        verify(result.ok)
        var head = testServer.lastHead().toLowerCase()
        verify(head.indexOf("put /api/v1/box/file?path=a%2fb.txt ") === 0)
        verify(head.indexOf("content-length: 9") >= 0)
        compare(testServer.lastBody(), "inhalt ä")
    }

    function test_screenshotAlsPngDatei() {
        testServer.respondHex(200, "89504e470d0a1a0a0000000d49484452", "image/png")
        var dest = testServer.tempDir + "/shot.png"
        client.screenshot("http://localhost:5173/", dest, cb)
        waitResult()
        verify(result.ok)
        compare(result.path, dest)
        compare(JSON.parse(testServer.lastBody()).url, "http://localhost:5173/")
    }

    function _exec(cmd, opts) {
        var log = { "out": "", "end": null, "error": null }
        client.exec(cmd, opts || {}, {
            "onOut": function(s, d) { log.out += d },
            "onEnd": function(e) { log.end = e },
            "onError": function(e) { log.error = e }
        })
        return log
    }

    function test_execStromMitGeteiltenZeilen() {
        testServer.respondChunked(200, [
            "event: out\ndata: {\"stream\":\"stdout\",\"da",
            "ta\":\"eins\\n\"}\n\nevent: out\ndata: {\"stream\":\"stderr\",\"data\":\"zwei\\n\"}\n\n",
            "event: end\ndata: {\"exitCode\":3,\"timedOut\":false,\"truncated\":true}\n\n"], 30)
        var log = _exec("make", { "cwd": "app", "timeoutS": 60 })
        tryVerify(function() { return log.end !== null || log.error !== null }, 5000)
        compare(log.error, null)
        compare(log.out, "eins\nzwei\n")
        compare(log.end.exitCode, 3)
        compare(log.end.truncated, true)
        var body = JSON.parse(testServer.lastBody())
        compare(body.cmd, "make")
        compare(body.cwd, "app")
        compare(body.timeoutS, 60)
        verify(testServer.lastHead().toLowerCase().indexOf("authorization: bearer nk_test") >= 0)
    }

    function test_execFehlerstatusVorDemStrom() {
        testServer.respond(423, '{"error":{"code":"box_blocked","message":"gesperrt"}}')
        var log = _exec("ls", {})
        tryVerify(function() { return log.error !== null }, 5000)
        compare(log.error.status, 423)
        compare(log.error.code, "box_blocked")
        compare(log.end, null)
    }

    function test_execWiderrufMittenImStrom() {
        testServer.respondChunked(200, [
            "event: out\ndata: {\"stream\":\"stdout\",\"data\":\"a\"}\n\n",
            "event: error\ndata: {\"code\":\"unauthorized\",\"message\":\"Schlüssel widerrufen\"}\n\n"], 30)
        var log = _exec("sleep 100", {})
        tryVerify(function() { return log.error !== null }, 5000)
        compare(log.error.code, "unauthorized")
        compare(log.out, "a")
    }

    function test_execAbgerissenOhneEnde() {
        testServer.respondChunked(200, [
            "event: out\ndata: {\"stream\":\"stdout\",\"data\":\"a\"}\n\n",
            "event: out\ndata: {\"stream\":\"stdout\",\"data\":\"b\"}\n\n"], 30)
        var log = _exec("x", {})
        tryVerify(function() { return log.error !== null || log.end !== null }, 5000)
        compare(log.end, null)
        compare(log.error.code, "stream_broken")
        compare(log.out, "ab")
    }

    function test_execLeerlaufZeitlimit() {
        client.execIdleTimeoutMs = 300
        testServer.stall(200)
        var log = _exec("x", {})
        tryVerify(function() { return log.error !== null || log.end !== null }, 5000)
        compare(log.end, null)
        compare(log.error.code, "timeout")
    }
}
