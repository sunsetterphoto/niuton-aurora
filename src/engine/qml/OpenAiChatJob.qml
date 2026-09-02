import QtQml

// Ein Chat-Request gegen ein OpenAI-kompatibles Backend. Signal-Protokoll und
// Terminierung wie ChatJob (genau eines von done/error; abort() ist still) —
// nur das Chunk-Format unterscheidet sich:
//
//   Ollama : {message: {content, thinking, tool_calls[]}}   pro Chunk komplett
//   OpenAI : {choices: [{delta: {content, tool_calls[]}}]}  fragmentiert
//
// tool_calls kommen bei OpenAI stückweise: der Name steht im ersten Delta,
// arguments tröpfeln als JSON-STRING über beliebig viele Chunks nach. Erst am
// Stream-Ende steht ein vollständiger Call fest — deshalb wird das
// toolCalls-Signal einmal am Ende gefeuert, nicht pro Chunk. Nach außen ist die
// Form dann Ollama-identisch (arguments als Objekt), damit der ChatController
// beide Backends gleich behandelt.
QtObject {
    id: job

    property var httpRef: null
    property Component streamFactory: null
    property string url: ""
    property var payload: null
    // Auth-Header für Cloud-Backends (OpenRouter): vom Client aufgelöst
    property var headers: null
    // Cloud-Backend: Kosten nach dem Stream über /v1/generation?id= nachladen
    // (Fakt: das Usage im Stream enthält keine cost; total_cost liefert die
    // Generation-Stats-API). Lokale llama-server haben nichts Vergleichbares.
    property bool fetchCost: false

    property string content: ""
    property string thinkingText: ""
    property var collectedToolCalls: []
    // Usage aus dem finalen Stream-Chunk (oder letztem Nicht-Leer-Chunk)
    property var usage: null
    // Antwort-Id (gen-...) für den Kosten-Lookup; leer bei Fehlern/Abort
    property string responseId: ""

    property bool _alive: true
    property bool _terminal: false
    property string _streamError: ""
    property var _stream: null
    // index -> {id, name, args} — Sammelstelle der Fragmente
    property var _pendingCalls: ({})

    signal token(string text)
    signal thinking(string text)
    signal toolCalls(var calls)
    signal done(var result)
    signal error(string message)

    function abort() {
        _alive = false
        if (_stream) _stream.abort()
    }

    function start() {
        _stream = streamFactory.createObject(job, { "idleTimeoutMs": 90000, "sse": true })
        _stream.objectReceived.connect(_onChunk)
        _stream.finished.connect(_onFinished)
        _stream.post(url, payload, headers || {})
    }

    function _onChunk(chunk) {
        if (!_alive) return
        if (chunk.error) {
            // Server melden Fehler teils als Objekt {message}, teils als String.
            _streamError = (chunk.error && chunk.error.message)
                ? String(chunk.error.message) : String(chunk.error)
            return
        }
        // Antwort-Id aus jedem Chunk übernehmen (für den Kosten-Lookup);
        // der finale Usage-Chunk hat KEINE choices — deshalb vor dem
        // choices-Guard erfassen.
        if (chunk.id) responseId = chunk.id
        if (chunk.usage) usage = chunk.usage
        var choices = chunk.choices
        if (!choices || choices.length === 0) return
        var delta = choices[0].delta
        if (!delta) return

        if (delta.reasoning_content) {
            thinkingText += delta.reasoning_content
            thinking(delta.reasoning_content)
        }
        if (delta.content) {
            content += delta.content
            token(delta.content)
        }
        var tc = delta.tool_calls
        if (tc && tc.length > 0) _collectToolCalls(tc)
    }

    // Fragmente nach index einsammeln. Der index fehlt bei manchen Servern im
    // Folge-Delta — dann gilt der zuletzt geöffnete Call.
    property int _lastIndex: 0
    function _collectToolCalls(list) {
        for (var i = 0; i < list.length; i++) {
            var frag = list[i]
            var idx = (frag.index !== undefined) ? frag.index : _lastIndex
            _lastIndex = idx
            var slot = _pendingCalls[idx] || { "id": "", "name": "", "args": "" }
            if (frag.id) slot.id = frag.id
            var fn = frag["function"]
            if (fn) {
                if (fn.name) slot.name = fn.name
                if (fn.arguments) slot.args += fn.arguments
            }
            _pendingCalls[idx] = slot
        }
    }

    // args-String -> Objekt (Ollama-Form). Defektes JSON darf den Zug nicht
    // sprengen: dann leeres Objekt, der Tool-Aufruf scheitert kontrolliert.
    function _finalizeToolCalls() {
        var out = []
        var keys = Object.keys(_pendingCalls).sort(function(a, b) { return a - b })
        for (var i = 0; i < keys.length; i++) {
            var slot = _pendingCalls[keys[i]]
            if (slot.name === "") continue
            var args = {}
            if (slot.args !== "") {
                try {
                    var parsed = JSON.parse(slot.args)
                    if (parsed && typeof parsed === "object" && !Array.isArray(parsed))
                        args = parsed
                } catch (e) {
                    args = {}
                }
            }
            out.push({ "id": slot.id,
                       "function": { "name": slot.name, "arguments": args } })
        }
        return out
    }

    function _onFinished(ok, status, errText) {
        if (!_alive || _terminal) return
        if (_streamError !== "") { _terminal = true; error(_streamError); return }
        if (!ok) { _terminal = true; error(errText); return }
        collectedToolCalls = _finalizeToolCalls()
        if (collectedToolCalls.length > 0) toolCalls(collectedToolCalls)
        var result = { "content": content, "thinking": thinkingText,
                       "toolCalls": collectedToolCalls }
        if (usage) result.usage = usage
        if (responseId !== "") result.generationId = responseId

        if (fetchCost && responseId !== "") {
            // Kosten best-effort: das done-Result wird erst nach der Antwort
            // (oder Fehlschlag) des Lookups gefeuert — die DB-Spur braucht die
            // Zahl, und ohne key (401) darf die Antwort trotzdem ankommen.
            var base = url
            var idx = base.indexOf("/v1/chat/completions")
            if (idx > 0) base = base.substring(0, idx)
            httpRef.getJson(base + "/v1/generation?id=" + responseId,
                function(res) {
                    if (!_alive) return
                    _terminal = true
                    if (res.ok && res.data && res.data.total_cost !== undefined)
                        result.cost = res.data.total_cost
                    done(result)
                }, 15000, headers || {})
            return
        }
        _terminal = true
        done(result)
    }
}
