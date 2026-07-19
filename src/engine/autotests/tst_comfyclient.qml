import QtQuick
import QtTest
import net.niuton.aurora.core
import net.niuton.aurora.engine

// Deckt zwei Task-5-Fixes ab (Audit ComfyClient.qml:8 + :51):
// - Fix A: Node-Mutationen (wf.pos/latent/sampler) werden vor der Mutation gegen ein
//   Template ohne semantische Node-IDs abgesichert -> failed() + busy=false statt
//   uncaught TypeError (der die Instanz dauerhaft "busy" haengen liess).
// - Fix B: onEndpointChanged ruft checkAvailability() neu auf; ein leerer Endpoint
//   setzt available synchron auf false.
// Bewusst OHNE echtes Netz: nur der synchrone Guard-/Leer-Endpoint-Zweig wird geprueft,
// der reale Http-Roundtrip (Fix A "gut"-Pfad, Fix B nicht-leerer Endpoint) bleibt
// unangetastet fire-and-forget (kein tryCompare/wait noetig, kein Flake-Risiko).
TestCase {
    name: "ComfyClient"

    ComfyClient { id: comfy }

    property var failMsgs: []

    function _onFailed(msg) { failMsgs.push(msg) }

    function init() {
        failMsgs = []
        comfy.failed.connect(_onFailed)
    }

    function cleanup() {
        comfy.failed.disconnect(_onFailed)
    }

    function test_generateMitFehlendemNodeBeendetSauberUndEntsperrtNaechstenLauf() {
        var dir = FileIO.standardPath("appData") + "/workflows"
        var wr = FileIO.writeText(dir + "/tst_comfy_kaputt.json",
            JSON.stringify({ "latent": { "inputs": {} }, "sampler": { "inputs": {} } }))   // wf.pos fehlt
        verify(wr.ok)

        comfy.generate({ prompt: "Ein Berg", model: "tst_comfy_kaputt" })

        compare(comfy.busy, false)
        compare(comfy.statusText, "")
        compare(failMsgs.length, 1)
        verify(failMsgs[0].indexOf("Workflow-Template unpassend") >= 0)

        // Kein dauerhafter Lock: ein zweiter Aufruf wird NICHT mit
        // "Es läuft bereits eine Generierung" abgewiesen, sondern läuft erneut
        // (und scheitert wieder sauber am selben kaputten Template).
        failMsgs = []
        comfy.generate({ prompt: "Noch mal", model: "tst_comfy_kaputt" })
        compare(failMsgs.length, 1)
        verify(failMsgs[0].indexOf("läuft bereits") === -1)
        verify(failMsgs[0].indexOf("Workflow-Template unpassend") >= 0)
        compare(comfy.busy, false)
    }

    function test_checkAvailabilityLeererEndpointSetztAvailableFalse() {
        comfy.endpoint = ""
        comfy.available = true   // erzwungen, um die Wirkung von checkAvailability() zu beobachten
        comfy.checkAvailability()
        compare(comfy.available, false)
    }

    function test_onEndpointChangedRuftCheckAvailabilityErneutAuf() {
        // Erster Wechsel (leer -> nicht-leer) stößt einen echten, aber bewusst
        // ignorierten Http-Probe an (127.0.0.1 = kein DNS, keine Wartezeit nötig,
        // wir werten sein Ergebnis nirgends aus).
        comfy.endpoint = "http://127.0.0.1:1"
        comfy.available = true   // erzwungen zurückgesetzt, unabhängig vom ersten Probe

        // Zweiter Wechsel (nicht-leer -> leer) muss onEndpointChanged -> checkAvailability()
        // auslösen; deren Leer-Zweig ist synchron, also ist die Prüfung sofort deterministisch.
        comfy.endpoint = ""
        compare(comfy.available, false)
    }

    // Gültiges Mini-Template (pos/latent/sampler mit inputs) für die Lauf-Tests.
    function _writeOkTemplate() {
        var dir = FileIO.standardPath("appData") + "/workflows"
        return FileIO.writeText(dir + "/tst_comfy_ok.json",
            JSON.stringify({ "pos": { "inputs": {} }, "latent": { "inputs": {} },
                             "sampler": { "inputs": {} } }))
    }

    // cancel(): der laufende Lauf wird lokal verworfen — busy/statusText sofort
    // zurückgesetzt, und der noch unterwegs befindliche async Callback (hier:
    // Verbindungsfehler auf totem Port) darf weder failed noch finished feuern.
    function test_cancelVerwirftLaufOhneSignale() {
        verify(_writeOkTemplate().ok)
        comfy.endpoint = "http://127.0.0.1:1"   // ECONNREFUSED kommt sofort, aber async
        var finCount = 0
        var onFin = function() { finCount++ }
        comfy.finished.connect(onFin)

        comfy.generate({ prompt: "Katze", model: "tst_comfy_ok", toolInitiated: true })
        compare(comfy.busy, true)
        comfy.cancel()
        compare(comfy.busy, false)
        compare(comfy.statusText, "")
        compare(comfy.toolInitiated, false)

        // Dem Fehler-Callback Zeit geben, einzutreffen — er muss verworfen werden.
        wait(200)
        compare(failMsgs.length, 0)
        compare(finCount, 0)
        comfy.finished.disconnect(onFin)
    }

    // Manueller Weg OHNE cancel: unverändert — der Fehler meldet wie bisher
    // über failed() und busy geht zurück.
    function test_manuellerWegOhneCancelMeldetWieBisher() {
        verify(_writeOkTemplate().ok)
        comfy.endpoint = "http://127.0.0.1:1"
        comfy.generate({ prompt: "Katze", model: "tst_comfy_ok" })
        compare(comfy.busy, true)
        tryCompare(comfy, "busy", false, 5000)
        compare(failMsgs.length, 1)
        verify(failMsgs[0].indexOf("ComfyUI nicht erreichbar") >= 0)
    }

    // Sofortiger Neustart nach cancel (selbe Event-Runde): der verworfene
    // alte Callback darf den neuen Lauf nicht stören, der neue Lauf meldet
    // wieder ganz normal (genau EIN failed — das des neuen Laufs).
    function test_neuerLaufNachCancelMeldetWiederNormal() {
        verify(_writeOkTemplate().ok)
        comfy.endpoint = "http://127.0.0.1:1"
        comfy.generate({ prompt: "alt", model: "tst_comfy_ok" })
        comfy.cancel()
        comfy.generate({ prompt: "neu", model: "tst_comfy_ok" })
        tryCompare(comfy, "busy", false, 5000)
        compare(failMsgs.length, 1)
        verify(failMsgs[0].indexOf("ComfyUI nicht erreichbar") >= 0)
    }
}
