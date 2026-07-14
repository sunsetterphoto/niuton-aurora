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
    onHttpChanged: { localClient.http = http; remoteClient.http = http }

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

    // Zustand (UI liest)
    property string selectedModel: "auto"  // "auto" | "local:<n>" | "remote:<n>"
    property string activeModel: ""
    property bool isRemote: false
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

    property Timer _profileTimer: Timer {
        interval: 30000
        repeat: true
        running: mgr.active
        onTriggered: mgr.checkPowerProfile()
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
        return e
    }

    function refresh() {
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
        return (isRemote && remoteClient.baseUrl !== "") ? remoteClient : localClient
    }
    function apiBase() { return activeClient().baseUrl }
    function chat(request) { return activeClient().chat(request) }
    function embed(model, input, callback) { activeClient().embed(model, input, callback) }

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
        isRemote = false
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
        if (saved.indexOf("remote:") === 0) return   // nach erfolgreicher Probe
        if (saved.indexOf("local:") === 0) {
            selectModel(saved)
        } else {
            selectedModel = "auto"
            isRemote = false
        }
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
        } else if (value.indexOf("local:") === 0) {
            isRemote = false
            var name = value.substring(6)
            if (name !== activeModel || !modelLoaded) {
                activeModel = name
                _preloadActive()
            }
        } else if (value.indexOf("remote:") === 0) {
            isRemote = true
            var rname = value.substring(7)
            if (rname !== activeModel || !modelLoaded) {
                activeModel = rname
                _preloadActive()   // ehrlich vorladen — am REMOTE-Backend
            }
        }
        _refreshActiveCaps()
    }

    function _preloadActive() {
        modelLoading = true
        modelLoaded = false
        var m = activeModel
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
