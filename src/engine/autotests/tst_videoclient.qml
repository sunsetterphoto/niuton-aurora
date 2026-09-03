import QtQuick
import QtTest
import net.niuton.aurora.engine

// OpenRouter-Video-Generierung: eigene API, NICHT Teil von /v1/models
// (deshalb existiert hier kein /v1/models-Pfad). Fakten (live verifiziert):
//   POST /v1/videos               -> {id, polling_url, status}      (202, async)
//   GET  /v1/videos/{jobId}       -> {status, unsigned_urls, usage} (poll)
//   GET  /v1/videos/models        -> Liste der 28 Video-Modelle
// Status-Enum: pending|in_progress|completed|failed|cancelled|expired
TestCase {
    name: "VideoClient"

    QtObject {
        id: mockHttp
        property var calls: []
        function getJson(url, cb, timeoutMs, headers) {
            calls.push({ "method": "get", "url": url, "cb": cb, "headers": headers })
        }
        function postJson(url, body, cb, timeoutMs, headers) {
            calls.push({ "method": "post", "url": url, "body": body,
                         "cb": cb, "timeout": timeoutMs, "headers": headers })
        }
        function answer(i, result) { if (calls[i].cb) calls[i].cb(result) }
        function last() { return calls[calls.length - 1] }
    }

    // KeyRing-Mock wie in tst_openaiclient
    QtObject {
        id: mockKeyring
        property var reads: []
        property string secret: "sk-test"
        function readSecret(keyRef, cb) {
            reads.push(keyRef)
            cb({ "ok": true, "secret": mockKeyring.secret })
        }
    }

    VideoClient {
        id: client
        baseUrl: "https://openrouter.ai/api"
        http: mockHttp
        keyring: mockKeyring
        keyRef: "openrouter"
    }

    function init() {
        mockHttp.calls = []
        mockKeyring.reads = []
        mockKeyring.secret = "sk-test"
        client.keyRef = "openrouter"
    }

    // ---------- Submit ----------

    function test_submitSendetAuthUndPayload() {
        var out = null
        client.submit({ "model": "google/veo-3.1-lite", "prompt": "ein Hund",
                        "aspectRatio": "16:9", "duration": 5,
                        "generateAudio": false }, function(r) { out = r })
        var c = mockHttp.last()
        compare(c.method, "post")
        verify(c.url.indexOf("/v1/videos") !== -1)
        compare(c.headers["Authorization"], "Bearer sk-test")
        compare(c.body.model, "google/veo-3.1-lite")
        compare(c.body.prompt, "ein Hund")
        compare(c.body.aspect_ratio, "16:9")
        compare(c.body.duration, 5)
        compare(c.body.generate_audio, false)
        mockHttp.answer(mockHttp.calls.length - 1,
            { "ok": true, "data": { "id": "job-123", "status": "pending",
                                    "polling_url": "…" } })
        verify(out.ok)
        compare(out.jobId, "job-123")
        compare(out.status, "pending")
    }

    function test_submitFehlerLiefertOkFalse() {
        var out = "unset"
        client.submit({ "model": "x", "prompt": "y" }, function(r) { out = r })
        mockHttp.answer(mockHttp.calls.length - 1, { "ok": false, "status": 402,
            "error": "insufficient credits" })
        compare(out.ok, false)
        verify(out.error !== undefined)
    }

    function test_submitOhneKeyKeinHeader() {
        client.keyRef = ""
        var out = null
        client.submit({ "model": "m", "prompt": "p" }, function(r) { out = r })
        var c = mockHttp.last()
        verify(!(c.headers && c.headers["Authorization"]))
    }

    // ---------- Poll ----------

    function test_pollParstStatusUrlsUndKosten() {
        var out = null
        client.poll("job-123", function(r) { out = r })
        var c = mockHttp.last()
        compare(c.method, "get")
        verify(c.url.indexOf("/v1/videos/job-123") !== -1)
        compare(c.headers["Authorization"], "Bearer sk-test")
        mockHttp.answer(mockHttp.calls.length - 1,
            { "ok": true, "data": { "id": "job-123", "status": "completed",
                                    "unsigned_urls": ["https://x/y.mp4"],
                                    "usage": { "cost": 0.32 } } })
        verify(out.ok)
        compare(out.status, "completed")
        compare(out.urls.length, 1)
        compare(out.cost, 0.32)
    }

    function test_pollFehlerMeldetNichtZweiteAntwort() {
        var out = "unset"
        client.poll("job-999", function(r) { out = r })
        mockHttp.answer(mockHttp.calls.length - 1, { "ok": false, "status": 404 })
        compare(out.ok, false)
    }

    // Lange Jobs: ein laufender Poll darf nicht verwechselt werden.
    function test_pollVerschiedeneJobs() {
        var out1 = null, out2 = null
        client.poll("job-a", function(r) { out1 = r })
        client.poll("job-b", function(r) { out2 = r })
        mockHttp.answer(mockHttp.calls.length - 2,
            { "ok": true, "data": { "status": "pending" } })
        compare(out1.status, "pending")
        // Zweiten erst später beantworten — kein Verwechslen
        verify(out2 === null)
        mockHttp.answer(mockHttp.calls.length - 1,
            { "ok": true, "data": { "status": "completed", "unsigned_urls": ["u"] } })
        compare(out2.status, "completed")
    }

    // ---------- Modell-Liste ----------

    function test_refreshVideoModelsMappt() {
        var out = null
        client.refreshVideoModels(function(r) { out = r })
        var c = mockHttp.last()
        verify(c.url.indexOf("/v1/videos/models") !== -1)
        compare(c.headers["Authorization"], "Bearer sk-test")
        mockHttp.answer(mockHttp.calls.length - 1, { "ok": true, "data": { "data": [
            { "id": "google/veo-3.1-lite", "name": "Veo 3.1 Lite",
              "generate_audio": true, "supported_durations": [4, 6, 8] },
            { "id": "kwaivgi/kling-v3.0-std", "name": "Kling v3 Std" }
        ] } })
        verify(out.ok)
        compare(out.models.length, 2)
        compare(out.models[0].name, "Veo 3.1 Lite")
        compare(out.models[0].audio, true)
        compare(out.models[0].durations.indexOf(8) !== -1, true)
    }
}