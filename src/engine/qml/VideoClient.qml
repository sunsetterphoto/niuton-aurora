import QtQml
import net.niuton.aurora.core as Core

// OpenRouter-Video-Generierung (eigene API, nicht Teil von /v1/models):
//
//   POST /v1/videos            -> {id, polling_url, status}   (202, async Job)
//   GET  /v1/videos/{jobId}    -> {status, unsigned_urls, usage:{cost}}
//   GET  /v1/videos/models     -> Liste der Video-Modelle (28 Stück)
//
// Status-Enum: pending | in_progress | completed | failed | cancelled | expired.
// Die Kosten stecken in der Poll-Antwort (usage.cost) — kein separater Lookup.
//
// Auth wie beim OpenAiClient: injizierbares keyring + keyRef; der Schlüssel
// wird genau einmal aufgelöst (Cache, bei keyRef-Wechsel invalidiert).
// Video ist ein LANGER asynchroner Job (Minuten) — der Client liefert nur
// Submit/Poll; das Polling orchestriert der AuroraController.
QtObject {
    id: client

    property string baseUrl: ""
    property var http: Core.Http
    property var keyring: Core.KeyRing
    property string keyRef: ""

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

    // request: {model, prompt, aspectRatio?, duration?, generateAudio?, seed?}
    // callback({ok, jobId, status, error?})
    function submit(request, callback) {
        _resolveKey(function() {
            if (baseUrl === "") { if (callback) callback({ "ok": false, "error": "kein Backend" }); return }
            var body = { "model": request.model, "prompt": request.prompt }
            if (request.aspectRatio) body.aspect_ratio = request.aspectRatio
            if (request.duration) body.duration = request.duration
            if (request.generateAudio !== undefined) body.generate_audio = request.generateAudio
            if (request.seed !== undefined) body.seed = request.seed
            http.postJson(baseUrl + "/v1/videos", body, function(res) {
                var ok = res.ok && res.data
                var out = { "ok": ok, "jobId": "", "status": "", "error": "" }
                if (ok) {
                    out.jobId = res.data.id || ""
                    out.status = res.data.status || ""
                } else {
                    out.error = res.error || ("HTTP " + res.status)
                }
                if (callback) callback(out)
            }, 30000, client._authHeaders())
        })
    }

    // jobId -> {ok, status, urls:[], cost, error?}
    function poll(jobId, callback) {
        if (jobId === "") { if (callback) callback({ "ok": false, "error": "kein Job" }); return }
        _resolveKey(function() {
            if (baseUrl === "") { if (callback) callback({ "ok": false, "error": "kein Backend" }); return }
            http.getJson(baseUrl + "/v1/videos/" + jobId, function(res) {
                var ok = res.ok && res.data
                var out = { "ok": ok, "status": "", "urls": [], "cost": 0, "error": "" }
                if (ok) {
                    out.status = res.data.status || ""
                    out.urls = res.data.unsigned_urls || []
                    if (res.data.usage) out.cost = res.data.usage.cost || 0
                } else {
                    out.error = res.error || ("HTTP " + res.status)
                }
                if (callback) callback(out)
            }, 30000, client._authHeaders())
        })
    }

    // Liste der Video-Modelle (für einen späteren Picker / Debug). 
    // callback({ok, models:[{id,name,audio,durations}], error?})
    function refreshVideoModels(callback) {
        _resolveKey(function() {
            if (baseUrl === "") { if (callback) callback({ "ok": false, "models": [], "error": "kein Backend" }); return }
            http.getJson(baseUrl + "/v1/videos/models", function(res) {
                var ok = res.ok && res.data
                var out = { "ok": ok, "models": [], "error": "" }
                if (ok) {
                    var list = res.data.data || []
                    for (var i = 0; i < list.length; i++) {
                        var m = list[i]
                        out.models.push({ "id": m.id, "name": m.name || m.id,
                                         "audio": !!m.generate_audio,
                                         "durations": m.supported_durations || [] })
                    }
                } else {
                    out.error = res.error || ("HTTP " + res.status)
                }
                if (callback) callback(out)
            }, 30000, client._authHeaders())
        })
    }
}