import QtQml
import net.niuton.aurora.core as Core

// Modell-Verwaltung (Spec 3.2): Auto-Modus über das Power-Profil,
// LAN/WLAN-Probe (niedrigster Listen-Index gewinnt), Auswahl-Persistenz
// über den Settings-Adapter, pickerEntries für den Header.
QtObject {
    id: mgr

    // Injektion (Tests: Mocks)
    property var settings: null            // AuroraSettings (Pflicht)
    property var fileio: Core.FileIO
    property var http: Core.Http
    // Schlüssel-Primitive für Cloud-Backends (Tests: Mock statt KWallet)
    property var keyring: Core.KeyRing
    onHttpChanged: {
        localClient.http = http
        remoteClient.http = http
        for (var id in _extraClients) _extraClients[id].http = http
    }

    property string localEndpoint: "http://127.0.0.1:11434"
    property bool active: false            // Widget offen → Profil-Polling

    // Ein OllamaClient pro Backend (Spec 3.2)
    property OllamaClient localClient: OllamaClient {
        baseUrl: mgr.localEndpoint
        http: mgr.http
        twoPhaseToolCalls: mgr.settings ? mgr.settings.twoPhaseToolCalls : false
    }
    property OllamaClient remoteClient: OllamaClient {
        baseUrl: ""
        http: mgr.http
        twoPhaseToolCalls: mgr.settings ? mgr.settings.twoPhaseToolCalls : false
    }

    // Weitere Backends aus der Registry (alles außer dem lokalen Ollama und
    // den LAN-Ollamas, die über die Probe an remoteClient gehen). Pro Backend
    // eine Instanz der zu seiner Sorte passenden Client-Klasse.
    property Component _openaiFactory: Component { OpenAiClient {} }
    property var _extraClients: ({})       // backendId -> Client

    readonly property var backends: settings ? settings.backends : []
    onBackendsChanged: _syncExtraClients()

    // Zustand (UI liest)
    property string selectedModel: "auto"  // "auto" | "<backendId>:<n>" | "remote:<n>"
    property string activeModel: ""
    // Welches Backend bedient activeModel. "local" = der lokale Ollama.
    property string activeBackendId: "local"
    // isRemote heißt weiterhin "nicht der lokale Ollama" — davon hängen
    // keep_alive und scheduleUnload ab: jedes andere Backend verwaltet seinen
    // Speicher selbst.
    readonly property bool isRemote: activeBackendId !== "local"
    // Verlässt der aktive Zug das Haus? Steuert Kennzeichnung in der UI.
    readonly property bool isCloudActive: {
        var b = _backendById(activeBackendId)
        return b ? b.cloud === true : false
    }
    property bool modelLoaded: false
    property bool modelLoading: false
    property string powerProfile: ""
    property bool autoModeAvailable: true
    property bool remoteAvailable: false
    property var activeCaps: []

    readonly property var localModels: localClient.models
    readonly property var remoteModels: remoteClient.models

    property int _remoteWinnerIndex: -1
    property int _probeEpoch: 0            // verwirft späte Antworten alter Proben
    property int _probePending: 0          // noch offene Antworten der aktuellen Epoche (Task 3)
    property string _loadingModel: ""      // Modell des laufenden Preloads (Audit-Fix Doppel-Preload)

    property Timer _profileTimer: Timer {
        interval: 30000
        repeat: true
        running: mgr.active
        onTriggered: mgr.checkPowerProfile()
    }

    // Live-Sync mit dem Modell-Store (KCM): nach Pull/Remove bumped der Store
    // den internen Key "modelsRevision" → hier neu proben, sonst bliebe der
    // Header-Picker im Panel-Widget (aktiviert nie neu) bis zum
    // plasmashell-Restart stale. Wert-Vergleich: revisionChanged feuert bei
    // JEDER Config-Änderung — nur bei echtem modelsRevision-Wechsel proben.
    // active-Guard: inaktive Manager proben nicht (refresh() holt die Probe
    // beim nächsten activate() nach) — verhindert auch, dass ein sterbender
    // Manager (destroy() ist deferred) auf Config-Reset/Writes noch Requests
    // absetzt.
    property string _modelsRev: String(Core.ConfigStore.value("modelsRevision") || "")
    property Connections _cfgWatch: Connections {
        target: Core.ConfigStore
        function onRevisionChanged() {
            if (!mgr.active) return
            var v = String(Core.ConfigStore.value("modelsRevision") || "")
            if (v !== mgr._modelsRev) {
                mgr._modelsRev = v
                mgr.probeBackends()
            }
        }
    }

    // Gruppierte Einträge für den Model-Picker (Struktur wie bisher,
    // plus enabled-Feld: Auto ohne Energieprofil ist deaktiviert)
    readonly property var pickerEntries: {
        var e = [{ "label": autoModeAvailable
                       ? "Auto (Energieprofil)"
                       : "Auto (Energieprofil nicht verfügbar)",
                   "value": "auto", "kind": "auto", "enabled": autoModeAvailable }]
        var lm = localClient.models
        if (lm.length > 0)
            e.push({ "label": "Lokal", "value": "", "kind": "header", "enabled": false })
        for (var i = 0; i < lm.length; i++)
            e.push({ "label": (lm[i].loaded ? "● " : "") + lm[i].name + " (" + lm[i].sizeGB + " GB)",
                     "value": "local:" + lm[i].name, "kind": "local", "enabled": true })
        var rm = remoteClient.models
        if (rm.length > 0)
            e.push({ "label": "Remote 🌐", "value": "", "kind": "header", "enabled": false })
        for (var j = 0; j < rm.length; j++)
            e.push({ "label": (rm[j].loaded ? "● " : "") + rm[j].name + " (" + rm[j].sizeGB + " GB)",
                     "value": "remote:" + rm[j].name, "kind": "remote", "enabled": true })
        // Weitere Backends in Registry-Reihenfolge. Ohne Größenangabe: die
        // OpenAI-API kennt weder Dateigröße noch Ladezustand. Cloud-Backends
        // tragen die Wolke im Gruppentitel — wer Daten aus dem Haus gibt, soll
        // das im Picker sehen.
        for (var bi = 0; bi < backends.length; bi++) {
            var b = backends[bi]
            if (!_isExtra(b)) continue
            var c = _extraClients[b.id]
            if (!c || c.models.length === 0) continue
            e.push({ "label": b.cloud ? (b.label + " ☁") : b.label,
                     "value": "", "kind": "header", "enabled": false })
            for (var mi = 0; mi < c.models.length; mi++)
                e.push({ "label": c.models[mi].name,
                         "value": b.id + ":" + c.models[mi].name,
                         "kind": b.cloud ? "cloud" : "extra", "enabled": true })
        }
        return e
    }

    function _backendById(id) {
        for (var i = 0; i < backends.length; i++)
            if (backends[i].id === id) return backends[i]
        return null
    }

    // Ein Backend geht über remoteClient, wenn es ein Ollama im Netz ist —
    // dafür gibt es die bestehende Epochen-Probe. Alles andere bekommt eine
    // eigene, dauerhafte Client-Instanz.
    function _isExtra(b) { return b.id !== "local" && b.kind !== "ollama" }

    function _syncExtraClients() {
        var cur = _extraClients
        var soll = {}
        for (var i = 0; i < backends.length; i++)
            if (_isExtra(backends[i])) soll[backends[i].id] = backends[i]
        // Entfallene Backends abräumen, sonst proben tote Clients weiter.
        for (var id in cur) {
            if (!soll[id]) {
                if (cur[id]) cur[id].destroy()
                delete cur[id]
            }
        }
        // Vorhandene Clients nachziehen, neue anlegen. keyring wird hier
        // immer aktualisiert (wie http über onHttpChanged): die Registry kann
        // den Backends-Wechsel auslösen, bevor eine neu injizierte Primitive
        // gesetzt war — sonst bliebe der alte (echte) KeyRing stehen.
        for (var sid in soll) {
            var b = soll[sid]
            if (cur[sid]) {
                cur[sid].baseUrl = b.endpoint
                cur[sid].http = mgr.http
                cur[sid].keyring = mgr.keyring
                // keyRef aus der Registry nachziehen (Cloud-Backends)
                if (b.keyRef) cur[sid].keyRef = b.keyRef
            } else {
                cur[sid] = _openaiFactory.createObject(mgr, {
                    "baseUrl": b.endpoint, "http": mgr.http,
                    "keyring": mgr.keyring, "keyRef": b.keyRef || "" })
            }
        }
        _extraClients = cur
    }

    // Der Client, der ein bestimmtes Backend bedient (null, wenn unbekannt).
    function clientFor(id) {
        if (id === "local") return localClient
        if (_extraClients[id]) return _extraClients[id]
        // LAN-Ollamas laufen über den Probe-Gewinner.
        return (remoteClient.baseUrl !== "") ? remoteClient : null
    }

    function refresh() {
        _syncExtraClients()
        applySavedModel()
        checkPowerProfile()
        probeBackends()
    }

    // Audit-Fix Task 3 (Fast-Follow): probeBackends() leert remoteClient.baseUrl
    // SOFORT beim Epochen-Start, isRemote bleibt bis zur Probe-Antwort unverändert
    // — im Bounded-Fenster isRemote===true bei leerer baseUrl fällt hier zentral
    // auf den (immer gültigen) lokalen Client zurück, statt "" + "/api/..." zu
    // bauen. chat()/embed()/preload() (und apiBase()) laufen alle über diese eine
    // Stelle. Verhalten außerhalb des Fensters (gültige remoteClient.baseUrl)
    // unverändert.
    function activeClient() {
        if (activeBackendId === "local") return localClient
        var c = clientFor(activeBackendId)
        // Guard (Audit Task 3): im Fenster zwischen Probe-Start und -Antwort
        // hat remoteClient eine leere baseUrl — dann auf den immer gültigen
        // lokalen Client ausweichen, statt "" + "/api/..." zu bauen.
        return c ? c : localClient
    }
    function apiBase() { return activeClient().baseUrl }
    function chat(request) { return activeClient().chat(request) }
    // Embedding mit Backend-Fallback: aktives Backend zuerst; liefert es null
    // (Embedding-Modell fehlt dort oder Backend down), der zweite Client —
    // RAG soll funktionieren, solange IRGENDEIN Backend das Modell hat
    // (Stand 25.07.: nomic-embed-text fehlte auf einem der beiden Backends).
    function embed(model, input, callback) {
        var first = activeClient()
        var second = (first === localClient) ? remoteClient : localClient
        first.embed(model, input, function(vec) {
            if (vec) { callback(vec); return }
            if (second.baseUrl === "") { callback(null); return }
            second.embed(model, input, callback)
        })
    }

    // ---------- Power-Profil / Auto-Modus ----------

    function _profileModel() {
        if (!settings) return ""
        if (powerProfile === "low-power") return settings.modelLowPower
        if (powerProfile === "performance") return settings.modelPerformance
        return settings.modelBalanced
    }

    function checkPowerProfile() {
        // KEIN früher Return bei fehlender Datei: der zweite if-Block ist der
        // einzige initiale Lade-Trigger im Auto-Modus und muss auch auf
        // Systemen ohne /sys/firmware/acpi/platform_profile laufen.
        var pp = fileio.readText("/sys/firmware/acpi/platform_profile", 64)
        autoModeAvailable = pp.ok
        var profile = pp.ok ? pp.text.trim() : ""
        if (profile === "low-power" || profile === "balanced" || profile === "performance") {
            powerProfile = profile
            resolveAndLoadModel()
        }
        if (selectedModel === "auto" && !modelLoaded && !modelLoading)
            resolveAndLoadModel()
    }

    function resolveAndLoadModel() {
        if (selectedModel !== "auto") return
        var newModel = _profileModel()
        if (newModel === "") return
        var prevModel = activeModel
        var prevWasLocal = !isRemote
        activeBackendId = "local"   // Auto-Modus wählt nie ein Cloud-Backend
        if (newModel !== activeModel || !modelLoaded) {
            // Vorheriges Modell nur entladen, wenn es LOKAL war — der alte
            // Code schickte den keep_alive-0 für Remote-Modelle fälschlich
            // an den lokalen Server (Alt-Bug)
            if (prevModel !== "" && modelLoaded && prevWasLocal && prevModel !== newModel)
                localClient.setKeepAlive(prevModel, "0")
            activeModel = newModel
            _preloadActive()
            _refreshActiveCaps()
        }
    }

    // ---------- Backend-Probe ----------

    function probeBackends() {
        _probeEpoch++
        var epoch = _probeEpoch
        localClient.refreshModels()
        // Weitere Backends haben je einen dauerhaften Client und stehen nicht
        // in Konkurrenz zueinander — sie brauchen die Epochen-/Gewinner-Logik
        // der Netzwerk-Probe unten nicht.
        _syncExtraClients()
        for (var id in _extraClients) _extraClients[id].refreshModels()

        var raw = (settings && settings.remoteEndpoints) ? settings.remoteEndpoints : []
        var eps = []
        for (var i = 0; i < raw.length; i++)
            if (raw[i] && eps.indexOf(raw[i]) === -1) eps.push(raw[i])

        // Jede Epoche beginnt „unbewiesen offline": Reset VOR dem Probing
        // (Audit-Fix Task 3 — Alt-Bug: ein voll fehlschlagender Re-Probe ließ
        // die Werte der letzten ERFOLGREICHEN Epoche stehen — grüner Punkt,
        // tote IP, tote Modelle im Picker, obwohl eps.length > 0 war). Nur ein
        // tatsächlicher Erfolg in _probeEndpoint setzt remoteAvailable/baseUrl
        // innerhalb dieser Epoche wieder — der Erfolgspfad selbst bleibt
        // unverändert.
        _remoteWinnerIndex = -1
        remoteAvailable = false
        remoteClient.baseUrl = ""           // Wechsel leert auch remoteClient.models
        _probePending = eps.length
        if (eps.length === 0) {
            _fallbackFromDeadRemote()
            return
        }
        for (var j = 0; j < eps.length; j++) {
            _probeEndpoint(j, eps[j], epoch)
        }
    }

    // Parallel je Endpunkt; niedrigster Index gewinnt: eine spätere Antwort
    // mit NIEDRIGEREM Index überschreibt den bisherigen Gewinner (heutige
    // LAN-überschreibt-WLAN-Logik, verallgemeinert)
    function _probeEndpoint(idx, url, epoch) {
        http.getJson(url + "/api/tags", function(res) {
            if (epoch !== mgr._probeEpoch) return
            try {
                var count = (res.ok && res.data && res.data.models)
                    ? res.data.models.length : 0
                if (count === 0) return
                if (mgr._remoteWinnerIndex !== -1 && idx >= mgr._remoteWinnerIndex) return
                mgr._remoteWinnerIndex = idx
                mgr.remoteClient.baseUrl = url          // Wechsel leert dessen Cache
                mgr.remoteAvailable = true
                mgr.remoteClient.refreshModels(function() {
                    if (epoch !== mgr._probeEpoch) return
                    mgr._applyPendingRemoteModel()
                })
            } finally {
                // Zählt IMMER (Erfolg wie Fehlschlag) — Task 3: sobald alle
                // Endpunkte dieser Epoche geantwortet haben und keiner
                // gewonnen hat, war die Probe ein Vollausfall.
                mgr._probeSettled(epoch)
            }
        })
    }

    // Alle Endpunkte der aktuellen Epoche beantwortet und keiner gewonnen
    // (remoteAvailable weiterhin false) → Vollausfall: ggf. von einem toten
    // Remote-Modell zurückfallen.
    function _probeSettled(epoch) {
        if (epoch !== _probeEpoch) return
        _probePending--
        if (_probePending <= 0 && !remoteAvailable) _fallbackFromDeadRemote()
    }

    // Kein Remote verfügbar (Probe fehlgeschlagen oder keine Endpoints
    // konfiguriert), aber ein Remote-Modell war aktiv: auf Auto/lokal
    // zurückfallen, damit chat()/embed() nie an eine leere baseUrl gehen
    // (Audit Task 3). isRemote NICHT hier selbst zurücksetzen —
    // resolveAndLoadModel() erledigt das erst NACH dem Capturing von
    // prevWasLocal (sonst Alt-Bug: keep_alive-0 für das Remote-Modell würde
    // fälschlich an den lokalen Server gehen, siehe dessen Kommentar).
    function _fallbackFromDeadRemote() {
        if (!isRemote) return
        selectedModel = "auto"
        resolveAndLoadModel()
    }

    // Gespeicherte Remote-Auswahl anwenden, sobald der Server erreichbar ist
    function _applyPendingRemoteModel() {
        var saved = settings ? settings.lastSelectedModel : ""
        if (saved.indexOf("remote:") !== 0 || selectedModel === saved) return
        var rm = remoteClient.models
        for (var i = 0; i < rm.length; i++) {
            if ("remote:" + rm[i].name === saved) {
                selectModel(saved)
                return
            }
        }
    }

    // ---------- Auswahl ----------

    function applySavedModel() {
        var saved = (settings && settings.lastSelectedModel)
            ? settings.lastSelectedModel : "auto"
        // "remote:" (Bestandsformat) wartet auf die Probe — erst danach steht
        // fest, welches Netzwerk-Backend gewonnen hat.
        if (saved.indexOf("remote:") === 0) return
        var id = _backendIdOf(saved)
        if (id !== "" && id !== "auto") {
            selectModel(saved)
        } else {
            selectedModel = "auto"
            activeBackendId = "local"
        }
    }

    // "openai:bonsai-27b" -> "openai"; "auto"/unbekannt -> "". Der Modellname
    // darf selbst Doppelpunkte tragen ("qwen3.5:9b"), deshalb nur am ERSTEN
    // trennen und nur bekannte Backend-Ids akzeptieren.
    function _backendIdOf(value) {
        var k = value.indexOf(":")
        if (k <= 0) return ""
        var id = value.substring(0, k)
        return _backendById(id) ? id : ""
    }
    function _modelNameOf(value) {
        var k = value.indexOf(":")
        return k <= 0 ? "" : value.substring(k + 1)
    }

    function selectModel(value) {
        if (settings) settings.requestPersist("lastSelectedModel", value)
        selectedModel = value
        if (value === "auto") {
            // isRemote NICHT hier zurücksetzen: resolveAndLoadModel() erledigt
            // das selbst — NACH dem Capturing von prevWasLocal. Ein Reset hier
            // würde den Guard zerstören und ein Remote-Vorgängermodell doch
            // wieder am LOKALEN Server "entladen" (genau der Alt-Bug).
            resolveAndLoadModel()
        } else if (value.indexOf("remote:") === 0) {
            // Bestandsformat: zeigt auf den Gewinner der Netzwerk-Probe.
            activeBackendId = _remoteWinnerId()
            var rname = value.substring(7)
            if (rname !== activeModel || !modelLoaded) {
                activeModel = rname
                _preloadActive()   // ehrlich vorladen — am REMOTE-Backend
            }
        } else {
            var id = _backendIdOf(value)
            if (id === "") return
            activeBackendId = id
            var name = _modelNameOf(value)
            if (name !== activeModel || !modelLoaded) {
                activeModel = name
                _preloadActive()
            }
        }
        _refreshActiveCaps()
    }

    // Die Netzwerk-Endpunkte werden aus denselben Schlüsseln gefaltet wie die
    // lan-Backends der Registry, also entspricht Probe-Index 0 der Id "lan1".
    function _remoteWinnerId() {
        return _remoteWinnerIndex <= 0 ? "lan1" : "lan2"
    }

    function _preloadActive() {
        // Audit-Fix (Klein/perf): der 30-s-Profil-Timer feuert auch, waehrend
        // ein Preload noch laeuft — fuer DASSELBE Modell keinen zweiten
        // parallelen Request starten. Ein echter Wechsel (anderes activeModel)
        // startet sehr wohl neu; der stale Callback des alten Modells wird im
        // Callback unten verworfen (m !== activeModel).
        if (modelLoading && _loadingModel === activeModel) return
        modelLoading = true
        modelLoaded = false
        var m = activeModel
        _loadingModel = m
        activeClient().preload(m, function(ok) {
            if (m !== mgr.activeModel) return   // inzwischen umgeschaltet
            mgr.modelLoading = false
            mgr.modelLoaded = true   // Parität: auch bei Fehlschlag (Status-LED wie bisher)
        })
    }

    function scheduleUnload() {
        if (isRemote) return   // Remote-Server verwaltet sich selbst
        if (activeModel === "") return
        var seconds = (settings && settings.unloadSeconds > 0)
            ? settings.unloadSeconds : 300
        localClient.setKeepAlive(activeModel, seconds + "s")
    }

    // ---------- Capabilities ----------

    function _refreshActiveCaps() {
        var m = activeModel
        activeClient().capabilities(m, function(caps) {
            if (m === mgr.activeModel) mgr.activeCaps = caps
        })
    }

    // Liefert die Caps des aktiven Modells (Cache oder frisch) und hält
    // activeCaps aktuell — Ersatz für das alte _fetchCaps(model, remote, cb)
    function withActiveCaps(callback) {
        var m = activeModel
        activeClient().capabilities(m, function(caps) {
            if (m === mgr.activeModel) mgr.activeCaps = caps
            callback(caps)
        })
    }
}
