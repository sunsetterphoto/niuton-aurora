import QtQuick
import QtTest
import net.niuton.aurora.ui

TestCase {
    name: "ModelTuner"

    ModelTuner {
        id: tuner
        width: 400
        height: 600
    }
    SignalSpy { id: savedSpy; target: tuner; signalName: "saveRequested" }

    function init() {
        tuner.params = ({})   // jeder Test startet leer (setzt alle Schalter aus)
        savedSpy.clear()
    }

    function test_ladenSetztAktivSchalterUndWerte() {
        tuner.params = { "temperature": 0.7, "num_ctx": 8192 }
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
        var o = savedSpy.signalArguments[0][0]
        compare(o.top_k, 40)               // int (Math.round auf Slider-Wert)
        compare(o.temperature, 0.65)       // real
        verify(o.top_p === undefined)      // inaktiv -> fehlt
        verify(o.num_ctx === undefined)
    }

    function test_roundTrip() {
        tuner.params = { "temperature": 0.7, "top_k": 40, "num_ctx": 8192, "stop": ["</s>", "END"] }
        tuner._save()
        var o = savedSpy.signalArguments[0][0]
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
        var o = savedSpy.signalArguments[0][0]
        verify(o.num_ctx === undefined)
    }
}
