import QtQml
import net.niuton.aurora.core as Core

// Modell-Store: Ollama-Modelle herunterladen (/api/pull, NDJSON-Fortschritt),
// entfernen (/api/delete) und installierte auflisten (/api/tags). Host-neutral
// (KCM-Seite ConfigModelStore instanziiert ihn), Primitive injizierbar (Tests:
// Mock-Http + Mock-Stream, kein echtes Netz).
QtObject {
    id: store

    property var http: Core.Http
    // Pro Pull ein frischer Stream (Abort ist pull-lokal), wie bei OllamaClient.
    property Component ndjsonFactory: Component { Core.NdjsonStream {} }

    // Laufzustand des einzigen aktiven Pulls (Single-Flight).
    property bool busy: false
    property string activeModel: ""
    property real progress: 0.0          // 0..1 über alle Layer-Digests
    property double totalBytes: 0
    property double completedBytes: 0
    property string statusText: ""

    signal pullFinished(bool ok, string error)

    property var _stream: null
    property var _digests: ({})

    // Kuratierter Katalog (sizeLabel nur, wo offiziell verifiziert — sonst
    // leer und die UI blendet die Größe aus). Freitext im UI deckt alles
    // andere ab. caps: siehe ollama.com-Modellseite.
    readonly property var catalog: [
        { "tag": "qwen3.6:35b-a3b", "titel": "Qwen 3.6 35B-A3B (MoE)",
          "sizeLabel": "24 GB", "kontext": "256K",
          "caps": ["vision", "tools", "thinking"],
          "beschreibung": "Flaggschiff mit 35B Parametern (3B aktiv) — stark bei Agentic Coding, sparsam im Verbrauch." },
        { "tag": "qwen3.6:27b", "titel": "Qwen 3.6 27B (Dense)",
          "sizeLabel": "17 GB", "kontext": "256K",
          "caps": ["vision", "tools", "thinking"],
          "beschreibung": "Kompaktes Dense-Modell mit vollem 256K-Kontext." },
        { "tag": "qwen3.5:9b", "titel": "Qwen 3.5 9B",
          "sizeLabel": "", "kontext": "",
          "caps": [],
          "beschreibung": "Bisheriges Aurora-Standardmodell im Leistungsprofil." },
        { "tag": "gemma4:e4b", "titel": "Gemma 4 E4B",
          "sizeLabel": "", "kontext": "",
          "caps": [],
          "beschreibung": "Aurora-Standard im ausgeglichenen Energieprofil." },
        { "tag": "gemma4:e2b", "titel": "Gemma 4 E2B",
          "sizeLabel": "", "kontext": "",
          "caps": [],
          "beschreibung": "Aurora-Standard im Energiesparprofil — sehr leichtgewichtig." },
        { "tag": "nomic-embed-text", "titel": "Nomic Embed Text",
          "sizeLabel": "", "kontext": "",
          "caps": ["embedding"],
          "beschreibung": "Embedding-Modell für die Wissensbasis (RAG)." }
    ]

    // Installierte Modelle eines Backends als Detail-Liste [{name, sizeGB, caps}]
    // (inkl. Embedding-Modelle — anders als OllamaClient.refreshModels wird hier
    // nichts gefiltert, der Store soll den kompletten Bestand zeigen).
    // callback(ok, entries)
    function listInstalled(baseUrl, callback) {
        http.getJson(baseUrl + "/api/tags", function(res) {
            var entries = []
            if (res.ok) {
                var list = (res.data && res.data.models) || []
                for (var i = 0; i < list.length; i++) {
                    if (!list[i].name) continue
                    entries.push({ "name": list[i].name,
                                   "sizeGB": Math.round((list[i].size || 0) / 1e8) / 10,
                                   "caps": list[i].capabilities || [] })
                }
            }
            callback(res.ok, entries)
        })
    }

    // Startet einen Pull. Single-Flight: bei laufendem Download, leerem
    // Namen oder leerer Backend-URL synchron false, sonst true (Fortschritt
    // via Properties, Ende via pullFinished).
    function pull(baseUrl, name) {
        if (busy) return false
        if (!name || name.trim() === "") return false
        if (!baseUrl || baseUrl === "") return false
        busy = true
        activeModel = name
        progress = 0
        totalBytes = 0
        completedBytes = 0
        statusText = "Starte Download …"
        _digests = {}
        // Digest-Verifizierung großer Modelle kann minutenlang ohne neue
        // Stream-Zeile laufen — Idle-Timeout weit über dem 90-s-Default.
        _stream = ndjsonFactory.createObject(store, { "idleTimeoutMs": 600000 })
        _stream.objectReceived.connect(_onPullObject)
        _stream.finished.connect(_onPullFinished)
        _stream.post(baseUrl + "/api/pull", { "name": name, "stream": true })
        return true
    }

    // Lokaler Abbruch: Ollama verwirft den Pull serverseitig beim Disconnect
    // (bereits geladene Blobs bleiben für einen späteren Resume erhalten).
    // Still: kein pullFinished — der Aufrufer hat ja selbst abgebrochen.
    function cancelPull() {
        if (!busy) return
        _dropStream()
        busy = false
        activeModel = ""
        progress = 0
        totalBytes = 0
        completedBytes = 0
        statusText = ""
    }

    // callback(ok, error)
    function remove(baseUrl, name, callback) {
        http.deleteJson(baseUrl + "/api/delete", { "name": name }, function(res) {
            if (res.ok) { callback(true, ""); return }
            var detail = (res.data && res.data.error) ? String(res.data.error) : ""
            callback(false, detail !== "" ? detail : String(res.error || ("HTTP " + res.status)))
        })
    }

    function _onPullObject(obj) {
        if (obj.error !== undefined) { _endPull(false, String(obj.error)); return }
        var st = obj.status || ""
        if (st === "success") { _endPull(true, ""); return }
        statusText = st
        if (obj.digest !== undefined && obj.total !== undefined) {
            var d = store._digests
            d[obj.digest] = { "total": obj.total, "completed": obj.completed || 0 }
            store._digests = d
            var t = 0, c = 0
            for (var k in d) { t += d[k].total; c += d[k].completed }
            totalBytes = t
            completedBytes = c
            if (t > 0) progress = Math.min(1, c / t)
        }
    }

    // Stream-Ende: nach einer success-Zeile wurde der Stream schon in
    // _endPull still verworfen — jedes finished() hier ist also ein Abbruch
    // ohne Erfolg (Netzfehler, Timeout oder vorzeitiges Ende).
    function _onPullFinished(ok, status, error) {
        if (ok) _endPull(false, "Unerwartetes Stream-Ende")
        else _endPull(false, error === "timeout" ? "Zeitüberschreitung beim Download"
                                                 : (String(error || ("HTTP " + status))))
    }

    function _endPull(ok, error) {
        _dropStream()
        busy = false
        statusText = ""
        if (ok) progress = 1
        pullFinished(ok, error)
    }

    function _dropStream() {
        if (_stream) {
            _stream.objectReceived.disconnect(_onPullObject)
            _stream.finished.disconnect(_onPullFinished)
            _stream.abort()
            _stream.destroy()
            _stream = null
        }
    }
}
