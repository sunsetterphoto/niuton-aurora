import QtQml
import net.niuton.aurora.core as Core

// Client der App-API des Aurora-Servers für den Cloud-Rechner (API.md §15):
//
//   GET    /api/v1/me                      -> Konto {username, displayName, tier, features:{box}, device, previewDomain}
//   GET    /api/v1/box                     -> Zustand · POST /box/wake
//   POST   /api/v1/box/exec {cmd,cwd?,timeoutS?} -> text/event-stream: out {stream,data} …,
//                                             dann GENAU EINES von end {exitCode,timedOut,truncated} | error {code,message}
//   GET    /api/v1/box/files?path=         -> {path, entries}
//   GET|PUT|DELETE /api/v1/box/file?path=  -> Datei (roh) · POST /box/dir?path=
//   GET    /api/v1/box/previews · PUT /box/previews/{app} {port} · POST /box/previews/{name}/open -> {url}
//   POST   /api/v1/box/screenshot {url}    -> image/png
//
// Anmeldung mit einem Geräte-Schlüssel (Authorization: Bearer nk_…). Der
// Schlüssel liegt im KWallet (KeyRing, Eintrag "cloudbox"; Env-Rückfall
// AURORA_CLOUDBOX_KEY) und wird einmal aufgelöst; nach 401/„unauthorized"
// wird der Cache verworfen (Schlüssel evtl. inzwischen ersetzt).
//
// Ergebnisse: cb({ok:true, …}) oder cb({ok:false, error:{status, code, message,
// retryAfterS}}); status 0 = keine HTTP-Antwort (code "unreachable"/"timeout"),
// eigene codes: "no_key", "not_configured", "invalid_endpoint", "stream_broken",
// "bad_response". Der Schlüssel taucht nie in Fehlermeldungen auf.
QtObject {
    id: client

    property string endpoint: ""
    property var http: Core.Http
    property var keyring: Core.KeyRing
    property string keyRef: "cloudbox"
    property Component streamFactory: Component { Core.NdjsonStream { sse: true } }
    property int timeoutMs: 30000
    // Leerlauf-Grenze des exec-Stroms; 0 = automatisch (Befehls-Zeitlimit + 60 s).
    // Nur Tests setzen das kürzer.
    property int execIdleTimeoutMs: 0
    // Zuletzt bekannte Vorschau-Domain (aus me()); leer = unbekannt.
    property string previewDomain: ""

    readonly property string base: _normalize(endpoint) + "/api/v1"
    readonly property bool configured: _normalize(endpoint) !== ""

    property string _keyState: ""     // "" | "loading" | "done"
    property string _key: ""
    property var _keyWaiters: []

    onEndpointChanged: previewDomain = ""
    onKeyRefChanged: resetKey()

    function _normalize(ep) {
        var s = String(ep || "").trim()
        while (s.length > 0 && s.charAt(s.length - 1) === "/") s = s.substring(0, s.length - 1)
        return s
    }

    // Schlüssel neu lesen lassen (Einstellungen haben ihn geändert/gelöscht).
    function resetKey() {
        _keyState = ""
        _key = ""
        _keyWaiters = []
    }

    function _err(status, code, message, retryAfterS) {
        var e = { "status": status || 0, "code": code, "message": message || code }
        if (retryAfterS !== undefined && retryAfterS !== null) e.retryAfterS = retryAfterS
        return e
    }

    function _resolveKey(callback) {
        if (_keyState === "done") { callback(_key); return }
        _keyWaiters.push(callback)
        if (_keyState === "loading") return
        _keyState = "loading"
        keyring.readSecret(keyRef, function(res) {
            client._key = (res && res.ok && res.secret) ? String(res.secret).trim() : ""
            client._keyState = (client._key !== "") ? "done" : ""
            var waiters = client._keyWaiters
            client._keyWaiters = []
            for (var i = 0; i < waiters.length; i++) waiters[i](client._key)
        })
    }

    // Prüft Adresse + Schlüssel und ruft fn(base, key) — sonst fail(error).
    // opts.endpoint/opts.key übersteuern (Verbindung prüfen vor dem Speichern).
    function _prepare(opts, fail, fn) {
        var ep = _normalize((opts && opts.endpoint !== undefined) ? opts.endpoint : endpoint)
        if (ep === "") { fail(_err(0, "not_configured", "Keine Server-Adresse eingetragen.")); return }
        if (!/^https?:\/\/[^\/\s]+/.test(ep)) {
            fail(_err(0, "invalid_endpoint", "Die Server-Adresse muss mit https:// beginnen."))
            return
        }
        var withKey = function(key) {
            if (!key) { fail(_err(0, "no_key", "Kein Geräte-Schlüssel eingetragen.")); return }
            fn(ep + "/api/v1", key)
        }
        var override = (opts && opts.key !== undefined) ? String(opts.key || "").trim() : null
        if (override !== null) withKey(override)
        else _resolveKey(withKey)
    }

    function _noteAuthError(e) {
        if (e && (e.status === 401 || e.code === "unauthorized" || e.code === "device_unauthorized"))
            resetKey()
    }

    // Http.request-Ergebnis -> Fehlerobjekt (oder null bei Erfolg)
    function _errorOf(res) {
        if (res && res.ok) return null
        if (!res) return _err(0, "unreachable", "Der Server ist nicht erreichbar.")
        if (res.error === "too_large") return _err(413, "too_large", "Die Datei ist zu groß.")
        // Zeitlimit auch nach schon empfangenen Kopfzeilen (Server hängt im Körper)
        if (res.error === "timeout")
            return _err(0, "timeout", "Zeitüberschreitung — der Server hat nicht rechtzeitig geantwortet.")
        if (!res.status) {
            return _err(0, "unreachable", "Der Server ist nicht erreichbar (" + (res.error || "keine Verbindung") + ").")
        }
        var body = (res.data && typeof res.data === "object") ? res.data.error : null
        if (body && typeof body === "object")
            return _err(res.status, body.code || ("http_" + res.status),
                        body.message || ("HTTP " + res.status), body.retryAfterS)
        if (res.status >= 200 && res.status < 300)
            return _err(0, "stream_broken", "Die Verbindung zum Server ist abgerissen (" + (res.error || "unvollständig") + ").")
        return _err(res.status, "http_" + res.status, "HTTP " + res.status)
    }

    // Gemeinsamer Ablauf aller Nicht-Strom-Aufrufe.
    function _call(path, req, opts, cb, map) {
        var fail = function(e) { client._noteAuthError(e); if (cb) cb({ "ok": false, "error": e }) }
        _prepare(opts, fail, function(baseUrl, key) {
            var o = {
                "method": req.method || "GET",
                "url": baseUrl + path,
                "headers": { "Authorization": "Bearer " + key },
                "timeoutMs": req.timeoutMs || client.timeoutMs
            }
            if (req.body !== undefined) o.body = req.body
            if (req.contentType) o.contentType = req.contentType
            if (req.maxBytes) o.maxBytes = req.maxBytes
            if (req.saveTo) o.saveTo = req.saveTo
            client.http.request(o, function(res) {
                var e = client._errorOf(res)
                if (e) { fail(e); return }
                var out = map ? map(res) : ({})
                if (out && out.error) { fail(out.error); return }
                out.ok = true
                if (cb) cb(out)
            })
        })
    }

    function _q(p) { return encodeURIComponent(String(p || "")) }

    function _preview(o) {
        o = o || {}
        return { "name": o.name || "", "url": o.url || "", "port": o.port || 0, "tlsReady": o.tlsReady === true }
    }

    // ---------- Konto / Zustand ----------

    // cb({ok, me:{username, displayName, tier, box, deviceName, previewDomain}})
    function me(cb, opts) {
        _call("/me", { "timeoutMs": 15000 }, opts, cb, function(res) {
            var d = res.data || {}
            var m = { "username": d.username || "", "displayName": d.displayName || d.username || "",
                      "tier": d.tier || "", "box": !!(d.features && d.features.box),
                      "deviceName": (d.device && d.device.name) || "", "previewDomain": d.previewDomain || "" }
            // Nur für die eigene Adresse merken, nicht für eine Probe mit anderer
            if (m.previewDomain !== "" && !(opts && opts.endpoint !== undefined
                                            && client._normalize(opts.endpoint) !== client._normalize(client.endpoint)))
                client.previewDomain = m.previewDomain
            return { "me": m }
        })
    }

    function status(cb) { _call("/box", {}, null, cb, function(res) { return { "box": res.data || {} } }) }
    function wake(cb) { _call("/box/wake", { "method": "POST" }, null, cb) }

    // ---------- Dateien ----------

    function list(path, cb) {
        _call("/box/files?path=" + _q(path), {}, null, cb, function(res) {
            var d = res.data || {}
            return { "path": d.path || "", "entries": d.entries || [] }
        })
    }

    // cb({ok, text, binary, size}); mehr als maxBytes -> too_large
    function read(path, cb, maxBytes) {
        _call("/box/file?path=" + _q(path), { "timeoutMs": 120000, "maxBytes": maxBytes || 2000000 }, null, cb,
              function(res) { return { "text": res.text || "", "binary": res.binary === true, "size": res.size || 0 } })
    }

    function write(path, content, cb) {
        _call("/box/file?path=" + _q(path), { "method": "PUT", "body": String(content === undefined ? "" : content),
                                              "contentType": "application/octet-stream", "timeoutMs": 120000 }, null, cb)
    }

    function remove(path, cb) { _call("/box/file?path=" + _q(path), { "method": "DELETE" }, null, cb) }
    function mkdir(path, cb) { _call("/box/dir?path=" + _q(path), { "method": "POST" }, null, cb) }

    // ---------- Vorschau ----------

    function previews(cb) {
        _call("/box/previews", {}, null, cb, function(res) {
            var list = (res.data && res.data.previews) || []
            var out = []
            for (var i = 0; i < list.length; i++) out.push(client._preview(list[i]))
            return { "previews": out }
        })
    }

    // name = App-Name (leer -> "app"); der echte Vorschau-Name steht im Ergebnis.
    function preview(port, name, cb) {
        var app = String(name || "").trim() || "app"
        _call("/box/previews/" + _q(app), { "method": "PUT", "body": { "port": port } }, null, cb,
              function(res) { return { "preview": client._preview(res.data) } })
    }

    // Einmalige Adresse (60 s gültig, an das Netz dieses Rechners gebunden).
    function openPreview(name, cb) {
        _call("/box/previews/" + _q(name) + "/open", { "method": "POST" }, null, cb, function(res) {
            var url = res.data && res.data.url
            if (!url) return { "error": client._err(502, "bad_response", "Unerwartete Antwort des Servers.") }
            return { "url": url }
        })
    }

    function deletePreview(name, cb) { _call("/box/previews/" + _q(name), { "method": "DELETE" }, null, cb) }

    // PNG nach destPath; prüft die PNG-Signatur.
    function screenshot(url, destPath, cb) {
        _call("/box/screenshot", { "method": "POST", "body": { "url": url }, "saveTo": destPath, "timeoutMs": 150000 },
              null, cb, function(res) {
            if (String(res.head || "").indexOf("89504e47") !== 0)
                return { "error": client._err(502, "bad_response", "Screenshot ist kein PNG.") }
            return { "path": res.path || destPath }
        })
    }

    // ---------- Befehl als Strom ----------

    // handlers: {onOut(stream, data), onEnd({exitCode, timedOut, truncated}), onError(error)}.
    // Genau EIN Abschluss (onEnd ODER onError), auch bei abgerissener Verbindung.
    // Rückgabe: {abort()} — Abbruch ist still (kein Abschluss-Callback).
    function exec(cmd, opts, handlers) {
        opts = opts || {}
        handlers = handlers || {}
        var t = parseInt(opts.timeoutS)
        if (!(t > 0)) t = 120
        t = Math.max(1, Math.min(900, t))
        var state = { "done": false, "stream": null, "errBody": null }
        var finish = function(kind, value) {
            if (state.done) return
            state.done = true
            if (kind === "error") {
                client._noteAuthError(value)
                if (handlers.onError) handlers.onError(value)
            } else if (handlers.onEnd) {
                handlers.onEnd(value)
            }
        }
        var handle = {
            "abort": function() {
                state.done = true
                if (state.stream) { state.stream.abort(); state.stream.destroy(); state.stream = null }
            }
        }
        _prepare(null, function(e) { finish("error", e) }, function(baseUrl, key) {
            if (state.done) return          // vor dem Start abgebrochen
            var body = { "cmd": String(cmd || ""), "timeoutS": t }
            if (opts.cwd) body.cwd = String(opts.cwd)
            // Stille Befehle senden lange nichts: Leerlauf bis über das Zeitlimit hinaus erlauben
            var s = client.streamFactory.createObject(client, { "sse": true, "idleTimeoutMs": client.execIdleTimeoutMs > 0 ? client.execIdleTimeoutMs : (t + 60) * 1000 })
            state.stream = s
            s.objectReceived.connect(function(o) {
                if (state.done || !o) return
                if (o.error && typeof o.error === "object") { state.errBody = o.error; return }   // Fehlerkörper (HTTP-Status)
                if (o.stream !== undefined) {
                    if (handlers.onOut) handlers.onOut(String(o.stream), String(o.data === undefined ? "" : o.data))
                } else if (o.exitCode !== undefined || o.timedOut !== undefined) {
                    finish("end", { "exitCode": (o.exitCode === undefined || o.exitCode === null) ? null : o.exitCode,
                                    "timedOut": o.timedOut === true, "truncated": o.truncated === true })
                } else if (o.code !== undefined) {
                    finish("error", client._err(0, String(o.code), o.message || String(o.code), o.retryAfterS))
                }
            })
            s.finished.connect(function(ok, httpStatus, error) {
                if (state.stream !== s) return      // abgebrochen: still bleiben
                state.stream = null
                s.destroy()
                if (state.done) return
                if (httpStatus && (httpStatus < 200 || httpStatus >= 300)) {
                    var b = state.errBody
                    finish("error", b ? client._err(httpStatus, b.code || ("http_" + httpStatus), b.message || ("HTTP " + httpStatus), b.retryAfterS)
                                      : client._err(httpStatus, "http_" + httpStatus, "HTTP " + httpStatus))
                } else if (error === "timeout") {
                    finish("error", client._err(0, "timeout", "Zeitüberschreitung — vom Server kam zu lange nichts."))
                } else if (!httpStatus) {
                    finish("error", client._err(0, "unreachable", "Der Server ist nicht erreichbar (" + (error || "keine Verbindung") + ")."))
                } else {
                    finish("error", client._err(0, "stream_broken", "Die Verbindung zum Server ist abgerissen ("
                                                + (ok ? "Ausgabe unvollständig" : (error || "Fehler")) + ")."))
                }
            })
            s.post(baseUrl + "/box/exec", body, { "Authorization": "Bearer " + key })
        })
        return handle
    }
}
