import QtQml
import net.niuton.aurora.core as Core

// OpenRouter-Audio-GENERIERUNG (Chat-API, nur Ausgabe). Fakt (Doku):
//   request : /v1/chat/completions, modalities ["text","audio"],
//             audio {voice, format:"wav"}, stream:true  (Audio ERFORDERT SSE)
//   response: delta.audio.data (base64-Fragmente -> zusammensetzen),
//             delta.audio.transcript (Text)
// Ergebnis: wavBase64 + transcript; lokale Wiedergabe über aplay (Speaker
// hat das Muster bereits) — kein neues Media-Framework.
//
// Auth wie bei OpenAiClient/VideoClient: keyring + keyRef, einmal auflösen,
// Cache bei keyRef-Wechsel invalidieren.
QtObject {
    id: client

    property string baseUrl: ""
    property var http: Core.Http
    property var keyring: Core.KeyRing
    property string keyRef: ""

    property Component sseFactory: Component { Core.NdjsonStream {} }
    // Der aktive Job (für abort() und Tests)
    property var _lastJob: null

    property string _keyState: ""
    property string _key: ""
    property var _keyWaiters: []

    onKeyRefChanged: {
        _keyState = ""
        _key = ""
        _keyWaiters = []
    }

    function _resolveKey(callback) {
        if (keyRef === "") { if (callback) callback(""); return }
        if (_keyState === "done") { if (callback) callback(_key); return }
        if (_keyState === "loading") {
            if (callback) _keyWaiters.push(callback)
            return
        }
        _keyState = "loading"
        keyring.readSecret(keyRef, function(res) {
            _key = (res.ok && res.secret) ? res.secret : ""
            _keyState = (_key !== "") ? "done" : ""
            var waiters = _keyWaiters
            _keyWaiters = []
            for (var i = 0; i < waiters.length; i++) waiters[i](_key)
            if (callback) callback(_key)
        })
    }

    function _authHeaders() {
        return (_key !== "") ? ({ "Authorization": "Bearer " + _key }) : ({})
    }

    // text -> {ok, wavBase64, transcript, error}
    // cfg: {voice (Default alloy), format (Default wav)}
    function generate(text, cfg, callback) {
        if (_lastJob) _lastJob.abort()
        _resolveKey(function() {
            if (baseUrl === "") {
                if (callback) callback({ "ok": false, "wavBase64": "", "transcript": "", "error": "kein Backend" })
                return
            }
            var payload = {
                "model": "google/lyria-3-clip-preview",   // Default (kostenlos); überschreibbar
                "messages": [{ "role": "user", "content": text || "" }],
                "modalities": ["text", "audio"],
                "audio": { "voice": (cfg && cfg.voice) || "alloy",
                           "format": (cfg && cfg.format) || "wav" },
                "stream": true
            }
            var akkum = ""
            var transcript = ""
            var s = sseFactory.createObject(client, { "idleTimeoutMs": 90000, "sse": true })
            // Der Callback-Block sammelt direkt; kein separates Job-Objekt nötig —
            // der Job-Zustand ist nur der Stream.
            s.objectReceived.connect(function(chunk) {
                if (chunk.error) return
                var choices = chunk.choices
                if (!choices || choices.length === 0) return
                var audio = choices[0].delta && choices[0].delta.audio
                if (!audio) return
                if (audio.data) akkum += audio.data
                if (audio.transcript) transcript += audio.transcript
            })
            s.finished.connect(function(ok, status, errText) {
                if (!ok) {
                    if (callback) callback({ "ok": false, "wavBase64": "", "transcript": "",
                                             "error": errText || ("HTTP " + status) })
                    return
                }
                if (callback) callback({ "ok": true, "wavBase64": akkum,
                                         "transcript": transcript, "error": "" })
            })
            client._lastJob = { "abort": function() { s.abort() }, "_stream": s, "stream": s }
            s.post(baseUrl + "/v1/chat/completions", payload, client._authHeaders())
        })
    }

    function abort() {
        if (_lastJob) { _lastJob.abort(); _lastJob = null }
    }
}