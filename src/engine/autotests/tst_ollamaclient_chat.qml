import QtQuick
import QtTest
import net.niuton.aurora.engine

TestCase {
    name: "OllamaClientChat"

    QtObject {
        id: mockHttp
        property var calls: []
        function getJson(url, cb, timeoutMs) { calls.push({ "url": url, "cb": cb }) }
        function postJson(url, body, cb, timeoutMs) {
            calls.push({ "url": url, "body": body, "cb": cb, "timeout": timeoutMs })
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
            property string postedUrl: ""
            property var postedBody: null
            property bool aborted: false
            function post(url, body) { postedUrl = url; postedBody = body }
            function abort() { aborted = true }
        }
    }

    OllamaClient {
        id: client
        baseUrl: "http://test:11434"
        http: mockHttp
        ndjsonFactory: mockStreamFactory
    }

    // Signal-Protokoll pro Job
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
        client.twoPhaseToolCalls = false
    }

    function test_streamingTokenThinkingDone() {
        var job = client.chat({ "model": "qwen3.5:9b",
                                "messages": [{ "role": "user", "content": "hi" }],
                                "think": true })
        _connectLog(job)
        var s = job._stream
        compare(s.postedUrl, "http://test:11434/api/chat")
        compare(s.postedBody.model, "qwen3.5:9b")
        compare(s.postedBody.stream, true)
        compare(s.postedBody.think, true)
        compare(s.postedBody.keep_alive, "10m")
        verify(s.postedBody.tools === undefined)
        compare(s.idleTimeoutMs, 90000)

        s.objectReceived({ "message": { "thinking": "Hmm. " } })
        s.objectReceived({ "message": { "thinking": "Also…" } })
        s.objectReceived({ "message": { "content": "Hal" } })
        s.objectReceived({ "message": { "content": "lo!" } })
        s.objectReceived({ "done": true })
        s.finished(true, 200, "")

        compare(log.length, 5)
        compare(log[0], ["thinking", "Hmm. "])
        compare(log[2], ["token", "Hal"])
        compare(log[4][0], "done")
        compare(log[4][1].content, "Hallo!")
        compare(log[4][1].thinking, "Hmm. Also…")
        compare(log[4][1].toolCalls.length, 0)
        job.destroy()
    }

    function test_optionsImPayload() {
        var job = client.chat({ "model": "m", "messages": [],
                                "options": { "num_ctx": 8192, "temperature": 0.7 } })
        var s = job._stream
        verify(s.postedBody.options !== undefined)
        compare(s.postedBody.options.num_ctx, 8192)
        compare(s.postedBody.options.temperature, 0.7)
        job.destroy()
    }

    function test_keineOptionsWennLeer() {
        var job = client.chat({ "model": "m", "messages": [], "options": {} })
        verify(job._stream.postedBody.options === undefined)   // leeres options -> kein Key
        job.destroy()

        var job2 = client.chat({ "model": "m", "messages": [] })
        verify(job2._stream.postedBody.options === undefined)  // gar kein options -> kein Key
        job2.destroy()
    }

    // Regression: manche Modelle (z.B. qwen3.6) liefern die finalen tool_calls IM
    // done:true-Chunk. Ein early-return bei chunk.done würde sie verschlucken.
    function test_streamingToolCallsInDoneChunk() {
        var job = client.chat({ "model": "qwen3.6", "messages": [],
                                "tools": [{ "type": "function" }] })
        _connectLog(job)
        var s = job._stream
        s.objectReceived({ "message": { "thinking": "Ich nutze read_file." } })
        s.objectReceived({ "message": { "content": "",
            "tool_calls": [{ "id": "abc", "function": { "index": 0, "name": "read_file",
                             "arguments": { "path": "/etc/hostname" } } }] }, "done": true })
        s.finished(true, 200, "")

        var doneEntry = null, sawToolCalls = false
        for (var i = 0; i < log.length; i++) {
            if (log[i][0] === "toolCalls") sawToolCalls = true
            if (log[i][0] === "done") doneEntry = log[i][1]
        }
        verify(sawToolCalls)                              // Signal gefeuert
        verify(doneEntry !== null)
        compare(doneEntry.toolCalls.length, 1)            // in done() aggregiert
        compare(doneEntry.toolCalls[0].function.name, "read_file")
        job.destroy()
    }

    function test_streamingToolCalls() {
        var job = client.chat({ "model": "qwen3.5:9b", "messages": [],
                                "tools": [{ "type": "function" }] })
        _connectLog(job)
        var s = job._stream
        compare(s.postedBody.tools.length, 1)
        verify(s.postedBody.think === undefined)   // think nicht im Request → nicht senden

        var calls = [{ "function": { "name": "web_search", "arguments": { "query": "wetter" } } }]
        var calls2 = [{ "function": { "name": "read_file", "arguments": { "path": "/etc/hostname" } } }]
        s.objectReceived({ "message": { "content": "Ich suche. " } })
        s.objectReceived({ "message": { "tool_calls": calls } })
        s.objectReceived({ "message": { "content": "und lese. " } })
        s.objectReceived({ "message": { "tool_calls": calls2 } })
        s.finished(true, 200, "")

        compare(log[1][0], "toolCalls")
        compare(log[1][1].length, 1)              // Signal trägt nur die Calls DIESES Chunks
        compare(log[1][1][0]["function"].name, "web_search")
        compare(log[3][0], "toolCalls")
        compare(log[3][1][0]["function"].name, "read_file")
        compare(log[4][0], "done")
        compare(log[4][1].content, "Ich suche. und lese. ")
        compare(log[4][1].toolCalls.length, 2)    // Sammlung über MEHRERE Chunks …
        compare(log[4][1].toolCalls[0]["function"].name, "web_search")   // … in Reihenfolge
        compare(log[4][1].toolCalls[1]["function"].name, "read_file")
        job.destroy()
    }

    function test_streamErrorObjekt() {
        var job = client.chat({ "model": "kaputt", "messages": [] })
        _connectLog(job)
        var s = job._stream
        s.objectReceived({ "error": "model 'kaputt' not found" })
        s.finished(true, 200, "")
        compare(log.length, 1)
        compare(log[0], ["error", "model 'kaputt' not found"])
        job.destroy()
    }

    function test_timeoutWirdError() {
        var job = client.chat({ "model": "m", "messages": [] })
        _connectLog(job)
        job._stream.finished(false, 0, "timeout")
        compare(log.length, 1)
        compare(log[0], ["error", "timeout"])
        job.destroy()
    }

    function test_abortIstStill() {
        var job = client.chat({ "model": "m", "messages": [] })
        _connectLog(job)
        var s = job._stream
        s.objectReceived({ "message": { "content": "Teil" } })
        job.abort()
        verify(s.aborted)
        // Späte Signale nach abort: komplett verworfen
        s.objectReceived({ "message": { "content": "spät" } })
        s.finished(false, 0, "abgebrochen")
        compare(log.length, 1)   // nur das eine token
        compare(log[0], ["token", "Teil"])
        job.destroy()
    }

    function test_twoPhaseMitTools() {
        client.twoPhaseToolCalls = true
        var job = client.chat({ "model": "m", "messages": [],
                                "tools": [{ "type": "function" }], "think": true })
        _connectLog(job)
        verify(job._stream === null)          // kein Stream im Fallback
        compare(mockHttp.calls.length, 1)
        var req = mockHttp.last()
        compare(req.url, "http://test:11434/api/chat")
        compare(req.body.stream, false)
        compare(req.body.think, false)        // Fallback erzwingt think:false
        compare(req.body.tools.length, 1)
        compare(req.timeout, 300000)

        var calls = [{ "function": { "name": "read_file", "arguments": { "path": "/tmp/x" } } }]
        mockHttp.answer(0, { "ok": true, "data": { "message": { "content": "", "tool_calls": calls } } })
        compare(log[0][0], "toolCalls")
        compare(log[1][0], "done")
        compare(log[1][1].toolCalls.length, 1)
        job.destroy()
    }

    function test_twoPhaseOhneToolsStreamt() {
        client.twoPhaseToolCalls = true
        var job = client.chat({ "model": "m", "messages": [] })
        verify(job._stream !== null)          // ohne Tools: normaler Stream
        compare(mockHttp.calls.length, 0)
        job.destroy()
    }

    function test_twoPhaseDirektantwort() {
        client.twoPhaseToolCalls = true
        var job = client.chat({ "model": "m", "messages": [], "tools": [{}] })
        _connectLog(job)
        mockHttp.answer(0, { "ok": true, "data": { "message": { "content": "Direkt." } } })
        compare(log[0], ["token", "Direkt."])
        compare(log[1][0], "done")
        compare(log[1][1].content, "Direkt.")
        job.destroy()
    }

    function test_twoPhaseHttpFehler() {
        client.twoPhaseToolCalls = true
        var job = client.chat({ "model": "m", "messages": [], "tools": [{}] })
        _connectLog(job)
        mockHttp.answer(0, { "ok": false, "error": "HTTP 500", "status": 500,
                             "data": { "error": "out of memory" } })
        compare(log.length, 1)
        compare(log[0], ["error", "out of memory"])   // Ollama-Fehlertext bevorzugt
        job.destroy()
    }

    function test_twoPhaseAbortVerwirftCallback() {
        client.twoPhaseToolCalls = true
        var job = client.chat({ "model": "m", "messages": [], "tools": [{}] })
        _connectLog(job)
        job.abort()
        mockHttp.answer(0, { "ok": true, "data": { "message": { "content": "spät" } } })
        compare(log.length, 0)
        job.destroy()
    }
}
