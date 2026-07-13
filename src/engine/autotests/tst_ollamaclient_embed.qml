import QtQuick
import QtTest
import net.niuton.aurora.engine

TestCase {
    name: "OllamaClientEmbed"

    QtObject {
        id: mockHttp
        property var calls: []
        function getJson(url, cb, t) { calls.push({ "url": url, "cb": cb }) }
        function postJson(url, body, cb, t) { calls.push({ "url": url, "body": body, "cb": cb, "timeout": t }) }
        function answer(i, r) { if (calls[i].cb) calls[i].cb(r) }
        function last() { return calls[calls.length - 1] }
    }

    OllamaClient { id: client; baseUrl: "http://test:11434"; http: mockHttp }

    function init() { mockHttp.calls = [] }

    function test_embed_postetUndLiefertVektor() {
        var out = "unset"
        client.embed("nomic-embed-text", "Hallo Welt", function(v) { out = v })
        var c = mockHttp.last()
        compare(c.url, "http://test:11434/api/embed")
        compare(c.body.model, "nomic-embed-text")
        compare(c.body.input, "Hallo Welt")
        mockHttp.answer(0, { "ok": true, "data": { "embeddings": [[0.5, -0.25, 1.0]] } })
        compare(out.length, 3)
        compare(out[0], 0.5)
    }

    function test_embed_fehlerLiefertNull() {
        var out = "unset"
        client.embed("nomic-embed-text", "x", function(v) { out = v })
        mockHttp.answer(0, { "ok": false, "error": "timeout", "status": 0 })
        compare(out, null)
    }

    function test_embed_leereEmbeddingsLiefertNull() {
        var out = "unset"
        client.embed("m", "x", function(v) { out = v })
        mockHttp.answer(0, { "ok": true, "data": {} })
        compare(out, null)
    }
}
