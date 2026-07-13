import QtQml
import net.niuton.aurora.core as Core

// Ein Ollama-Backend (Spec 3.2). Eine Instanz pro Backend, verwaltet vom
// ModelManager. Primitive injizierbar (Tests: Mocks).
QtObject {
    id: client

    property string baseUrl: ""
    property var http: Core.Http
    // Fallback für defektes Tool-Call-Streaming (bindet der ModelManager
    // aus AuroraSettings.twoPhaseToolCalls); ausgewertet in chat() (Task 3)
    property bool twoPhaseToolCalls: false

    // NdjsonStream-Fabrik: pro Job ein frischer Stream (kein geteilter
    // Zustand, Abort ist job-lokal). Tests injizieren hier ihren Mock.
    property Component ndjsonFactory: Component { Core.NdjsonStream {} }
    property Component _jobFactory: Component { ChatJob {} }

    // [{name, sizeGB, loaded, digest}] — Embedding-Modelle gefiltert
    property var models: []
    // name -> {digest, caps}; nur Erfolge werden gecacht
    property var _capsCache: ({})

    onBaseUrlChanged: {
        models = []
        _capsCache = {}
    }

    // /api/tags + /api/ps; invalidiert den Caps-Cache über den Modell-Digest
    // (behebt den Dauer-Cache: Modell-Updates wurden nie neu abgefragt)
    function refreshModels(callback) {
        http.getJson(baseUrl + "/api/tags", function(res) {
            if (!res.ok) {
                client.models = []
                if (callback) callback([])
                return
            }
            var list = (res.data && res.data.models) || []
            var fresh = []
            var digests = {}
            for (var i = 0; i < list.length; i++) {
                var m = list[i]
                if (m.name.indexOf("embed") !== -1) continue
                var digest = m.digest || ""
                digests[m.name] = digest
                fresh.push({ "name": m.name,
                             "sizeGB": Math.round(m.size / 1e8) / 10,
                             "loaded": false,
                             "digest": digest })
            }
            var kept = {}
            for (var name in client._capsCache) {
                var entry = client._capsCache[name]
                if (digests[name] !== undefined && entry.digest === digests[name])
                    kept[name] = entry
            }
            client._capsCache = kept

            http.getJson(client.baseUrl + "/api/ps", function(psRes) {
                if (psRes.ok) {
                    var loaded = ((psRes.data && psRes.data.models) || [])
                        .map(function(p) { return p.name })
                    for (var j = 0; j < fresh.length; j++)
                        fresh[j].loaded = loaded.indexOf(fresh[j].name) !== -1
                }
                client.models = fresh
                if (callback) callback(fresh)
            })
        })
    }

    // Capabilities (tools/thinking/vision) via /api/show, mit Digest-Cache.
    // Fehlschläge werden NICHT gecacht (Alt-Bug: offline → für immer []).
    function capabilities(model, callback) {
        var hit = _capsCache[model]
        if (hit) { callback(hit.caps); return }
        if (baseUrl === "") { callback([]); return }
        http.postJson(baseUrl + "/api/show", { "model": model }, function(res) {
            var caps = []
            if (res.ok) {
                caps = (res.data && res.data.capabilities) || []
                var digest = ""
                for (var i = 0; i < client.models.length; i++) {
                    if (client.models[i].name === model) {
                        digest = client.models[i].digest
                        break
                    }
                }
                var cache = client._capsCache
                cache[model] = { "digest": digest, "caps": caps }
                client._capsCache = cache
            }
            callback(caps)
        })
    }

    // Modell in den Speicher des EIGENEN Backends laden (behebt den Bug,
    // dass preload immer an den lokalen Server ging)
    function preload(model, callback) {
        http.postJson(baseUrl + "/api/chat",
            { "model": model, "messages": [], "keep_alive": "10m" },
            function(res) { if (callback) callback(res.ok) },
            300000)   // Modell-Load kann bei großen Modellen Minuten dauern
    }

    function setKeepAlive(model, duration) {
        http.postJson(baseUrl + "/api/chat",
            { "model": model, "messages": [], "keep_alive": duration },
            null, 60000)
    }

    // Ein streamender Request MIT Tools (Spec 3.2, ersetzt die
    // Zwei-Phasen-Architektur). request: {model, messages, tools?, think?,
    // keepAlive?}. tools/think nur mitgeben, wenn das Modell die Capability
    // hat — das entscheidet der Aufrufer.
    function chat(request) {
        var payload = {
            "model": request.model,
            "messages": request.messages,
            "stream": true,
            "keep_alive": request.keepAlive !== undefined ? request.keepAlive : "10m"
        }
        if (request.tools && request.tools.length > 0) payload.tools = request.tools
        if (request.think !== undefined) payload.think = request.think
        if (request.options && Object.keys(request.options).length > 0) payload.options = request.options
        var job = _jobFactory.createObject(client, {
            "httpRef": http,
            "ndjsonFactory": ndjsonFactory,
            "url": baseUrl + "/api/chat",
            "payload": payload,
            "twoPhase": twoPhaseToolCalls
        })
        job.start()
        return job
    }

    // Einbettung der Nutzerfrage (Wissensbasis Scheibe B). Ollama /api/embed
    // liefert embeddings als Array von Vektoren; wir nehmen den ersten. Best-effort:
    // bei Fehler/leer callback(null). Kurzer Timeout — blockiert nie den Chat.
    function embed(model, input, callback) {
        http.postJson(baseUrl + "/api/embed", { "model": model, "input": input }, function(res) {
            var vec = (res.ok && res.data && res.data.embeddings && res.data.embeddings.length > 0)
                ? res.data.embeddings[0] : null
            if (callback) callback(vec)
        }, 20000)
    }
}
