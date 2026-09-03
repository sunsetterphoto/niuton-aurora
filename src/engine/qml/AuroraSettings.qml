import QtQml
import net.niuton.aurora.core

// Settings-Adapter (Spec 2c): stabile Engine-Oberfläche (typisierte Properties),
// an den geteilten ConfigStore gebunden. Widget UND App instanziieren nur dieses
// Objekt.
//
// Reaktivität (Stufe 2d/2e, AOT-sicher + eager):
// - INITIAL werden die Werte EAGER beim Konstruieren direkt aus ConfigStore.value(...)
//   gelesen (Initial-Binding), damit sie ab dem ersten Zugriff korrekt sind — auch
//   für frühe Konsumenten wie die App-Shell, die schon in Component.onCompleted probt
//   (das frühere reine _sync()-in-onCompleted lief dafür zu spät → leere Endpunkte).
// - AKTUALISIERT werden sie über _sync() (Connections auf ConfigStore.revisionChanged;
//   Signal-Handler laufen immer, sind AOT-immun). QSettings hat keine per-Key-Notify;
//   der QFileSystemWatcher im ConfigStore bumpt revision auch bei Änderungen aus der
//   Config-Dialog-Engine / einem anderen Prozess.
// - ConfigStore.value ist ein invokable Call (keine Binding-Dependency) → das
//   Initial-Binding evaluiert genau einmal, wird nicht als Totcode eliminiert
//   (anders als der frühere Komma-Operator-Trick), und reagiert selbst nicht auf
//   revision — genau dafür ist _sync() da.
QtObject {
    id: settings

    // Modelle
    property string modelLowPower: ConfigStore.value("modelLowPower")
    property string modelBalanced: ConfigStore.value("modelBalanced")
    property string modelPerformance: ConfigStore.value("modelPerformance")
    property string lastSelectedModel: ConfigStore.value("lastSelectedModel")
    property string embedModel: ConfigStore.value("embedModel")
    // OpenRouter-Video-Generierung: Default-Modell (Veo 3.1 Lite); leer deaktiviert.
    property string videoGenModel: ConfigStore.value("videoGenModel")
    // Vom Nutzer gepinnte OpenRouter-Modelle (Array der IDs). Leer = die
    // Engine nutzt das freie Startset (OpenRouterFreeStart).
    property var openrouterFavorites: _parseFavorites()
    property bool ragEnabled: ConfigStore.value("ragEnabled")
    property int ragTopK: ConfigStore.value("ragTopK")
    property double ragThreshold: ConfigStore.value("ragThreshold")
    property var remoteEndpoints: settings._computeRemoteEndpoints()
    property var backends: settings._computeBackends()
    property int unloadSeconds: ConfigStore.value("unloadSeconds")

    // Tools (kanonisch "off" | "auto" | "confirm")
    property string toolWebSearch: ConfigStore.value("toolWebSearch")
    property string toolReadFile: ConfigStore.value("toolReadFile")
    property string toolListDir: ConfigStore.value("toolListDir")
    property string toolWebFetch: ConfigStore.value("toolWebFetch")
    property string toolWriteFile: ConfigStore.value("toolWriteFile")
    property string toolRunCommand: ConfigStore.value("toolRunCommand")
    property int toolMaxRounds: ConfigStore.value("toolMaxRounds")
    property bool twoPhaseToolCalls: ConfigStore.value("twoPhaseToolCalls")

    // Dienste
    property string comfyEndpoint: ConfigStore.value("comfyEndpoint")
    property string comfyEndpointLocal: ConfigStore.value("comfyEndpointLocal")
    property bool comfyEnabled: ConfigStore.value("comfyEnabled")
    property string comfyDefaultModel: ConfigStore.value("comfyDefaultModel")
    property bool comfyFreeVram: ConfigStore.value("comfyFreeVram")
    property string searchEndpoint: ConfigStore.value("searchEndpoint")
    property bool speachesEnabled: ConfigStore.value("speachesEnabled")
    property string speachesEndpoint: ConfigStore.value("speachesEndpoint")
    property string speachesSttModel: ConfigStore.value("speachesSttModel")
    property bool servicesAutoStart: ConfigStore.value("servicesAutoStart")

    // Voice
    property string ttsVoice: ConfigStore.value("ttsVoice")
    property bool ttsAutoSpeak: ConfigStore.value("ttsAutoSpeak")
    property string sttLanguage: ConfigStore.value("sttLanguage")
    property string sttSource: ConfigStore.value("sttSource")
    property var modelParams: _parseModelParams()

    // remoteEndpoints: gefaltet aus remoteEnabled + beiden Endpunkten. Als Funktion,
    // damit sie sowohl das Initial-Binding oben als auch _sync() speisen kann.
    function _computeRemoteEndpoints() {
        var eps = []
        if (ConfigStore.value("remoteEnabled")) {
            var a = ConfigStore.value("remoteEndpoint")
            var b = ConfigStore.value("remoteEndpointFallback")
            if (a) eps.push(a)
            if (b) eps.push(b)
        }
        return eps
    }

    // Backend-Registry: die eine Liste, über die der ModelManager läuft. Sie
    // ersetzt das feste Paar lokal/remote — jeder Eintrag nennt seine Sorte,
    // und die Sorte bestimmt den Client (OllamaClient bzw. OpenAiClient).
    //
    // Die REIHENFOLGE ist bedeutungstragend: die Probe nimmt den niedrigsten
    // Index, der antwortet. Deshalb steht das lokale Ollama vorn und alles mit
    // cloud:true hinten — solange hier etwas antwortet, geht nichts nach außen.
    function _computeBackends() {
        var out = [{ "id": "local", "kind": "ollama",
                     "endpoint": "http://127.0.0.1:11434",
                     "label": "Lokal", "cloud": false }]
        // Ollama im eigenen Netz (LAN vor WLAN: Reihenfolge wie konfiguriert)
        if (ConfigStore.value("remoteEnabled")) {
            var a = ConfigStore.value("remoteEndpoint")
            var b = ConfigStore.value("remoteEndpointFallback")
            if (a) out.push({ "id": "lan1", "kind": "ollama", "endpoint": a,
                              "label": "Netzwerk", "cloud": false })
            if (b) out.push({ "id": "lan2", "kind": "ollama", "endpoint": b,
                              "label": "Netzwerk (2)", "cloud": false })
        }
        // OpenAI-Protokoll, aber im eigenen Netz (llama-server mit Bonsai):
        // dasselbe Vertrauensniveau wie Ollama, deshalb kein Cloud-Flag.
        var oa = ConfigStore.value("openaiEndpoint")
        if (oa) out.push({ "id": "openai", "kind": "openai", "endpoint": oa,
                           "label": "llama-server", "cloud": false })
        // Cloud zuletzt und nur auf ausdrücklichen Wunsch. Endpunkt OHNE /v1:
        // der OpenAiClient hängt die Route selbst an (/v1/models) — die alte
        // Schreibweise mit /v1 ergab ".../api/v1/v1/models".
        if (ConfigStore.value("openrouterEnabled"))
            out.push({ "id": "openrouter", "kind": "openai",
                       "endpoint": "https://openrouter.ai/api",
                       "label": "OpenRouter", "cloud": true,
                       "keyRef": "openrouter" })
        return out
    }

    // Alle Werte aus dem ConfigStore neu einlesen (bei jeder revision-Änderung).
    function _sync() {
        modelLowPower = ConfigStore.value("modelLowPower")
        modelBalanced = ConfigStore.value("modelBalanced")
        modelPerformance = ConfigStore.value("modelPerformance")
        lastSelectedModel = ConfigStore.value("lastSelectedModel")
        embedModel = ConfigStore.value("embedModel")
        videoGenModel = ConfigStore.value("videoGenModel")
        openrouterFavorites = _parseFavorites()
        ragEnabled = ConfigStore.value("ragEnabled")
        ragTopK = ConfigStore.value("ragTopK")
        ragThreshold = ConfigStore.value("ragThreshold")
        unloadSeconds = ConfigStore.value("unloadSeconds")
        toolWebSearch = ConfigStore.value("toolWebSearch")
        toolReadFile = ConfigStore.value("toolReadFile")
        toolListDir = ConfigStore.value("toolListDir")
        toolWebFetch = ConfigStore.value("toolWebFetch")
        toolWriteFile = ConfigStore.value("toolWriteFile")
        toolRunCommand = ConfigStore.value("toolRunCommand")
        toolMaxRounds = ConfigStore.value("toolMaxRounds")
        twoPhaseToolCalls = ConfigStore.value("twoPhaseToolCalls")
        comfyEndpoint = ConfigStore.value("comfyEndpoint")
        comfyEndpointLocal = ConfigStore.value("comfyEndpointLocal")
        comfyEnabled = ConfigStore.value("comfyEnabled")
        comfyDefaultModel = ConfigStore.value("comfyDefaultModel")
        comfyFreeVram = ConfigStore.value("comfyFreeVram")
        searchEndpoint = ConfigStore.value("searchEndpoint")
        speachesEnabled = ConfigStore.value("speachesEnabled")
        speachesEndpoint = ConfigStore.value("speachesEndpoint")
        speachesSttModel = ConfigStore.value("speachesSttModel")
        servicesAutoStart = ConfigStore.value("servicesAutoStart")
        ttsVoice = ConfigStore.value("ttsVoice")
        ttsAutoSpeak = ConfigStore.value("ttsAutoSpeak")
        sttLanguage = ConfigStore.value("sttLanguage")
        sttSource = ConfigStore.value("sttSource")
        modelParams = _parseModelParams()
        remoteEndpoints = _computeRemoteEndpoints()
        backends = _computeBackends()
    }

    property Connections _revisionConn: Connections {
        target: ConfigStore
        function onRevisionChanged() { settings._sync() }
    }

    // modelParams-Blob robust parsen: bei ungültigem (extern manipuliertem)
    // JSON auf {} zurückfallen statt zu werfen.
    function _parseModelParams() {
        try {
            var o = JSON.parse(ConfigStore.value("modelParams") || "{}")
            return (o && typeof o === "object" && !Array.isArray(o)) ? o : ({})
        } catch (e) {
            return ({})
        }
    }

    // Favoriten-Liste robust parsen: bei ungültigem JSON oder Nicht-Array
    // (extern manipuliert) auf das leere Startset zurückfallen.
    function _parseFavorites() {
        try {
            var raw = JSON.parse(ConfigStore.value("openrouterFavorites") || "[]")
            return Array.isArray(raw) ? raw : []
        } catch (e) {
            return []
        }
    }

    // Options-Objekt des Modells (nur gesetzte Keys) bzw. {} für Unbekannte.
    function paramsFor(name) {
        var m = modelParams || ({})
        var e = m[name]
        return (e && typeof e === "object") ? e : ({})
    }

    // obj = nur gesetzte Parameter; leeres obj entfernt den Modell-Eintrag.
    // Liest den aktuellen Blob frisch aus dem ConfigStore (nicht die evtl. noch
    // nicht nachgezogene Property), merged und persistiert als JSON-String.
    function setModelParams(name, obj) {
        var all = _parseModelParams()
        if (obj && Object.keys(obj).length > 0)
            all[name] = obj
        else
            delete all[name]
        requestPersist("modelParams", JSON.stringify(all))
    }

    // Engine -> Store: Schreibwunsch. Schreibt in den ConfigStore (dessen
    // revision-Bump _sync() synchron auslöst und die Properties aktualisiert)
    // UND emittiert persistRequested als stabile Kompatibilitäts-Oberfläche
    // (Tests/Consumer).
    signal persistRequested(string key, var value)
    function requestPersist(key, value) {
        ConfigStore.setValue(key, value)
        persistRequested(key, value)
    }
}
