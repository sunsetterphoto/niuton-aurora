import QtQuick
import QtTest
import net.niuton.aurora.core
import net.niuton.aurora.engine

// ModelStore ohne echtes Netz: Mock-Http + Mock-NdjsonStream werden injiziert
// (gleiche Injektions-Konvention wie OllamaClient). Der Mock-Stream zeichnet
// post()/abort() auf und lässt die Tests Zeilen/Ende von Hand emittieren.
TestCase {
    name: "ModelStore"

    // Letzte angelegte Stream-Instanz (ModelStore holt sich pro Pull einen
    // frischen Stream aus der Fabrik).
    property var lastStream: null

    component MockStream: QtObject {
        property int idleTimeoutMs: 0
        property var posted: null   // {url, body}
        property int abortCount: 0
        signal objectReceived(var obj)
        signal finished(bool ok, int status, string error)
        function post(url, body) { posted = { "url": url, "body": body } }
        function abort() { abortCount += 1 }
    }

    // Mock-Http: getJson/deleteJson liefern auf Zuruf konfigurierte Resultate
    // und zeichnen Aufrufe auf.
    property QtObject mockHttp: QtObject {
        property var tagsResult: ({ "ok": true, "data": { "models": [] } })
        property var deleteCalls: []
        property var deleteResult: ({ "ok": true, "status": 200 })
        function getJson(url, cb, t) { cb(tagsResult) }
        function postJson(url, body, cb, t) { cb({ "ok": true }) }
        function deleteJson(url, body, cb, t) {
            deleteCalls.push({ "url": url, "body": body })
            cb(deleteResult)
        }
    }

    ModelStore {
        id: store
        http: mockHttp
        ndjsonFactory: Component { MockStream {} }
    }

    // Fabrik-Instanzen nachverfolgen: createObject passiert in ModelStore
    // selbst — der frische Stream liegt danach in store._stream.
    function _startPull() {
        var started = store.pull("http://backend:11434", "qwen3.6:27b")
        verify(started)
        lastStream = store._stream
        verify(lastStream !== null)
    }

    property var finishResults: []
    function _onFinish(ok, err) { finishResults.push({ "ok": ok, "err": err }) }

    function init() {
        finishResults = []
        store.pullFinished.connect(_onFinish)
        mockHttp.tagsResult = { "ok": true, "data": { "models": [] } }
        mockHttp.deleteCalls = []
        mockHttp.deleteResult = { "ok": true, "status": 200 }
    }

    function cleanup() {
        store.pullFinished.disconnect(_onFinish)
        if (store.busy) store.cancelPull()
        lastStream = null
    }

    function test_pullStartetStreamMitPullApi() {
        _startPull()
        compare(store.busy, true)
        compare(store.activeModel, "qwen3.6:27b")
        compare(lastStream.posted.url, "http://backend:11434/api/pull")
        compare(lastStream.posted.body.name, "qwen3.6:27b")
        compare(lastStream.posted.body.stream, true)
        compare(lastStream.idleTimeoutMs, 600000)   // Digest-Verifizierung pausiert
    }

    function test_pullFortschrittSummiertUeberDigests() {
        _startPull()
        lastStream.objectReceived({ "status": "pulling manifest" })
        compare(store.statusText, "pulling manifest")
        lastStream.objectReceived({ "status": "downloading", "digest": "a",
                                    "total": 100, "completed": 50 })
        compare(store.progress, 0.5)
        compare(store.totalBytes, 100)
        compare(store.completedBytes, 50)
        // Zweiter Layer: Fortschritt aggregiert (50+150)/(100+300)
        lastStream.objectReceived({ "status": "downloading", "digest": "b",
                                    "total": 300, "completed": 150 })
        compare(store.progress, 0.5)
        compare(store.totalBytes, 400)
        compare(store.completedBytes, 200)
        // Erster Layer schreitet weiter voran (gleicher Digest aktualisiert)
        lastStream.objectReceived({ "status": "downloading", "digest": "a",
                                    "total": 100, "completed": 100 })
        compare(store.progress, 250.0 / 400.0)
    }

    function test_pullErfolgBeiSuccessZeile() {
        _startPull()
        lastStream.objectReceived({ "status": "success" })
        compare(store.busy, false)
        compare(store.progress, 1)
        compare(finishResults.length, 1)
        compare(finishResults[0].ok, true)
        compare(finishResults[0].err, "")
        // Stream wurde still abgeräumt (abort + destroy), kein doppeltes Finish
        compare(lastStream.abortCount, 1)
        compare(store._stream, null)
    }

    function test_pullFehlerZeileSchlaegtFehl() {
        _startPull()
        lastStream.objectReceived({ "error": "pull model manifest: file not found" })
        compare(store.busy, false)
        compare(finishResults.length, 1)
        compare(finishResults[0].ok, false)
        verify(finishResults[0].err.indexOf("not found") >= 0)
    }

    function test_pullStreamTimeoutMeldetZeitüberschreitung() {
        _startPull()
        lastStream.finished(false, 0, "timeout")
        compare(store.busy, false)
        compare(finishResults.length, 1)
        compare(finishResults[0].ok, false)
        compare(finishResults[0].err, "Zeitüberschreitung beim Download")
    }

    function test_pullStreamEndeOhneSuccessIstFehler() {
        _startPull()
        lastStream.finished(true, 200, "")
        compare(store.busy, false)
        compare(finishResults.length, 1)
        compare(finishResults[0].ok, false)
        verify(finishResults[0].err.length > 0)
    }

    function test_pullSingleFlightUndLeererName() {
        _startPull()
        compare(store.pull("http://backend:11434", "anderes:modell"), false)
        compare(store.activeModel, "qwen3.6:27b")   // erster Lauf unverändert
        store.cancelPull()
        compare(store.pull("http://backend:11434", "  "), false)
        compare(store.busy, false)
    }

    function test_cancelPullBrichtStillAb() {
        _startPull()
        lastStream.objectReceived({ "status": "downloading", "digest": "a",
                                    "total": 100, "completed": 50 })
        compare(store.completedBytes, 50)
        store.cancelPull()
        compare(store.busy, false)
        compare(store.activeModel, "")
        compare(store.progress, 0)
        compare(store.totalBytes, 0)
        compare(store.completedBytes, 0)
        compare(lastStream.abortCount, 1)
        compare(finishResults.length, 0)   // Abbruch meldet nichts
        // Verspätete Zeilen des toten Streams erreichen den Store nicht mehr
        lastStream.objectReceived({ "status": "success" })
        compare(store.busy, false)
        compare(finishResults.length, 0)
    }

    function test_removeRuftDeleteJsonMitNamen() {
        var results = []
        var ok = store.remove("http://backend:11434", "qwen3.6:27b",
            function(o, e) { results.push({ "ok": o, "err": e }) })
        compare(mockHttp.deleteCalls.length, 1)
        compare(mockHttp.deleteCalls[0].url, "http://backend:11434/api/delete")
        compare(mockHttp.deleteCalls[0].body.name, "qwen3.6:27b")
        compare(results.length, 1)
        compare(results[0].ok, true)
    }

    function test_removeFehlerNimmtOllamaErrorBody() {
        mockHttp.deleteResult = { "ok": false, "status": 404,
            "error": "HTTP 404", "data": { "error": "model 'x' not found" } }
        var results = []
        store.remove("http://backend:11434", "x:y", function(o, e) {
            results.push({ "ok": o, "err": e }) })
        compare(results[0].ok, false)
        compare(results[0].err, "model 'x' not found")
    }

    function test_listInstalledLiefertDetailsAllerModelle() {
        mockHttp.tagsResult = { "ok": true, "data": { "models": [
            { "name": "qwen3.6:27b", "size": 17300000000, "capabilities": ["vision", "tools"] },
            { "name": "nomic-embed-text:latest", "size": 274000000, "capabilities": ["embedding"] } ] } }
        var got = null
        store.listInstalled("http://backend:11434", function(ok, entries) {
            got = { "ok": ok, "entries": entries } })
        compare(got.ok, true)
        compare(got.entries.length, 2)
        compare(got.entries[0].name, "qwen3.6:27b")
        compare(got.entries[0].sizeGB, 17.3)
        compare(got.entries[0].caps.length, 2)
        // Embedding-Modelle werden NICHT gefiltert (Store-Sicht, vgl. OllamaClient)
        compare(got.entries[1].name, "nomic-embed-text:latest")
        compare(got.entries[1].sizeGB, 0.3)
    }

    function test_listInstalledBackendDownMeldetNichtOk() {
        mockHttp.tagsResult = { "ok": false, "status": 0, "error": "refused" }
        var got = null
        store.listInstalled("http://backend:11434", function(ok, entries) {
            got = { "ok": ok, "entries": entries } })
        compare(got.ok, false)
        compare(got.entries.length, 0)
    }

    function test_pullLeereBackendUrlWirdAbgewiesen() {
        compare(store.pull("", "qwen3.6:27b"), false)
        compare(store.busy, false)
        compare(store._stream, null)
    }

    // Store-Bestandsänderungen bumped der ModelStore über den internen Key
    // "modelsRevision" → ModelManager probt neu (Live-Sync Store→Picker).
    function test_erfolgreicherPullBumpedModelsRevision() {
        var vorher = String(ConfigStore.value("modelsRevision") || "")
        _startPull()
        lastStream.objectReceived({ "status": "success" })
        var nachher = String(ConfigStore.value("modelsRevision") || "")
        verify(nachher !== "")
        verify(nachher !== vorher)
    }

    function test_fehlgeschlagenerPullBumpedNicht() {
        ConfigStore.setValue("modelsRevision", "fixwert")
        _startPull()
        lastStream.finished(false, 0, "timeout")
        compare(String(ConfigStore.value("modelsRevision")), "fixwert")
    }

    function test_removeErfolgBumped() {
        ConfigStore.setValue("modelsRevision", "fixwert")
        var done = false
        store.remove("http://backend:11434", "x:y", function(o, e) { done = true })
        verify(done)
        verify(String(ConfigStore.value("modelsRevision")) !== "fixwert")
    }

    function test_removeFehlerBumpedNicht() {
        ConfigStore.setValue("modelsRevision", "fixwert")
        mockHttp.deleteResult = { "ok": false, "status": 404,
            "error": "HTTP 404", "data": { "error": "nope" } }
        store.remove("http://backend:11434", "x:y", function(o, e) {})
        compare(String(ConfigStore.value("modelsRevision")), "fixwert")
    }

    function test_katalogEnthältAngefragteQwen36Modelle() {
        var tags = store.catalog.map(function(e) { return e.tag })
        verify(tags.indexOf("qwen3.6:35b-a3b") >= 0)
        verify(tags.indexOf("qwen3.6:27b") >= 0)
        // Jeder Katalog-Eintrag hat die Pflichtfelder für die UI
        for (var i = 0; i < store.catalog.length; i++) {
            var e = store.catalog[i]
            verify(e.tag.length > 0)
            verify(e.titel.length > 0)
            verify(e.beschreibung.length > 0)
        }
    }
}
