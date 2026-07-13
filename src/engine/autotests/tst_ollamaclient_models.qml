import QtQuick
import QtTest
import net.niuton.aurora.engine

TestCase {
    name: "OllamaClientModels"

    // Mock-Http: fängt Aufrufe, Test beantwortet sie explizit über answer()
    QtObject {
        id: mockHttp
        property var calls: []
        function getJson(url, cb, timeoutMs) {
            calls.push({ "method": "get", "url": url, "cb": cb })
        }
        function postJson(url, body, cb, timeoutMs) {
            calls.push({ "method": "post", "url": url, "body": body, "cb": cb, "timeout": timeoutMs })
        }
        function answer(i, result) { if (calls[i].cb) calls[i].cb(result) }
        function last() { return calls[calls.length - 1] }
    }

    OllamaClient {
        id: client
        baseUrl: "http://test:11434"
        http: mockHttp
    }

    function init() {
        mockHttp.calls = []
        client.baseUrl = ""              // leert models + Caps-Cache …
        client.baseUrl = "http://test:11434"   // … und setzt zurück
        mockHttp.calls = []
    }

    function _tagsAntwort() {
        return { "ok": true, "data": { "models": [
            { "name": "gemma4:e4b", "size": 5600000000, "digest": "abc1" },
            { "name": "nomic-embed-text", "size": 300000000, "digest": "eee1" },
            { "name": "qwen3.5:9b", "size": 9800000000, "digest": "def2" }
        ] } }
    }

    function test_refreshFiltertUndMarkiert() {
        var out = null
        client.refreshModels(function(models) { out = models })
        compare(mockHttp.calls.length, 1)
        compare(mockHttp.calls[0].url, "http://test:11434/api/tags")
        mockHttp.answer(0, _tagsAntwort())
        compare(mockHttp.calls.length, 2)
        compare(mockHttp.calls[1].url, "http://test:11434/api/ps")
        mockHttp.answer(1, { "ok": true, "data": { "models": [{ "name": "qwen3.5:9b" }] } })

        compare(out.length, 2)                    // Embedding gefiltert
        compare(out[0].name, "gemma4:e4b")
        compare(out[0].sizeGB, 5.6)               // Math.round(size/1e8)/10
        compare(out[0].loaded, false)
        compare(out[0].digest, "abc1")
        compare(out[1].loaded, true)
        compare(client.models.length, 2)
    }

    function test_tagsFehlerLeertListe() {
        _refreshMit("def2")                       // erst befüllen (tags+ps beantwortet)
        compare(client.models.length, 1)          // Vorbedingung: nicht leer
        var out = null
        var vorher = mockHttp.calls.length
        client.refreshModels(function(models) { out = models })
        mockHttp.answer(vorher, { "ok": false, "error": "Connection refused", "status": 0 })
        compare(out.length, 0)
        compare(client.models.length, 0)          // jetzt WIRKLICH das Leeren belegt
        compare(mockHttp.calls.length, vorher + 1)   // kein /api/ps nach tags-Fehler
    }

    function _refreshMit(digestQwen) {
        client.refreshModels()
        var i = mockHttp.calls.length - 1
        mockHttp.answer(i, { "ok": true, "data": { "models": [
            { "name": "qwen3.5:9b", "size": 9800000000, "digest": digestQwen }
        ] } })
        mockHttp.answer(mockHttp.calls.length - 1, { "ok": true, "data": { "models": [] } })
    }

    function test_capsCacheUndDigestInvalidierung() {
        _refreshMit("def2")

        var caps1 = null
        client.capabilities("qwen3.5:9b", function(c) { caps1 = c })
        var showCall = mockHttp.last()
        compare(showCall.method, "post")
        compare(showCall.url, "http://test:11434/api/show")
        compare(showCall.body.model, "qwen3.5:9b")
        mockHttp.answer(mockHttp.calls.length - 1,
            { "ok": true, "data": { "capabilities": ["tools", "thinking"] } })
        compare(caps1, ["tools", "thinking"])

        // Cache-Hit: kein weiterer /api/show-Aufruf
        var vorher = mockHttp.calls.length
        var caps2 = null
        client.capabilities("qwen3.5:9b", function(c) { caps2 = c })
        compare(mockHttp.calls.length, vorher)
        compare(caps2, ["tools", "thinking"])

        // Refresh mit UNVERÄNDERTEM Digest: Cache überlebt
        _refreshMit("def2")
        vorher = mockHttp.calls.length
        client.capabilities("qwen3.5:9b", function(c) {})
        compare(mockHttp.calls.length, vorher)

        // Refresh mit NEUEM Digest (Modell-Update): Cache invalidiert
        _refreshMit("def3")
        client.capabilities("qwen3.5:9b", function(c) {})
        compare(mockHttp.last().url, "http://test:11434/api/show")
    }

    function test_showFehlerWirdNichtGecacht() {
        // Alt-Bug: einmal offline → [] für immer. Neu: Fehlschlag nicht cachen.
        var caps = null
        client.capabilities("gemma4:e4b", function(c) { caps = c })
        mockHttp.answer(mockHttp.calls.length - 1, { "ok": false, "error": "timeout", "status": 0 })
        compare(caps.length, 0)

        var vorher = mockHttp.calls.length
        client.capabilities("gemma4:e4b", function(c) {})
        compare(mockHttp.calls.length, vorher + 1)                        // erneut gefragt …
        compare(mockHttp.calls[vorher].url, "http://test:11434/api/show") // … und zwar /api/show
    }

    function test_leereBaseUrlLiefertLeereCaps() {
        client.baseUrl = ""
        var caps = null
        client.capabilities("egal", function(c) { caps = c })
        compare(caps.length, 0)
        compare(mockHttp.calls.length, 0)
    }

    function test_preloadUndKeepAlive() {
        client.preload("gemma4:e4b")
        var p = mockHttp.last()
        compare(p.url, "http://test:11434/api/chat")
        compare(p.body.model, "gemma4:e4b")
        compare(p.body.messages.length, 0)
        compare(p.body.keep_alive, "10m")
        compare(p.timeout, 300000)

        var ok = null
        client.preload("gemma4:e4b", function(o) { ok = o })
        mockHttp.answer(mockHttp.calls.length - 1, { "ok": true, "status": 200 })
        compare(ok, true)

        client.setKeepAlive("gemma4:e4b", "0")
        var k = mockHttp.last()
        compare(k.body.keep_alive, "0")
        compare(k.timeout, 60000)
    }

    function test_baseUrlWechselLeertZustand() {
        _refreshMit("def2")
        client.capabilities("qwen3.5:9b", function(c) {})
        mockHttp.answer(mockHttp.calls.length - 1,
            { "ok": true, "data": { "capabilities": ["tools"] } })

        client.baseUrl = "http://anders:11434"
        compare(client.models.length, 0)
        client.capabilities("qwen3.5:9b", function(c) {})
        compare(mockHttp.last().url, "http://anders:11434/api/show")   // Cache weg
    }
}
