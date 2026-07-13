import QtQml

// Ein Chat-Request (Spec 3.2): Job-Objekt mit Signalen token/thinking/
// toolCalls/done/error und abort(). Genau eines von done/error terminiert;
// abort() ist still. Der Aufrufer zerstört den Job nach Gebrauch.
QtObject {
    id: job

    // Vom OllamaClient beim Erzeugen gesetzt
    property var httpRef: null
    property Component ndjsonFactory: null
    property string url: ""
    property var payload: null
    property bool twoPhase: false

    // Aggregat für done()
    property string content: ""
    property string thinkingText: ""
    property var collectedToolCalls: []

    property bool _alive: true
    property bool _terminal: false
    property string _streamError: ""
    property var _stream: null

    signal token(string text)
    signal thinking(string text)
    signal toolCalls(var calls)
    signal done(var result)
    signal error(string message)

    function abort() {
        _alive = false
        if (_stream) _stream.abort()   // NdjsonStream.abort() ist still
    }

    function start() {
        if (twoPhase && payload.tools && payload.tools.length > 0)
            _startTwoPhase()
        else
            _startStreaming()
    }

    function _startStreaming() {
        _stream = ndjsonFactory.createObject(job, { "idleTimeoutMs": 90000 })
        _stream.objectReceived.connect(_onChunk)
        _stream.finished.connect(_onFinished)
        payload.stream = true
        _stream.post(url, payload)
    }

    function _onChunk(chunk) {
        if (!_alive) return
        if (chunk.error) { _streamError = String(chunk.error); return }
        // KEIN early-return bei chunk.done: manche Modelle (z.B. qwen3.6) liefern die
        // finalen content/tool_calls IM done:true-Chunk (Ollama streamt Deltas, der
        // done-Chunk-content ist dann leer, aber tool_calls stehen darin). Die
        // Terminierung macht _onFinished über das finished-Signal des Streams.
        var msg = chunk.message
        if (!msg) return
        if (msg.thinking) {
            thinkingText += msg.thinking
            thinking(msg.thinking)
        }
        if (msg.content) {
            content += msg.content
            token(msg.content)
        }
        if (msg.tool_calls && msg.tool_calls.length > 0) {
            collectedToolCalls = collectedToolCalls.concat(msg.tool_calls)
            toolCalls(msg.tool_calls)
        }
    }

    function _onFinished(ok, status, errText) {
        if (!_alive || _terminal) return
        _terminal = true
        if (_streamError !== "") { error(_streamError); return }
        if (!ok) { error(errText); return }
        done({ "content": content, "thinking": thinkingText,
               "toolCalls": collectedToolCalls })
    }

    // Fallback (twoPhaseToolCalls): non-streaming MIT Tools, think hart aus —
    // exakt das heutige Phase-1-Verhalten für Setups mit defektem
    // Tool-Call-Streaming.
    function _startTwoPhase() {
        var body = {}
        for (var k in payload) body[k] = payload[k]
        body.stream = false
        if (body.think !== undefined) body.think = false
        httpRef.postJson(url, body, function(res) {
            if (!_alive || _terminal) return
            _terminal = true
            if (!res.ok) {
                error((res.data && res.data.error)
                      ? String(res.data.error) : (res.error || ""))
                return
            }
            var msg = (res.data && res.data.message) || {}
            if (msg.content) {
                content = msg.content
                token(msg.content)
            }
            if (msg.tool_calls && msg.tool_calls.length > 0) {
                collectedToolCalls = msg.tool_calls
                toolCalls(msg.tool_calls)
            }
            done({ "content": content, "thinking": "",
                   "toolCalls": collectedToolCalls })
        }, 300000)
    }
}
