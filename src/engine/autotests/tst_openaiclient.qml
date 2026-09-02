import QtQuick
import QtTest
import net.niuton.aurora.engine

// OpenAI-kompatibles Backend (llama-server, vLLM, LM Studio). Spiegelt die
// OllamaClient-Oberfläche, damit der ModelManager beide austauschbar hält.
TestCase {
    name: "OpenAiClient"

    QtObject {
        id: mockHttp
        property var calls: []
        function getJson(url, cb, timeoutMs) {
            calls.push({ "method": "get", "url": url, "cb": cb })
        }
        function postJson(url, body, cb, timeoutMs) {
            calls.push({ "method": "post", "url": url, "body": body,
                         "cb": cb, "timeout": timeoutMs })
        }
        function answer(i, result) { if (calls[i].cb) calls[i].cb(result) }
        function last() { return calls[calls.length - 1] }
    }

    Component {
        id: mockStreamFactory
        QtObject {
            signal objectReceived(var obj)
            signal finished(bool ok, int status, string error)
            property int idleTimeoutMs: 0
            property bool sse: false
            property string postedUrl: ""
            property var postedBody: null
            property bool aborted: false
            function post(url, body) { postedUrl = url; postedBody = body }
            function abort() { aborted = true }
        }
    }

    OpenAiClient {
        id: client
        baseUrl: "http://test:8080"
        http: mockHttp
        sseFactory: mockStreamFactory
    }

    property var log: []
    function _connectLog(job) {
        job.token.connect(function(t) { log.push(["token", t]) })
        job.thinking.connect(function(t) { log.push(["thinking", t]) })
        job.toolCalls.connect(function(c) { log.push(["toolCalls", c]) })
        job.done.connect(function(r) { log.push(["done", r]) })
        job.error.connect(function(m) { log.push(["error", m]) })
    }

    function init() {
        mockHttp.calls = []
        log = []
    }

    // ---------- Modelle ----------

    function test_refreshModelsMapptDataIds() {
        var out = null
        client.refreshModels(function(models) { out = models })
        compare(mockHttp.calls.length, 1)
        compare(mockHttp.calls[0].url, "http://test:8080/v1/models")
        mockHttp.answer(0, { "ok": true, "data": { "data": [
            { "id": "bonsai-27b-ternary" },
            { "id": "qwen3.6-27b" }
        ] } })
        compare(out.length, 2)
        compare(out[0].name, "bonsai-27b-ternary")
        compare(client.models.length, 2)
    }

    function test_modelsFehlerLeertListe() {
        client.refreshModels()
        mockHttp.answer(0, { "ok": true, "data": { "data": [{ "id": "m" }] } })
        compare(client.models.length, 1)
        client.refreshModels()
        mockHttp.answer(1, { "ok": false, "error": "refused", "status": 0 })
        compare(client.models.length, 0)
    }

    // /v1/models kennt weder Größe noch Ladezustand — die Felder existieren
    // trotzdem, damit pickerEntries im ModelManager unverändert bleibt.
    function test_modelsHabenPickerFelder() {
        client.refreshModels()
        mockHttp.answer(0, { "ok": true, "data": { "data": [{ "id": "m" }] } })
        compare(client.models[0].sizeGB, 0)
        compare(client.models[0].loaded, false)
        compare(client.models[0].digest, "")
    }

    // ---------- Capabilities ----------

    // OpenAI-Server haben kein /api/show. Statt zu raten liefert der Client
    // die konfigurierte Annahme — ohne Netzaufruf.
    function test_capabilitiesOhneServerabfrage() {
        var caps = null
        client.capabilities("bonsai-27b-ternary", function(c) { caps = c })
        compare(mockHttp.calls.length, 0)
        compare(caps, ["tools"])
    }

    function test_capabilitiesKonfigurierbar() {
        client.defaultCapabilities = ["tools", "vision"]
        var caps = null
        client.capabilities("m", function(c) { caps = c })
        compare(caps, ["tools", "vision"])
        client.defaultCapabilities = ["tools"]
    }

    // ---------- Preload / KeepAlive: No-ops ----------

    function test_preloadIstNoOpUndMeldetErfolg() {
        var ok = null
        client.preload("m", function(o) { ok = o })
        compare(mockHttp.calls.length, 0)   // kein Äquivalent in der OpenAI-API
        compare(ok, true)
        client.setKeepAlive("m", "0")       // darf nicht werfen
        compare(mockHttp.calls.length, 0)
    }

    // ---------- Chat ----------

    function test_chatStreamtDeltasUndSetztSse() {
        var job = client.chat({ "model": "bonsai-27b-ternary",
                                "messages": [{ "role": "user", "content": "hi" }] })
        _connectLog(job)
        var s = job._stream
        compare(s.postedUrl, "http://test:8080/v1/chat/completions")
        compare(s.sse, true)                       // SSE statt NDJSON
        compare(s.postedBody.model, "bonsai-27b-ternary")
        compare(s.postedBody.stream, true)

        s.objectReceived({ "choices": [{ "delta": { "content": "Hal" } }] })
        s.objectReceived({ "choices": [{ "delta": { "content": "lo!" } }] })
        s.finished(true, 200, "")

        compare(log.length, 3)
        compare(log[0], ["token", "Hal"])
        compare(log[2][0], "done")
        compare(log[2][1].content, "Hallo!")
        job.destroy()
    }

    // llama-server/DeepSeek-Stil: Reasoning kommt als reasoning_content.
    function test_reasoningContentWirdZuThinking() {
        var job = client.chat({ "model": "m", "messages": [] })
        _connectLog(job)
        var s = job._stream
        s.objectReceived({ "choices": [{ "delta": { "reasoning_content": "Hmm. " } }] })
        s.objectReceived({ "choices": [{ "delta": { "content": "Ja." } }] })
        s.finished(true, 200, "")
        compare(log[0], ["thinking", "Hmm. "])
        compare(log[2][1].thinking, "Hmm. ")
        job.destroy()
    }

    // DER Kernfall: OpenAI streamt tool_calls fragmentiert — der Name kommt im
    // ersten Delta, arguments tröpfeln als JSON-STRING nach. Der ChatController
    // erwartet Ollama-Form: ein Call mit arguments als OBJEKT.
    function test_fragmentierteToolCallsWerdenZusammengesetzt() {
        var job = client.chat({ "model": "m", "messages": [],
                                "tools": [{ "type": "function" }] })
        _connectLog(job)
        var s = job._stream
        compare(s.postedBody.tools.length, 1)

        s.objectReceived({ "choices": [{ "delta": { "tool_calls": [
            { "index": 0, "id": "call_1",
              "function": { "name": "fs_ls", "arguments": "" } }] } }] })
        s.objectReceived({ "choices": [{ "delta": { "tool_calls": [
            { "index": 0, "function": { "arguments": "{\"pa" } }] } }] })
        s.objectReceived({ "choices": [{ "delta": { "tool_calls": [
            { "index": 0, "function": { "arguments": "th\":\"/tmp\"}" } }] } }] })
        s.objectReceived({ "choices": [{ "finish_reason": "tool_calls", "delta": {} }] })
        s.finished(true, 200, "")

        var doneEntry = log[log.length - 1]
        compare(doneEntry[0], "done")
        var calls = doneEntry[1].toolCalls
        compare(calls.length, 1)
        compare(calls[0]["function"].name, "fs_ls")
        compare(calls[0]["function"].arguments.path, "/tmp")   // Objekt, nicht String
        job.destroy()
    }

    // Zwei parallele Calls: der index trennt sie.
    function test_zweiToolCallsNachIndexGetrennt() {
        var job = client.chat({ "model": "m", "messages": [] })
        _connectLog(job)
        var s = job._stream
        s.objectReceived({ "choices": [{ "delta": { "tool_calls": [
            { "index": 0, "function": { "name": "a", "arguments": "{}" } },
            { "index": 1, "function": { "name": "b", "arguments": "{\"x\":1}" } }] } }] })
        s.finished(true, 200, "")
        var calls = log[log.length - 1][1].toolCalls
        compare(calls.length, 2)
        compare(calls[0]["function"].name, "a")
        compare(calls[1]["function"].arguments.x, 1)
        job.destroy()
    }

    // Defektes arguments-JSON darf den Zug nicht sprengen: leeres Objekt.
    function test_defektesArgumentsJsonLiefertLeeresObjekt() {
        var job = client.chat({ "model": "m", "messages": [] })
        _connectLog(job)
        var s = job._stream
        s.objectReceived({ "choices": [{ "delta": { "tool_calls": [
            { "index": 0, "function": { "name": "a", "arguments": "{kaputt" } }] } }] })
        s.finished(true, 200, "")
        var calls = log[log.length - 1][1].toolCalls
        compare(calls.length, 1)
        compare(Object.keys(calls[0]["function"].arguments).length, 0)
        job.destroy()
    }

    // Aurora spricht intern Ollama-Optionen; OpenAI nimmt sie auf Top-Level.
    function test_ollamaOptionenWerdenGemappt() {
        var job = client.chat({ "model": "m", "messages": [],
                                "options": { "temperature": 0.7, "num_predict": 512,
                                             "top_p": 0.95, "num_ctx": 8192 } })
        var b = job._stream.postedBody
        compare(b.temperature, 0.7)
        compare(b.max_tokens, 512)          // num_predict -> max_tokens
        compare(b.top_p, 0.95)
        verify(b.num_ctx === undefined)     // serverseitig fixiert, nicht pro Request
        verify(b.options === undefined)
        job.destroy()
    }

    function test_fehlerBeendetJob() {
        var job = client.chat({ "model": "m", "messages": [] })
        _connectLog(job)
        job._stream.finished(false, 500, "HTTP 500")
        compare(log.length, 1)
        compare(log[0], ["error", "HTTP 500"])
        job.destroy()
    }

    function test_abortIstStill() {
        var job = client.chat({ "model": "m", "messages": [] })
        _connectLog(job)
        var s = job._stream
        job.abort()
        compare(s.aborted, true)
        s.finished(true, 200, "")
        compare(log.length, 0)              // kein done/error nach abort
        job.destroy()
    }

    // ---------- Embeddings ----------

    function test_embedLiestErstenVektor() {
        var vec = null
        client.embed("nomic", "hallo", function(v) { vec = v })
        var c = mockHttp.last()
        compare(c.url, "http://test:8080/v1/embeddings")
        compare(c.body.model, "nomic")
        compare(c.body.input, "hallo")
        mockHttp.answer(0, { "ok": true, "data": { "data": [
            { "embedding": [0.1, 0.2] }] } })
        compare(vec.length, 2)
        compare(vec[0], 0.1)
    }

    function test_embedFehlerLiefertNull() {
        var vec = "unset"
        client.embed("nomic", "hallo", function(v) { vec = v })
        mockHttp.answer(0, { "ok": false, "error": "timeout" })
        compare(vec, null)
    }

    function test_leereBaseUrlSetztNichtsAb() {
        client.baseUrl = ""
        client.refreshModels()
        var caps = null
        client.capabilities("m", function(c) { caps = c })
        compare(mockHttp.calls.length, 0)
        compare(caps.length, 0)
        client.baseUrl = "http://test:8080"
    }
}
