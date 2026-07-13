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
    property var remoteEndpoints: settings._computeRemoteEndpoints()
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
    property bool comfyEnabled: ConfigStore.value("comfyEnabled")
    property string comfyDefaultModel: ConfigStore.value("comfyDefaultModel")
    property string searchEndpoint: ConfigStore.value("searchEndpoint")

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

    // Alle Werte aus dem ConfigStore neu einlesen (bei jeder revision-Änderung).
    function _sync() {
        modelLowPower = ConfigStore.value("modelLowPower")
        modelBalanced = ConfigStore.value("modelBalanced")
        modelPerformance = ConfigStore.value("modelPerformance")
        lastSelectedModel = ConfigStore.value("lastSelectedModel")
        embedModel = ConfigStore.value("embedModel")
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
        comfyEnabled = ConfigStore.value("comfyEnabled")
        comfyDefaultModel = ConfigStore.value("comfyDefaultModel")
        searchEndpoint = ConfigStore.value("searchEndpoint")
        ttsVoice = ConfigStore.value("ttsVoice")
        ttsAutoSpeak = ConfigStore.value("ttsAutoSpeak")
        sttLanguage = ConfigStore.value("sttLanguage")
        sttSource = ConfigStore.value("sttSource")
        modelParams = _parseModelParams()
        remoteEndpoints = _computeRemoteEndpoints()
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
