import QtQuick
import QtTest
import net.niuton.aurora.ui

// ModelTuner als Geschwister von TestCase (nicht als Kind) + "when: windowShown":
// nur so spiegelt tuner.visible echte effektive Sichtbarkeit wider (sonst bleibt
// visible in einer nie gezeigten TestCase-Szene dauerhaft false — siehe Muster in
// tst_knowledgeview.qml). Wird für den Snapshot-beim-Öffnen-Test gebraucht, der
// visible explizit umschaltet.
Item {
    id: root
    width: 400; height: 600

    ModelTuner {
        id: tuner
        anchors.fill: parent
    }
    SignalSpy { id: savedSpy; target: tuner; signalName: "saveRequested" }

    TestCase {
        name: "ModelTuner"
        when: windowShown

        // Öffnen simulieren: schließen (falls offen), params/modelName setzen, dann
        // wieder sichtbar machen — das ist der einzige Zeitpunkt, an dem der Tuner neu
        // snapshottet/lädt (onVisibleChanged: if (visible) _openSnapshot()).
        function reopenWith(modelName, params) {
            tuner.visible = false
            tuner.modelName = modelName
            tuner.params = params
            tuner.visible = true
        }

        function init() {
            reopenWith("", ({}))   // jeder Test startet frisch geöffnet, leer
            savedSpy.clear()
        }

        function test_ladenSetztAktivSchalterUndWerte() {
            reopenWith("qwen3.5:9b", { "temperature": 0.7, "num_ctx": 8192 })
            verify(tuner.temperatureActive)
            verify(tuner.numCtxActive)
            verify(!tuner.topPActive)          // nicht in params -> aus
            verify(!tuner.seedActive)
            compare(tuner.temperatureValue, 0.7)
            compare(tuner.numCtxText, "8192")
        }

        function test_speichernNurAktiveMitTypen() {
            tuner.topKActive = true
            tuner.topKValue = 40
            tuner.temperatureActive = true
            tuner.temperatureValue = 0.65
            tuner._save()
            compare(savedSpy.count, 1)
            var o = savedSpy.signalArguments[0][1]
            compare(o.top_k, 40)               // int (Math.round auf Slider-Wert)
            compare(o.temperature, 0.65)       // real
            verify(o.top_p === undefined)      // inaktiv -> fehlt
            verify(o.num_ctx === undefined)
        }

        function test_roundTrip() {
            reopenWith("qwen3.5:9b", { "temperature": 0.7, "top_k": 40, "num_ctx": 8192, "stop": ["</s>", "END"] })
            tuner._save()
            var o = savedSpy.signalArguments[0][1]
            compare(o.temperature, 0.7)
            compare(o.top_k, 40)
            compare(o.num_ctx, 8192)
            compare(o.stop.length, 2)
            compare(o.stop[1], "END")
        }

        function test_aktivAberLeeresFeldWirdAusgelassen() {
            tuner.numCtxActive = true
            tuner.numCtxText = ""              // aktiv, aber leer
            tuner._save()
            var o = savedSpy.signalArguments[0][1]
            verify(o.num_ctx === undefined)
        }

        // --- Snapshot-Verhalten (Task 7): kein Edit-Verlust/Falschspeichern bei
        // Auto-Modus-Modellwechsel während der Tuner offen ist. ---

        function test_paramsAenderungWaehrendOffenWirdIgnoriert() {
            reopenWith("gemma4:e4b", { "temperature": 0.5 })
            verify(tuner.temperatureActive)
            compare(tuner.temperatureValue, 0.5)

            tuner.temperatureValue = 0.9        // Nutzer editiert
            // Externe Änderung während der Tuner offen ist (z. B. Auto-Modus wechselt
            // activeModel/params) — darf die laufende Bearbeitung NICHT überschreiben.
            tuner.params = { "temperature": 0.2 }
            compare(tuner.temperatureValue, 0.9)
            verify(tuner.temperatureActive)
        }

        function test_modellwechselWaehrendOffenWirdIgnoriert() {
            reopenWith("gemma4:e4b", ({}))
            tuner.modelName = "qwen3.5:9b"      // Auto-Modus wechselt das aktive Modell
            compare(tuner._snapModel, "gemma4:e4b")
        }

        function test_speichernNutztGesnapshottesModell() {
            reopenWith("gemma4:e4b", ({}))
            tuner.modelName = "qwen3.5:9b"      // aktives Modell wechselt waehrend offen
            tuner.temperatureActive = true
            tuner.temperatureValue = 0.6
            tuner._save()
            compare(savedSpy.count, 1)
            compare(savedSpy.signalArguments[0][0], "gemma4:e4b")   // gesnapshottes Modell
            compare(savedSpy.signalArguments[0][1].temperature, 0.6)
        }

        function test_erneutesOeffnenLaedtNeueParams() {
            reopenWith("gemma4:e4b", { "temperature": 0.5 })
            tuner.temperatureValue = 0.9        // Edit, wird beim Schließen verworfen
            reopenWith("qwen3.5:9b", { "temperature": 0.3 })   // schließen + neu öffnen
            compare(tuner._snapModel, "qwen3.5:9b")
            compare(tuner.temperatureValue, 0.3)
        }

        // --- Out-of-range-Parameter (Task 9): Slider klemmt den ANGEZEIGTEN Wert
        // auf [from,to], aber ungerührtes Speichern darf den gespeicherten
        // Originalwert nicht durch den geklemmten Wert ersetzen. ---

        function test_outOfRangeWertBleibtBeimBlossenSpeichernErhalten() {
            reopenWith("qwen3.5:9b", { "temperature": 2.5, "top_k": 250 })
            verify(tuner.temperatureActive)
            compare(tuner.temperatureValue, 2.0)   // Slider klemmt die Anzeige auf maxValue
            compare(tuner.topKValue, 200)
            tuner._save()
            compare(savedSpy.count, 1)
            var o = savedSpy.signalArguments[0][1]
            compare(o.temperature, 2.5)            // Originalwert erhalten, nicht 2.0
            compare(o.top_k, 250)                  // Originalwert erhalten, nicht 200
        }

        function test_slideBewegungUeberschreibtOutOfRangeMitNeuemWert() {
            reopenWith("qwen3.5:9b", { "temperature": 2.5 })
            compare(tuner.temperatureValue, 2.0)
            tuner.temperatureValue = 1.2           // Nutzer bewegt den Slider aktiv
            tuner._save()
            var o = savedSpy.signalArguments[0][1]
            compare(o.temperature, 1.2)            // neuer Wert wird gespeichert
        }

        function test_inRangeWertUnveraendertBeimBlossenSpeichern() {
            reopenWith("qwen3.5:9b", { "temperature": 0.7 })
            tuner._save()
            var o = savedSpy.signalArguments[0][1]
            compare(o.temperature, 0.7)
        }
    }
}
