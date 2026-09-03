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
                    // Reasoning-Fähigkeiten (P-C): supported_efforts,
                    // default_effort, mandatory — für /effort-Validierung und
                    // Tuner. Fehlen ohne Metadaten.
                    var rsn = m.reasoning || {}
                    fresh.push({ "name": name, "sizeGB": 0,
                                 "loaded": false, "digest": "",
                                 "contextLength": m.context_length || 0,
                                 "imageOutput": outMod.indexOf("image") !== -1,
                                 "efforts": rsn.supported_efforts || [],
                                 "defaultEffort": rsn.default_effort || "",
                                 "thinkingMandatory": rsn.mandatory === true })
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
    // P-D: auch frequency/presence_penalty, top_a, logit_bias, logprobs und
    // response_format — vorher wurden sie still verschluckt.
    function _mapOptions(payload, options) {
        if (!options) return
        if (options.temperature !== undefined) payload.temperature = options.temperature
        if (options.top_p !== undefined) payload.top_p = options.top_p
        if (options.top_k !== undefined) payload.top_k = options.top_k
        if (options.num_predict !== undefined) payload.max_tokens = options.num_predict
        if (options.seed !== undefined) payload.seed = options.seed
        if (options.stop !== undefined) payload.stop = options.stop
        if (options.frequency_penalty !== undefined) payload.frequency_penalty = options.frequency_penalty
        if (options.presence_penalty !== undefined) payload.presence_penalty = options.presence_penalty
        if (options.top_a !== undefined) payload.top_a = options.top_a
        if (options.logit_bias !== undefined) payload.logit_bias = options.logit_bias
        if (options.logprobs !== undefined) payload.logprobs = options.logprobs
        if (options.top_logprobs !== undefined) payload.top_logprobs = options.top_logprobs
        // response_format als Enum ("json"/"json_object") -> OpenAI-Objekt
        if (options.response_format !== undefined) {
            if (options.response_format === "json" || options.response_format === "json_object")
                payload.response_format = { "type": "json_object" }
            else if (options.response_format === "json_schema")
                payload.response_format = { "type": "json_schema" }
            else
                payload.response_format = options.response_format   // bereits Objekt
        }
    }

    // Anhänge: Aurora transportiert sie im Ollama-Format (message.images als
    // Base64-Liste, ohne MIME). OpenAI nimmt ein content-Array mit text- und
    // image_url-Teilen. Mapping hier (Backend-Sache), damit der ChatController
    // eine gemeinsame Historie für beide Welten hält. Das Original wird nie
    // mutiert — der ChatController nutzt es weiter im Ollama-Format. MIME beim
    // data-Prefix: Ollama kennt keins; dpng ist der von Vision-APIs am besten
    // akzeptierte Default (die meisten Server snüffeln die Bytes).
    //
    // Audio-Anhang: message.audio (base64, wav) -> input_audio-Part. Format
    // live gegen die API verifiziert (2026-09, freies nemotron-nano-omni).
    function _mapMessages(messages) {
        if (!messages) return messages
        var out = []
        for (var i = 0; i < messages.length; i++) {
            var m = messages[i]
            var imgs = m.images
            var audio = m.audio
            var istString = (typeof m.content === "string")
            var isMulti = (imgs && imgs.length > 0 || audio) && istString
            if (!isMulti) {
                out.push(m)
                continue
            }
            var parts = []
            if (m.content !== "") parts.push({ "type": "text", "text": m.content })
            if (imgs) {
                for (var j = 0; j < imgs.length; j++)
                    parts.push({ "type": "image_url",
                                 "image_url": { "url": "data:image/png;base64," + imgs[j] } })
            }
            if (audio)
                parts.push({ "type": "input_audio",
                             "input_audio": { "data": audio, "format": "wav" } })
            var n = {}
            for (var k in m) {
                if (k !== "images" && k !== "content" && k !== "audio") n[k] = m[k]
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
        // P-B: Reasoning pro Anfrage. OpenRouter versteht reasoning.enabled (map)
        // + reasoning_effort (Top-Level, OpenAI-Stil); llama-server akzeptiert
        // reasoning_effort pro Request (llama.cpp-Doku). Effort leer -> nicht senden.
        if (request.reasoning) {
            payload.reasoning = { "enabled": request.reasoning.enabled === true }
            if (request.reasoning.effort !== undefined && request.reasoning.effort !== "")
                payload.reasoning_effort = request.reasoning.effort
        }
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

    // llama-server im Router-Modus: Modell gezielt entladen (VRAM freigeben), damit
    // beim Wechsel zu Ollama nur EIN lokales Modell geladen bleibt. Best-effort:
    // Fehler (Server ohne Router-Support) werden gemeldet, blockieren aber nie.
    // callback({ok, error?})
    function unloadModel(model, callback) {
        _resolveKey(function() {
            if (baseUrl === "") {
                if (callback) callback({ "ok": false, "error": "kein Backend" })
                return
            }
            http.postJson(baseUrl + "/models/unload", { "model": model },
                function(res) {
                    if (callback) callback({ "ok": res.ok,
                                             "error": res.ok ? "" : (res.error || ("HTTP " + res.status)) })
                }, 15000, client._authHeaders())
        })
    }

    // Bildgenerierung über ein Bild-Ausgabe-Modell (OpenRouter). NON-Streaming:
    // so dokumentiert (message.images[].image_url.url als data-URL) — die
    // SSE-Struktur für Bilder ist offiziell nicht spezifiziert, also nicht
    // erraten. request: {model, prompt}; callback({ok, images:[dataUrl,...],
    // error?}).
    function generateImage(request, callback) {
        _resolveKey(function() {
            if (baseUrl === "") { if (callback) callback({ "ok": false, "images": [], "error": "kein Backend" }); return }
            http.postJson(baseUrl + "/v1/chat/completions",
                { "model": request.model,
                  "messages": [{ "role": "user", "content": request.prompt }],
                  "stream": false,
                  "modalities": ["image", "text"] },
                function(res) {
                    var urls = []
                    var ok = res.ok && res.data
                    if (ok) {
                        var msg = (res.data.choices && res.data.choices[0]
                                   && res.data.choices[0].message)
                            ? res.data.choices[0].message : null
                        var imgs = (msg && msg.images) || []
                        for (var i = 0; i < imgs.length; i++) {
                            var u = imgs[i].image_url && imgs[i].image_url.url
                            if (u) urls.push(u)
                        }
                    }
                    if (callback) callback({ "ok": ok,
                                             "images": urls,
                                             "error": ok ? "" : (res.error || "HTTP " + res.status) })
                }, 120000, client._authHeaders())
        })
    }
}
