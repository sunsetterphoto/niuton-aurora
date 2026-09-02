import QtQml
import net.niuton.aurora.core as Core

// Ein OpenAI-kompatibles Backend (llama-server, vLLM, LM Studio, OpenRouter).
// Spiegelt bewusst die OllamaClient-Oberfläche — refreshModels/capabilities/
// preload/setKeepAlive/chat/embed —, damit der ModelManager beide Client-Typen
// über activeClient() austauschbar verwendet.
//
// Zwei Dinge kann die OpenAI-API nicht, die Ollama kann:
//   * Modell-Metadaten (Größe, Ladezustand, Digest) — /v1/models liefert nur ids
//   * Capabilities und Preload — es gibt kein /api/show und kein /api/chat mit
//     leeren messages. Beides wird lokal beantwortet statt geraten.
//
// Auth: Cloud-Backends (OpenRouter) tragen einen keyRef aus der Registry. Der
// Schlüssel kommt aus KeyRing (KWallet, Env-Fallback) und wird asynchron genau
// einmal aufgelöst; jeder Request bekommt dann einen Bearer-Header. Ohne
// keyRef (llama-server lokal) bleibt alles header-frei.
QtObject {
    id: client

    property string baseUrl: ""
    property var http: Core.Http
    // Injizierbare Schlüssel-Primitive (Tests: Mock statt echtem KWallet)
    property var keyring: Core.KeyRing
    // Verweist in der Registry auf das Secret; "" = kein Auth nötig
    property string keyRef: ""

    // Pro Job ein frischer Stream (Abort ist job-lokal), wie beim OllamaClient.
    property Component sseFactory: Component { Core.NdjsonStream {} }
    property Component _jobFactory: Component { OpenAiChatJob {} }

    // [{name, sizeGB, loaded, digest}] — Felder wie beim OllamaClient, damit
    // pickerEntries im ModelManager unverändert bleibt.
    property var models: []

    // Es gibt keine Capability-Abfrage. Tool-Calling beherrschen die gängigen
    // OpenAI-Server; wer ein Modell ohne Tools fährt, setzt das hier auf [].
    property var defaultCapabilities: ["tools"]

    // Auflösungszustand des Schlüssels: "" (ungelöst) | "loading" | "done".
    property string _keyState: ""
    property string _key: ""
    property var _keyWaiters: []

    onBaseUrlChanged: models = []
    // Anderer keyRef = anderer Schlüsselraum: den aufgelösten Schlüssel
    // verwerfen, sonst würde der nächste Request mit dem falschen Key
    // authentifizieren (Security: Nachschlagen im falschen Wallet).
    onKeyRefChanged: {
        _keyState = ""
        _key = ""
        _keyWaiters = []
    }

    // Schlüssel auflösen (genau einmal, dann gecacht). Fehler (Wallet zu)
    // werden NICHT gecacht — der nächste Request versucht es erneut. Die
    // Aufrufer (refreshModels/chat/embed) warten über den Callback, damit
    // kein Request ohne den Header losläuft, den er braucht.
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
            // Erst die Wartenden, dann der Auslöser — keiner darf leer
            // ausgehen, auch wenn weitere Anfragen während des Ladens kamen.
            var waiters = _keyWaiters
            _keyWaiters = []
            for (var i = 0; i < waiters.length; i++) waiters[i](_key)
            if (callback) callback(_key)
        })
    }

    // Header-Block; nur wenn ein Schlüssel bekannt ist (kein Empty-Bearer).
    function _authHeaders() {
        return (_key !== "") ? ({ "Authorization": "Bearer " + _key }) : ({})
    }

    function refreshModels(callback) {
        _resolveKey(function() {
            if (baseUrl === "") {
                client.models = []
                if (callback) callback([])
                return
            }
            http.getJson(baseUrl + "/v1/models", function(res) {
                if (!res.ok) {
                    client.models = []
                    if (callback) callback([])
                    return
                }
                var list = (res.data && res.data.data) || []
                var fresh = []
                for (var i = 0; i < list.length; i++) {
                    var m = list[i]
                    var name = m.id || ""
                    if (name === "" || name.indexOf("embed") !== -1) continue
                    // Metadaten für Picker (Kontextlänge) und Bild-Ausgabe
                    // (modalities-Anfrage): fehlen bei manchen Servern
                    // (llama-server) — dann 0/false.
                    var outMod = (m.architecture && m.architecture.output_modalities)
                        ? m.architecture.output_modalities : []
                    fresh.push({ "name": name, "sizeGB": 0,
                                 "loaded": false, "digest": "",
                                 "contextLength": m.context_length || 0,
                                 "imageOutput": outMod.indexOf("image") !== -1 })
                }
                client.models = fresh
                if (callback) callback(fresh)
            }, 0, client._authHeaders())
        })
    }

    // Ohne Server-Abfrage: die konfigurierte Annahme (leere baseUrl -> nichts).
    function capabilities(model, callback) {
        callback(baseUrl === "" ? [] : defaultCapabilities)
    }

    // Kein Äquivalent in der OpenAI-API — llama-server hält sein Modell ohnehin
    // dauerhaft geladen. Erfolg melden, damit der ModelManager weiterläuft.
    function preload(model, callback) {
        if (callback) callback(true)
    }

    function setKeepAlive(model, duration) { /* kein Äquivalent */ }

    // Aurora spricht intern Ollama-Optionen; OpenAI nimmt die Sampling-Werte auf
    // Top-Level. num_ctx bleibt außen vor: die Kontextgröße ist beim
    // llama-server ein Startparameter (-c), kein Request-Feld.
    function _mapOptions(payload, options) {
        if (!options) return
        if (options.temperature !== undefined) payload.temperature = options.temperature
        if (options.top_p !== undefined) payload.top_p = options.top_p
        if (options.top_k !== undefined) payload.top_k = options.top_k
        if (options.num_predict !== undefined) payload.max_tokens = options.num_predict
        if (options.seed !== undefined) payload.seed = options.seed
        if (options.stop !== undefined) payload.stop = options.stop
    }

    // Anhänge: Aurora transportiert sie im Ollama-Format (message.images als
    // Base64-Liste, ohne MIME). OpenAI nimmt ein content-Array mit text- und
    // image_url-Teilen. Mapping hier (Backend-Sache), damit der ChatController
    // eine gemeinsame Historie für beide Welten hält. Das Original wird nie
    // mutiert — der ChatController nutzt es weiter im Ollama-Format. MIME beim
    // data-Prefix: Ollama kennt keins; dpng ist der von Vision-APIs am besten
    // akzeptierte Default (die meisten Server snüffeln die Bytes).
    function _mapMessages(messages) {
        if (!messages) return messages
        var out = []
        for (var i = 0; i < messages.length; i++) {
            var m = messages[i]
            var imgs = m.images
            var istString = (typeof m.content === "string")
            if (!imgs || imgs.length === 0 || !istString) {
                out.push(m)
                continue
            }
            var parts = []
            if (m.content !== "") parts.push({ "type": "text", "text": m.content })
            for (var j = 0; j < imgs.length; j++)
                parts.push({ "type": "image_url",
                             "image_url": { "url": "data:image/png;base64," + imgs[j] } })
            var n = {}
            for (var k in m) {
                if (k !== "images" && k !== "content") n[k] = m[k]
            }
            n.content = parts
            out.push(n)
        }
        return out
    }

    function chat(request) {
        var payload = {
            "model": request.model,
            "messages": _mapMessages(request.messages),
            "stream": true
        }
        if (request.tools && request.tools.length > 0) payload.tools = request.tools
        _mapOptions(payload, request.options)
        var job = _jobFactory.createObject(client, {
            "httpRef": http,
            "streamFactory": sseFactory,
            "url": baseUrl + "/v1/chat/completions",
            "payload": payload,
            "fetchCost": keyRef !== ""   // nur Cloud: Kosten-Stats nachladen
        })
        // Der Job wird sofort zurückgegeben (Signale können schon verbunden
        // werden); gestartet wird erst, wenn der Schlüssel da ist — kein
        // Request ohne Auth-Header. Ohne keyRef bzw. mit synchronem KeyRing
        // (Tests) passiert das unmittelbar.
        _resolveKey(function() {
            job.headers = client._authHeaders()
            job.start()
        })
        return job
    }

    // /v1/embeddings liefert data[].embedding; wir nehmen den ersten Vektor.
    // Best-effort wie beim OllamaClient: bei Fehler/leer callback(null).
    function embed(model, input, callback) {
        _resolveKey(function() {
            if (baseUrl === "") { if (callback) callback(null); return }
            http.postJson(baseUrl + "/v1/embeddings", { "model": model, "input": input },
                function(res) {
                    var arr = (res.ok && res.data && res.data.data) || []
                    var vec = (arr.length > 0 && arr[0].embedding) ? arr[0].embedding : null
                    if (callback) callback(vec)
                }, 20000, client._authHeaders())
        })
    }
}
