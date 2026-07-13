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
        persistSpy.clear()
        // ConfigStore ist ein QML_SINGLETON (nicht pro Testfunktion neu baubar) —
        // reset() ist der Isolations-Hebel (AURORA_CONFIG_PATH zeigt laut
        // CMakeLists auf eine build-lokale, testspezifische Datei). Er setzt
        // lastSelectedModel/remoteEndpoints implizit auf die Schema-Defaults
        // ("auto" bzw. [] durch die revision-Bindung in testSettings) zurück.
        ConfigStore.reset()
        mockFileIO.files = { "/sys/firmware/acpi/platform_profile": "balanced\n" }
        if (mgr) mgr.destroy()
        mgr = mgrFactory.createObject(this)
    }

    function _tags(namen) {
        var models = []
        for (var i = 0; i < namen.length; i++)
            models.push({ "name": namen[i], "size": 5000000000, "digest": "d" + i })
        return { "ok": true, "data": { "models": models } }
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
}
