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

    // Fake für die KeyRing-Primitive: liefert synchron einen Schlüssel und
    // protokolliert die Anfragen (Auth-Tests dürfen nie das echte KWallet
    // oder die Session berühren).
    QtObject {
        id: mockKeyring
        property var reads: []
        property string secret: "sk-test"
        function readSecret(keyRef, cb) {
            reads.push(keyRef)
            cb({ "ok": true, "secret": mockKeyring.secret })
        }
    }

    // Variante, die fehlschlägt (Wallet zu / abgelehnt)
    QtObject {
        id: brokenKeyring
        property var reads: []
        function readSecret(keyRef, cb) {
            reads.push(keyRef)
            cb({ "ok": false, "error": "Wallet zu" })
        }
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
            property var postedHeaders: null
            property bool aborted: false
            function post(url, body, headers) { postedUrl = url; postedBody = body; postedHeaders = headers }
            function abort() { aborted = true }
        }
    }

    OpenAiClient {
        id: client
        baseUrl: "http://test:8080"
        http: mockHttp
        sseFactory: mockStreamFactory
        keyring: mockKeyring
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
        mockKeyring.reads = []
        mockKeyring.secret = "sk-test"
        client.keyRef = ""          // Tests isolieren: kein Zustand übernehmen
        client.keyring = mockKeyring
    }

    // ---------- Auth (OpenRouter: Cloud-Backend braucht einen Key) ----------

    // Ohne keyRef darf kein Authorization-Header entstehen und die KeyRing-
    // Primitive gar nicht erst gefragt werden — llama-server lokal braucht nichts.
    function test_ohneKeyRefKeinAuthHeader() {
        client.refreshModels()
        verify(!(mockHttp.calls[0].headers && mockHttp.calls[0].headers["Authorization"]))
        compare(mockKeyring.reads.length, 0)
    }

    // Mit keyRef: der Schlüssel wird genau einmal aufgelöst, alle Requests
    // tragen ihn als Bearer-Header.
    function test_mitKeyRefAuthHeaderBeiModellen() {
        client.keyRef = "openrouter"
        client.refreshModels()
        var c = mockHttp.calls[0]
        compare(c.headers["Authorization"], "Bearer sk-test")
        compare(mockKeyring.reads.length, 1)
        compare(mockKeyring.reads[0], "openrouter")

        // Schlüssel bleibt gecacht: zweiter Request ohne weiteren readSecret.
        client.refreshModels()
        compare(mockKeyring.reads.length, 1)
        compare(mockHttp.calls[1].headers["Authorization"], "Bearer sk-test")
    }

    // Chat streamt über NdjsonStream — auch dort muss der Header hin.
    function test_authHeaderImChatStream() {
        client.keyRef = "openrouter"
        var job = client.chat({ "model": "m", "messages": [] })
        var s = job._stream
        compare(s.postedHeaders["Authorization"], "Bearer sk-test")
        job.destroy()
    }

    function test_authHeaderBeiEmbed() {
        client.keyRef = "openrouter"
        client.embed("nomic", "hallo", function(v) {})
        compare(mockHttp.last().headers["Authorization"], "Bearer sk-test")
    }

    // Abwesenheit des Keys ist kein Fehler, aber auch kein Empty-Bearer:
    // einfach ohne Header arbeiten (Server meldet dann 401 — ehrlich).
    function test_leererSchluesselKeinHeader() {
        client.keyRef = "openrouter"
        mockKeyring.secret = ""
        client.refreshModels()
        verify(!(mockHttp.calls[0].headers && mockHttp.calls[0].headers["Authorization"]))
    }

    // Fehlschlag der KeyRing-Primitive (Wallet zu): wie leerer Schlüssel,
    // nur dass ein weiterer Versuch erneut fragt.
    function test_schluesselFehlerKeinHeader() {
        client.keyring = brokenKeyring
        client.keyRef = "openrouter"
        client.refreshModels()
        verify(!(mockHttp.calls[0].headers && mockHttp.calls[0].headers["Authorization"]))
        compare(brokenKeyring.reads.length, 1)
        // Nächster Request versucht es erneut (Fehler wird nicht gecacht)
        client.refreshModels()
        compare(brokenKeyring.reads.length, 2)
        client.keyring = mockKeyring
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
