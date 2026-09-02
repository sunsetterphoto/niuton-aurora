import QtQuick
import QtTest
import net.niuton.aurora.core
import net.niuton.aurora.engine

TestCase {
    name: "ModelManager"

    QtObject {
        id: mockHttp
        property var calls: []
        function getJson(url, cb, timeoutMs) { calls.push({ "method": "get", "url": url, "cb": cb }) }
        function postJson(url, body, cb, timeoutMs) {
            calls.push({ "method": "post", "url": url, "body": body, "cb": cb })
        }
        function answer(i, result) { if (calls[i].cb) calls[i].cb(result) }
        // Ersten noch unbeantworteten Aufruf finden, dessen URL urlPart enthält
        function find(urlPart, from) {
            for (var i = (from || 0); i < calls.length; i++)
                if (calls[i].url.indexOf(urlPart) !== -1) return i
            return -1
        }
    }

    QtObject {
        id: mockFileIO
        property var files: ({ "/sys/firmware/acpi/platform_profile": "balanced\n" })
        function readText(path, maxBytes) {
            if (files[path] !== undefined) return { "ok": true, "text": files[path] }
            return { "ok": false, "error": "not found", "text": "" }
        }
    }

    // Fake für die Schlüssel-Primitive (Cloud-Backend-Tests ohne KWallet)
    QtObject {
        id: mockKeyring
        property var reads: []
        function readSecret(keyRef, cb) {
            reads.push(keyRef)
            cb({ "ok": true, "secret": "sk-test" })
        }
    }

    // Eigene Id (nicht "settings"): ModelManager hat selbst eine Property
    // "settings" — "settings: settings" im Component unten würde sonst auf
    // die eigene (noch ungesetzte) Property zeigen statt auf dieses Objekt
    // (QML-Scoping: Objekt-eigene Properties verdecken gleichnamige Ids).
    AuroraSettings { id: testSettings }
    SignalSpy { id: persistSpy; target: testSettings; signalName: "persistRequested" }

    property var mgr: null

    Component {
        id: mgrFactory
        ModelManager {
            settings: testSettings
            fileio: mockFileIO
            http: mockHttp
            localEndpoint: "http://local:11434"
        }
    }

    function init() {
        mockHttp.calls = []
        mockKeyring.reads = []
        persistSpy.clear()
        // Sterbenden Manager VOR dem Config-Reset deaktivieren + zerstören
        // (destroy() ist deferred — ohne active=false reagiert der noch
        // lebende Manager auf die revisionChanged-Flut des reset() und
        // setzt Requests in das frische mockHttp.calls des neuen Tests ab).
        if (mgr) { mgr.active = false; mgr.destroy() }
        // ConfigStore ist ein QML_SINGLETON (nicht pro Testfunktion neu baubar) —
        // reset() ist der Isolations-Hebel (AURORA_CONFIG_PATH zeigt laut
        // CMakeLists auf eine build-lokale, testspezifische Datei). Er setzt
        // lastSelectedModel/remoteEndpoints implizit auf die Schema-Defaults
        // ("auto" bzw. [] durch die revision-Bindung in testSettings) zurück.
        ConfigStore.reset()
        mockFileIO.files = { "/sys/firmware/acpi/platform_profile": "balanced\n" }
        mgr = mgrFactory.createObject(this)
    }

    function _tags(namen) {
        var models = []
        for (var i = 0; i < namen.length; i++)
            models.push({ "name": namen[i], "size": 5000000000, "digest": "d" + i })
        return { "ok": true, "data": { "models": models } }
    }

    // Preload-Requests zaehlen (keep_alive "10m" unterscheidet sie von
    // setKeepAlive-"0"/"300s" auf demselben /api/chat-Endpunkt)
    function _preloadCount() {
        var n = 0
        for (var i = 0; i < mockHttp.calls.length; i++)
            if (mockHttp.calls[i].url.indexOf("/api/chat") !== -1
                && mockHttp.calls[i].body && mockHttp.calls[i].body.keep_alive === "10m") n++
        return n
    }

    function test_autoModusLaedtProfilModell() {
        mockFileIO.files["/sys/firmware/acpi/platform_profile"] = "performance\n"
        mgr.refresh()
        compare(mgr.powerProfile, "performance")
        compare(mgr.autoModeAvailable, true)
        compare(mgr.activeModel, "qwen3.5:9b")   // testSettings.modelPerformance
        compare(mgr.isRemote, false)
        compare(mgr.modelLoading, true)
        var i = mockHttp.find("http://local:11434/api/chat")
        verify(i !== -1)                          // preload am lokalen Backend
        compare(mockHttp.calls[i].body.model, "qwen3.5:9b")
        compare(mockHttp.calls[i].body.keep_alive, "10m")
        mockHttp.answer(i, { "ok": true })
        compare(mgr.modelLoading, false)
        compare(mgr.modelLoaded, true)
    }

    // Audit-Fix (Klein/perf): der 30-s-Profil-Timer feuert auch, waehrend ein
    // Modell noch laedt — fuer DASSELBE Modell darf kein zweiter paralleler
    // Preload-Request starten.
    function test_preloadGuardKeinDoppelterPreloadWaehrendLaden() {
        mgr.refresh()                              // balanced -> gemma4:e4b, Preload in flight
        compare(mgr.modelLoading, true)
        compare(_preloadCount(), 1)
        mgr.checkPowerProfile()                    // Timer-Tick: gleiches Profil, noch ladend
        mgr.checkPowerProfile()
        compare(_preloadCount(), 1)                // KEIN paralleler Zweit-Preload
        compare(mgr.modelLoading, true)
        mockHttp.answer(mockHttp.find("http://local:11434/api/chat"), { "ok": true })
        compare(mgr.modelLoading, false)
        compare(mgr.modelLoaded, true)
    }

    // Der Guard darf einen echten ModellWECHSEL waehrend des Ladens nicht
    // blockieren: das neue Modell wird vorgeladen, der stale Callback des alten
    // verworfen (modelLoading bleibt bis zur Antwort des NEUEN Modells true).
    function test_preloadWechselWaehrendLadenStartetNeuesModell() {
        mgr.refresh()                              // e4b-Preload in flight
        var iAlt = mockHttp.find("http://local:11434/api/chat")
        verify(iAlt !== -1)
        mockFileIO.files["/sys/firmware/acpi/platform_profile"] = "performance\n"
        mgr.checkPowerProfile()                    // Wechsel auf qwen3.5:9b, e4b laedt noch
        var iNeu = mockHttp.find("http://local:11434/api/chat", iAlt + 1)
        verify(iNeu !== -1)
        compare(mockHttp.calls[iNeu].body.model, "qwen3.5:9b")
        mockHttp.answer(iAlt, { "ok": true })      // stale Antwort des alten Modells
        compare(mgr.modelLoading, true)            // neuer Preload laeuft noch
        mockHttp.answer(iNeu, { "ok": true })
        compare(mgr.modelLoading, false)
        compare(mgr.modelLoaded, true)
        compare(mgr.activeModel, "qwen3.5:9b")
    }

    function test_fehlendesProfilDeaktiviertAuto() {
        mockFileIO.files = {}
        mgr.refresh()
        compare(mgr.autoModeAvailable, false)
        compare(mgr.pickerEntries[0].enabled, false)
        compare(mgr.pickerEntries[0].value, "auto")
        // Fallback: balanced-Modell wird trotzdem geladen (heutiges Verhalten)
        compare(mgr.activeModel, "gemma4:e4b")
    }

    function test_probeNiedrigsterIndexGewinnt() {
        ConfigStore.setValue("remoteEndpoint", "http://lan:11434")
        ConfigStore.setValue("remoteEndpointFallback", "http://wlan:11434")
        mgr.refresh()
        var iLan = mockHttp.find("http://lan:11434/api/tags")
        var iWlan = mockHttp.find("http://wlan:11434/api/tags")
        verify(iLan !== -1 && iWlan !== -1)       // beide parallel gestartet

        // WLAN (Index 1) antwortet ZUERST → vorläufiger Gewinner
        mockHttp.answer(iWlan, _tags(["gross:31b"]))
        compare(mgr.remoteAvailable, true)
        verify(mgr.apiBase() === "http://local:11434")   // aktiv bleibt lokal
        var iWlanRefresh = mockHttp.find("http://wlan:11434/api/tags", iWlan + 1)
        verify(iWlanRefresh !== -1)               // refreshModels des Gewinners

        // LAN (Index 0) antwortet SPÄTER → überschreibt den Gewinner
        mockHttp.answer(iLan, _tags(["gross:31b"]))
        var iLanRefresh = mockHttp.find("http://lan:11434/api/tags", iLan + 1)
        verify(iLanRefresh !== -1)
        mockHttp.answer(iLanRefresh, _tags(["gross:31b"]))
        mockHttp.answer(mockHttp.find("http://lan:11434/api/ps"), { "ok": true, "data": { "models": [] } })
        compare(mgr.remoteModels.length, 1)
    }

    function test_probeLeereAntwortZaehltNicht() {
        ConfigStore.setValue("remoteEndpoint", "http://lan:11434")
        mgr.refresh()
        mockHttp.answer(mockHttp.find("http://lan:11434/api/tags"), _tags([]))
        compare(mgr.remoteAvailable, false)
    }

    function test_probeSpaeteWlanAntwortUeberschreibtNicht() {
        ConfigStore.setValue("remoteEndpoint", "http://lan:11434")
        ConfigStore.setValue("remoteEndpointFallback", "http://wlan:11434")
        mgr.refresh()
        var iLan = mockHttp.find("http://lan:11434/api/tags")
        var iWlan = mockHttp.find("http://wlan:11434/api/tags")
        mockHttp.answer(iLan, _tags(["gross:31b"]))     // LAN (Index 0) gewinnt zuerst
        var callsVorher = mockHttp.calls.length
        mockHttp.answer(iWlan, _tags(["gross:31b"]))    // WLAN trudelt nach
        compare(mockHttp.calls.length, callsVorher)     // kein WLAN-refreshModels ausgelöst
        verify(mockHttp.find("http://wlan:11434/api/tags", iWlan + 1) === -1)
    }

    function test_probeEpocheVerwirftSpaeteAntworten() {
        ConfigStore.setValue("remoteEndpoint", "http://lan:11434")
        mgr.refresh()
        var iAlt = mockHttp.find("http://lan:11434/api/tags")
        mgr.refresh()                                   // neue Probe-Epoche
        var callsVorher = mockHttp.calls.length
        mockHttp.answer(iAlt, _tags(["gross:31b"]))     // Antwort der ALTEN Probe
        compare(mockHttp.calls.length, callsVorher)     // verworfen: kein refreshModels
        compare(mgr.remoteAvailable, false)
    }

    function test_gespeicherteRemoteAuswahlNachProbe() {
        ConfigStore.setValue("lastSelectedModel", "remote:gross:31b")
        ConfigStore.setValue("remoteEndpoint", "http://lan:11434")
        mgr.refresh()
        compare(mgr.selectedModel, "auto")        // remote erst nach Probe
        var iProbe = mockHttp.find("http://lan:11434/api/tags")
        mockHttp.answer(iProbe, _tags(["gross:31b"]))
        var iRefresh = mockHttp.find("http://lan:11434/api/tags", iProbe + 1)
        mockHttp.answer(iRefresh, _tags(["gross:31b"]))
        mockHttp.answer(mockHttp.find("http://lan:11434/api/ps"), { "ok": true, "data": { "models": [] } })
        compare(mgr.selectedModel, "remote:gross:31b")
        compare(mgr.isRemote, true)
        compare(mgr.activeModel, "gross:31b")
        // Preload zielt auf das REMOTE-Backend (Spec-Fix)
        verify(mockHttp.find("http://lan:11434/api/chat") !== -1)
    }

    function test_selectModelPersistiert() {
        mgr.selectModel("local:gemma4:e2b")
        compare(persistSpy.count, 1)
        compare(persistSpy.signalArguments[0][0], "lastSelectedModel")
        compare(persistSpy.signalArguments[0][1], "local:gemma4:e2b")
        compare(mgr.selectedModel, "local:gemma4:e2b")
        compare(mgr.activeModel, "gemma4:e2b")
        compare(mgr.isRemote, false)
    }

    function test_scheduleUnloadNurLokal() {
        mgr.selectModel("local:gemma4:e4b")
        mockHttp.calls = []
        mgr.scheduleUnload()
        var i = mockHttp.find("http://local:11434/api/chat")
        verify(i !== -1)
        compare(mockHttp.calls[i].body.keep_alive, "300s")   // testSettings.unloadSeconds

        // Remote: kein Unload (der Server verwaltet sich selbst)
        ConfigStore.setValue("remoteEndpoint", "http://lan:11434")
        mgr.refresh()
        var iProbe = mockHttp.find("http://lan:11434/api/tags")
        mockHttp.answer(iProbe, _tags(["gross:31b"]))
        mgr.selectModel("remote:gross:31b")
        mockHttp.calls = []
        mgr.scheduleUnload()
        compare(mockHttp.calls.length, 0)
    }

    function test_autoWechselEntlaedtNurLokalesVorgaengermodell() {
        mockFileIO.files["/sys/firmware/acpi/platform_profile"] = "balanced\n"
        mgr.refresh()
        var iPre = mockHttp.find("http://local:11434/api/chat")
        mockHttp.answer(iPre, { "ok": true })     // gemma4:e4b geladen
        compare(mgr.modelLoaded, true)

        mockFileIO.files["/sys/firmware/acpi/platform_profile"] = "performance\n"
        mockHttp.calls = []
        mgr.checkPowerProfile()
        // Erst Unload des alten LOKALEN Modells (keep_alive 0), dann preload neu
        var iUnload = mockHttp.find("http://local:11434/api/chat")
        compare(mockHttp.calls[iUnload].body.model, "gemma4:e4b")
        compare(mockHttp.calls[iUnload].body.keep_alive, "0")
        var iNeu = mockHttp.find("http://local:11434/api/chat", iUnload + 1)
        compare(mockHttp.calls[iNeu].body.model, "qwen3.5:9b")
    }

    function test_remoteZuAutoEntlaedtRemoteModellNichtLokal() {
        // Alt-Bug-Guard: Wechsel remote → auto darf das Remote-Modell NICHT
        // per keep_alive:0 an den LOKALEN Server melden
        ConfigStore.setValue("remoteEndpoint", "http://lan:11434")
        mgr.refresh()
        var iProbe = mockHttp.find("http://lan:11434/api/tags")
        mockHttp.answer(iProbe, _tags(["gross:31b"]))
        mgr.selectModel("remote:gross:31b")
        var iPre = mockHttp.find("http://lan:11434/api/chat")
        verify(iPre !== -1)
        mockHttp.answer(iPre, { "ok": true })           // Remote-Modell "geladen"
        compare(mgr.modelLoaded, true)

        mockHttp.calls = []
        mgr.selectModel("auto")
        for (var i = 0; i < mockHttp.calls.length; i++)
            verify(!(mockHttp.calls[i].body && mockHttp.calls[i].body.model === "gross:31b"))
        var iNeu = mockHttp.find("http://local:11434/api/chat")
        compare(mockHttp.calls[iNeu].body.model, "gemma4:e4b")   // balanced-Profil, lokal
        compare(mgr.isRemote, false)
    }

    function test_withActiveCapsSetztActiveCaps() {
        mgr.selectModel("local:gemma4:e4b")
        // selectModel hat bereits einen /api/show-Aufruf abgesetzt — beantworten
        var iShow = mockHttp.find("http://local:11434/api/show")
        verify(iShow !== -1)
        mockHttp.answer(iShow, { "ok": true, "data": { "capabilities": ["tools", "vision"] } })
        compare(mgr.activeCaps, ["tools", "vision"])

        var out = null
        mgr.withActiveCaps(function(caps) { out = caps })   // Cache-Hit, synchron
        compare(out, ["tools", "vision"])
    }

    function test_pickerEntriesStruktur() {
        mgr.refresh()
        var iTags = mockHttp.find("http://local:11434/api/tags")
        mockHttp.answer(iTags, _tags(["gemma4:e4b"]))
        mockHttp.answer(mockHttp.find("http://local:11434/api/ps"),
            { "ok": true, "data": { "models": [{ "name": "gemma4:e4b" }] } })
        var e = mgr.pickerEntries
        compare(e[0].value, "auto")
        compare(e[0].kind, "auto")
        compare(e[0].enabled, true)
        compare(e[1].kind, "header")
        compare(e[1].enabled, false)
        compare(e[2].value, "local:gemma4:e4b")
        compare(e[2].kind, "local")
        compare(e[2].enabled, true)
        // Exakt gepinnt: Geladen-Markierung, Name und Größe (5e9 B → 5 GB)
        compare(e[2].label, "● gemma4:e4b (5 GB)")
    }

    // Audit-Fix Task 3: Remote-Status muss bei einem voll fehlschlagenden
    // Re-Probe zurückgesetzt werden (Alt-Bug: blieb "online" mit toter
    // baseUrl, wenn eps.length > 0 war) — und ein aktives Remote-Modell
    // muss auf Auto/lokal zurückfallen, statt an eine leere baseUrl zu senden.
    function test_remoteOfflineNachErfolgReicherProbeFaelltZurueck() {
        ConfigStore.setValue("remoteEndpoint", "http://lan:11434")
        mgr.refresh()
        var iProbe = mockHttp.find("http://lan:11434/api/tags")
        mockHttp.answer(iProbe, _tags(["gross:31b"]))
        var iRefresh = mockHttp.find("http://lan:11434/api/tags", iProbe + 1)
        mockHttp.answer(iRefresh, _tags(["gross:31b"]))
        mockHttp.answer(mockHttp.find("http://lan:11434/api/ps"), { "ok": true, "data": { "models": [] } })
        mgr.selectModel("remote:gross:31b")
        var iPre = mockHttp.find("http://lan:11434/api/chat")
        mockHttp.answer(iPre, { "ok": true })     // Remote-Modell "geladen"

        compare(mgr.isRemote, true)
        compare(mgr.remoteAvailable, true)
        verify(mgr.apiBase() === "http://lan:11434")

        // Server geht offline: Re-Probe (neue Epoche) schlägt fehl
        mockHttp.calls = []
        mgr.refresh()
        var iProbe2 = mockHttp.find("http://lan:11434/api/tags")
        verify(iProbe2 !== -1)
        mockHttp.answer(iProbe2, { "ok": false })   // Server nicht erreichbar

        compare(mgr.remoteAvailable, false)
        compare(mgr.remoteClient.baseUrl, "")
        compare(mgr.remoteClient.models.length, 0)
        compare(mgr.isRemote, false)                 // Fallback: Auto/lokal
        verify(!(mgr.isRemote && mgr.apiBase() === ""))   // nie an leere baseUrl senden
        compare(mgr.activeModel, "gemma4:e4b")       // balanced-Profil, jetzt lokal
        var iNeu = mockHttp.find("http://local:11434/api/chat")
        verify(iNeu !== -1)                          // Preload läuft jetzt LOKAL
    }

    // Audit-Fix Task 3 (Fast-Follow): probeBackends() leert remoteClient.baseUrl
    // SOFORT (synchron), bevor eine Probe-Antwort da ist — isRemote bleibt bis
    // dahin unverändert true. Genau in diesem Fenster darf activeClient() NICHT
    // remoteClient (baseUrl "") liefern, sonst bauen chat()/embed()/preload()
    // "" + "/api/chat" und senden an einen leeren Host.
    function test_activeClientWeichtBeiLeererRemoteBaseUrlAufLokalAus() {
        // Remote zunächst erfolgreich anwählen
        ConfigStore.setValue("remoteEndpoint", "http://lan:11434")
        mgr.refresh()
        var iProbe = mockHttp.find("http://lan:11434/api/tags")
        mockHttp.answer(iProbe, _tags(["gross:31b"]))
        var iRefresh = mockHttp.find("http://lan:11434/api/tags", iProbe + 1)
        mockHttp.answer(iRefresh, _tags(["gross:31b"]))
        mockHttp.answer(mockHttp.find("http://lan:11434/api/ps"), { "ok": true, "data": { "models": [] } })
        mgr.selectModel("remote:gross:31b")
        mockHttp.answer(mockHttp.find("http://lan:11434/api/chat"), { "ok": true })
        compare(mgr.isRemote, true)
        verify(mgr.apiBase() === "http://lan:11434")   // Kontrolle: normale Auswahl unverändert

        // Re-Probe: baseUrl wird sofort geleert, isRemote bleibt bis zur
        // Probe-Antwort true — DAS ist das Fenster.
        mockHttp.calls = []
        mgr.refresh()
        compare(mgr.remoteClient.baseUrl, "")
        compare(mgr.isRemote, true)                        // Fenster: noch "remote", aber leer
        verify(mgr.activeClient() === mgr.localClient)      // Guard: weicht auf lokal aus
        verify(mgr.apiBase() === "http://local:11434")      // nie "" + "/api/..."

        // chat()/embed()/preload laufen über activeClient() -> treffen im
        // Fenster ebenfalls den lokalen, nicht den leeren Client.
        var out = "unset"
        mgr.embed("nomic-embed-text", "Frage", function(v) { out = v })
        verify(mockHttp.find("http://local:11434/api/embed") !== -1)
    }

    function test_embed_delegiertAnAktivesBackend() {
        // Standard: isRemote=false -> localClient (baseUrl local), http=mockHttp
        var out = "unset"
        mgr.embed("nomic-embed-text", "Frage", function(v) { out = v })
        var i = mockHttp.find("http://local:11434/api/embed")
        verify(i !== -1)
        compare(mockHttp.calls[i].body.model, "nomic-embed-text")
        compare(mockHttp.calls[i].body.input, "Frage")
        mockHttp.answer(i, { "ok": true, "data": { "embeddings": [[0.1, 0.2]] } })
        compare(out.length, 2)
    }

    // Embed-Fallback: aktives Remote liefert null (Modell fehlt dort) →
    // zweiter Versuch auf dem lokalen Backend, das den Vektor liefert.
    function test_embedFaelltBeiNullVonRemoteAufLokalZurueck() {
        ConfigStore.setValue("remoteEndpoint", "http://lan:11434")
        mgr.refresh()
        var iProbe = mockHttp.find("http://lan:11434/api/tags")
        mockHttp.answer(iProbe, _tags(["gross:31b"]))
        var iRefresh = mockHttp.find("http://lan:11434/api/tags", iProbe + 1)
        mockHttp.answer(iRefresh, _tags(["gross:31b"]))
        mockHttp.answer(mockHttp.find("http://lan:11434/api/ps"), { "ok": true, "data": { "models": [] } })
        mgr.selectModel("remote:gross:31b")
        mockHttp.answer(mockHttp.find("http://lan:11434/api/chat"), { "ok": true })
        compare(mgr.isRemote, true)

        var out = "unset"
        mgr.embed("nomic-embed-text", "Frage", function(v) { out = v })
        var iRemote = mockHttp.find("http://lan:11434/api/embed")
        verify(iRemote !== -1)
        mockHttp.answer(iRemote, { "ok": false, "status": 404, "error": "HTTP 404" })
        // null vom Remote → Fallback ans lokale Backend
        var iLocal = mockHttp.find("http://local:11434/api/embed")
        verify(iLocal !== -1)
        compare(out, "unset")   // noch nicht final beantwortet
        mockHttp.answer(iLocal, { "ok": true, "data": { "embeddings": [[0.3, 0.4]] } })
        compare(out.length, 2)
    }

    // Ohne zweites nutzbares Backend (remote baseUrl leer) geht null durch.
    function test_embedNullOhneFallbackBackend() {
        var out = "unset"
        mgr.embed("nomic-embed-text", "Frage", function(v) { out = v })
        var i = mockHttp.find("http://local:11434/api/embed")
        verify(i !== -1)
        mockHttp.answer(i, { "ok": false, "status": 404, "error": "HTTP 404" })
        compare(out, null)
        // kein Embed-Request an eine leere/ungültige zweite URL
        for (var c = 0; c < mockHttp.calls.length; c++)
            verify(mockHttp.calls[c].url.indexOf("/api/embed") === -1 || c === i)
    }
    // Live-Sync Modell-Store → Picker: nur ein echter modelsRevision-Wechsel
    // stößt probeBackends an; beliebige andere Config-Writes nicht.
    function test_modelsRevisionWechselLoestProbeAus() {
        mgr.active = true   // Watcher ist active-gegatet (Panel-Widget ist immer aktiv)
        compare(mockHttp.calls.length, 0)
        // Irrelevante Config-Änderung: KEINE Probe (Wert-Vergleich)
        ConfigStore.setValue("ttsVoice", "irgendwas")
        compare(mockHttp.calls.length, 0)
        // modelsRevision-Bump → probeBackends → /api/tags auf dem lokalen Backend
        ConfigStore.setValue("modelsRevision", "2026-07-25T12:00:00")
        verify(mockHttp.find("http://local:11434/api/tags") !== -1)
        // Gleicher Wert nochmal: setValue idempotent → kein Bump, keine Probe
        var n = mockHttp.calls.length
        ConfigStore.setValue("modelsRevision", "2026-07-25T12:00:00")
        compare(mockHttp.calls.length, n)
        // Neuer Wert → erneute Probe
        ConfigStore.setValue("modelsRevision", "2026-07-25T12:01:00")
        verify(mockHttp.find("http://local:11434/api/tags", n) !== -1)
    }

    // ---------- Backend-Registry: mehr als lokal + remote ----------

    // Ein OpenAI-Backend (llama-server mit Bonsai) spricht ein anderes
    // Protokoll: /v1/models statt /api/tags.
    function test_openaiBackendWirdMitV1ModelsGeprobt() {
        ConfigStore.setValue("openaiEndpoint", "http://llama:8080")
        mgr.refresh()
        var i = mockHttp.find("http://llama:8080/v1/models")
        verify(i !== -1)
    }

    function test_openaiModelleErscheinenImPicker() {
        ConfigStore.setValue("openaiEndpoint", "http://llama:8080")
        mgr.refresh()
        var i = mockHttp.find("http://llama:8080/v1/models")
        mockHttp.answer(i, { "ok": true, "data": { "data": [
            { "id": "bonsai-27b-ternary" }] } })
        var gefunden = false
        for (var k = 0; k < mgr.pickerEntries.length; k++)
            if (mgr.pickerEntries[k].value === "openai:bonsai-27b-ternary") gefunden = true
        verify(gefunden)
    }

    // Auswahl eines OpenAI-Modells: chat() muss an DESSEN Endpunkt gehen,
    // nicht an das lokale Ollama.
    function test_auswahlOpenaiLeitetChatDorthin() {
        ConfigStore.setValue("openaiEndpoint", "http://llama:8080")
        mgr.refresh()
        var i = mockHttp.find("http://llama:8080/v1/models")
        mockHttp.answer(i, { "ok": true, "data": { "data": [{ "id": "bonsai-27b-ternary" }] } })
        mgr.selectModel("openai:bonsai-27b-ternary")
        compare(mgr.activeModel, "bonsai-27b-ternary")
        compare(mgr.apiBase(), "http://llama:8080")
        mgr.chat({ "model": "bonsai-27b-ternary", "messages": [] })
        // Der OpenAiClient streamt über NdjsonStream, nicht über http —
        // entscheidend ist, dass apiBase auf das richtige Backend zeigt.
        compare(mgr.activeBackendId, "openai")
    }

    // Das Cloud-Flag ist die Leitplanke: der Auto-Modus darf nie dorthin
    // greifen, auch wenn das Profil-Modell zufällig gleich heißt.
    function test_autoModusUeberspringtCloud() {
        ConfigStore.setValue("openrouterEnabled", true)
        mgr.refresh()
        compare(mgr.isCloudActive, false)
        verify(mgr.activeBackendId !== "openrouter")
    }

    // Wer ein Cloud-Modell wählt, bekommt es — aber sichtbar markiert.
    // (keyref-Durchreichung: ohne Mock-KeyRing würde hier das echte KWallet
    // asynchron antworten und der Test wäre nicht deterministisch.)
    function test_cloudAuswahlWirdAlsSolcheGemeldet() {
        mgr.keyring = mockKeyring
        ConfigStore.setValue("openrouterEnabled", true)
        mgr.refresh()
        var i = mockHttp.find("openrouter.ai/api/v1/models")
        verify(i !== -1)
        mockHttp.answer(i, { "ok": true, "data": { "data": [{ "id": "openrouter/free" }] } })
        mgr.selectModel("openrouter:openrouter/free")
        compare(mgr.activeBackendId, "openrouter")
        compare(mgr.isCloudActive, true)
    }

    // Cloud-Backend bekommt seine Schlüssel-Auflösung: der ModelManager
    // reicht keyring + keyRef aus der Registry an den OpenAiClient weiter —
    // ohne diesen Weg käme kein Authorization-Header an.
    function test_cloudBackendBekommtKeyRefUndKeyring() {
        ConfigStore.setValue("openrouterEnabled", true)
        mgr.keyring = mockKeyring
        mgr.refresh()
        compare(mockKeyring.reads.length, 1)
        compare(mockKeyring.reads[0], "openrouter")
        var i = mockHttp.find("openrouter.ai/api/v1/models")
        verify(i !== -1)
        mockHttp.answer(i, { "ok": true, "data": { "data": [{ "id": "openrouter/free" }] } })
    }

    // Favoriten-Filter: das Startset (21 freie Modelle) erscheint im Picker;
    // bezahlte Modelle tauchen NICHT auf (425 flach wären unbenutzbar).
    function test_pickerZeigtNurFreieCloudModelle() {
        mgr.keyring = mockKeyring
        ConfigStore.setValue("openrouterEnabled", true)
        mgr.refresh()
        var i = mockHttp.find("openrouter.ai/api/v1/models")
        verify(i !== -1)
        mockHttp.answer(i, { "ok": true, "data": { "data": [
            { "id": "openrouter/free" },
            { "id": "google/gemini-3.8-flash" }   // bezahlt — bleibt weg
        ] } })
        var gefunden = false
        var bezahltGefunden = false
        for (var k = 0; k < mgr.pickerEntries.length; k++) {
            if (mgr.pickerEntries[k].value === "openrouter:openrouter/free") gefunden = true
            if (mgr.pickerEntries[k].value === "openrouter:google/gemini-3.8-flash") bezahltGefunden = true
        }
        verify(gefunden)
        verify(!bezahltGefunden)
    }

    // Bestandsauswahl "remote:<modell>" muss weiter funktionieren: sie zeigt
    // auf das erste Netzwerk-Backend. refreshModels braucht neben der Probe
    // den zweiten /api/tags- und den /api/ps-Aufruf, bevor models steht —
    // erst dann kann _applyPendingRemoteModel greifen (Alt-Test beantwortete
    // nur die Probe und ließ die Auswahl dadurch leer).
    function test_migrationAlterRemoteAuswahl() {
        ConfigStore.setValue("remoteEnabled", true)
        ConfigStore.setValue("remoteEndpoint", "http://lan:11434")
        ConfigStore.setValue("lastSelectedModel", "remote:qwen3.6-27b")
        mgr.refresh()
        var iProbe = mockHttp.find("http://lan:11434/api/tags")
        verify(iProbe !== -1)
        mockHttp.answer(iProbe, _tags(["qwen3.6-27b"]))
        var iRefresh = mockHttp.find("http://lan:11434/api/tags", iProbe + 1)
        verify(iRefresh !== -1)
        mockHttp.answer(iRefresh, _tags(["qwen3.6-27b"]))
        mockHttp.answer(mockHttp.find("http://lan:11434/api/ps"), { "ok": true, "data": { "models": [] } })
        compare(mgr.activeModel, "qwen3.6-27b")
        compare(mgr.isRemote, true)
    }
}
