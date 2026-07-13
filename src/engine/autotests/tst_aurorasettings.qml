import QtQuick
import QtTest
import net.niuton.aurora.core
import net.niuton.aurora.engine

TestCase {
    name: "AuroraSettings"

    AuroraSettings { id: s }
    SignalSpy { id: spy; target: s; signalName: "persistRequested" }

    // ConfigStore ist ein QML_SINGLETON (pro Engine EIN Objekt) und kann nicht
    // pro Testfunktion neu gebaut werden — reset() ist der Isolations-Hebel,
    // der jeden Test wieder auf die C++-Schema-Defaults zurücksetzt (AURORA_CONFIG_PATH
    // zeigt laut CMakeLists auf eine build-lokale, testspezifische Datei).
    function init() {
        ConfigStore.reset()
        spy.clear()
    }

    function test_neutraleDefaults() {
        compare(s.modelLowPower, "gemma4:e2b")
        compare(s.modelBalanced, "gemma4:e4b")
        compare(s.modelPerformance, "qwen3.5:9b")
        compare(s.lastSelectedModel, "auto")
        compare(s.remoteEndpoints.length, 0)   // Engine-Default LEER (keine privaten IPs)
        compare(s.unloadSeconds, 300)
        compare(s.toolWebSearch, "auto")
        compare(s.toolReadFile, "auto")
        compare(s.toolListDir, "auto")
        compare(s.toolWebFetch, "auto")
        compare(s.toolWriteFile, "confirm")
        compare(s.toolRunCommand, "confirm")
        compare(s.toolMaxRounds, 5)
        compare(s.twoPhaseToolCalls, false)
        compare(s.comfyEndpoint, "")
        compare(s.comfyEnabled, true)
        compare(s.comfyDefaultModel, "z_image_turbo")
        compare(s.searchEndpoint, "http://127.0.0.1:8888")
        compare(s.ttsVoice, "de_DE-thorsten-high")
        compare(s.ttsAutoSpeak, false)
        compare(s.sttLanguage, "auto")
        compare(s.sttSource, "")
        compare(s.embedModel, "nomic-embed-text")
    }

    function test_modelParamsDefaultLeer() {
        compare(s.modelParams !== undefined && s.modelParams !== null, true)
        compare(Object.keys(s.modelParams).length, 0)          // Default "{}" -> {}
        compare(Object.keys(s.paramsFor("qwen3.5:9b")).length, 0)  // unbekannt -> {}
    }

    function test_modelParamsRoundTrip() {
        s.setModelParams("qwen3.5:9b", { "num_ctx": 8192, "temperature": 0.7 })
        compare(spy.count, 1)                                  // requestPersist gefeuert
        compare(spy.signalArguments[0][0], "modelParams")      // richtiger Key
        var p = s.paramsFor("qwen3.5:9b")
        compare(p.num_ctx, 8192)
        compare(p.temperature, 0.7)
        verify(p.top_p === undefined)                          // nur gesetzte Keys

        // zweites Modell unabhängig, erstes bleibt erhalten
        s.setModelParams("gemma4:e4b", { "num_ctx": 4096 })
        compare(s.paramsFor("gemma4:e4b").num_ctx, 4096)
        compare(s.paramsFor("qwen3.5:9b").num_ctx, 8192)

        // leeres obj entfernt nur diesen Eintrag
        s.setModelParams("qwen3.5:9b", {})
        compare(Object.keys(s.paramsFor("qwen3.5:9b")).length, 0)
        compare(s.paramsFor("gemma4:e4b").num_ctx, 4096)
    }

    function test_requestPersistEmittiertUndAktualisiertProperty() {
        // requestPersist schreibt jetzt via ConfigStore.setValue UND emittiert
        // persistRequested (Kompatibilitäts-Oberfläche für Tests/Consumer) —
        // die revision-verankerte Bindung oben spiegelt den neuen Wert sofort.
        s.requestPersist("lastSelectedModel", "local:qwen3.5:9b")
        compare(spy.count, 1)
        compare(spy.signalArguments[0][0], "lastSelectedModel")
        compare(spy.signalArguments[0][1], "local:qwen3.5:9b")
        compare(s.lastSelectedModel, "local:qwen3.5:9b")
    }

    function test_remoteEndpointsLeerOhneRemoteEnabled() {
        ConfigStore.setValue("remoteEndpoint", "http://lan:11434")
        ConfigStore.setValue("remoteEndpointFallback", "http://wlan:11434")
        ConfigStore.setValue("remoteEnabled", false)
        compare(s.remoteEndpoints.length, 0)
    }

    function test_remoteEndpointsGefaltetMitBeidenEndpunkten() {
        ConfigStore.setValue("remoteEnabled", true)
        ConfigStore.setValue("remoteEndpoint", "http://lan:11434")
        ConfigStore.setValue("remoteEndpointFallback", "http://wlan:11434")
        compare(s.remoteEndpoints.length, 2)
        compare(s.remoteEndpoints[0], "http://lan:11434")
        compare(s.remoteEndpoints[1], "http://wlan:11434")
    }

    function test_embedModelReaktiv() {
        ConfigStore.setValue("embedModel", "mxbai-embed-large")
        compare(s.embedModel, "mxbai-embed-large")
    }
}
