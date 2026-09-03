import QtQuick
import QtTest
import net.niuton.aurora.engine

Item {
    GenerateVideoTool { id: vidTool }

    // Video ist ein MINUTENLANGER async Job — das Tool darf den Chat-Loop
    // nicht blockieren: es meldet sofort "gestartet" (done), die fertige
    // Datei kommt später über appendGeneratedVideo (Controller).
    function makeCtx(fn) {
        return { "videoGenFn": fn }
    }

    TestCase {
        name: "GenerateVideoTool"

        function test_metadata() {
            compare(vidTool.name, "generate_video")
            compare(vidTool.category, "generate")
        }

        function test_executeNutztVideoGenFnUndMeldetSofort() {
            var got = null
            var doneCalled = null
            vidTool.execute({ "prompt": "ein wandernder Nebel überm Berg", "duration": 6 },
                makeCtx(function(req, cb) {
                    got = req
                    cb({ "ok": true, "started": true, "jobId": "job-1" })
                }),
                function(text, extra) { doneCalled = { "text": text, "extra": extra } })
            // done IMMER sofort (Chat läuft weiter; Video wird asynchron fertig)
            verify(doneCalled !== null)
            compare(got.prompt, "ein wandernder Nebel überm Berg")
            compare(got.duration, 6)
            compare(doneCalled.extra.status, "ok")
            compare(doneCalled.extra.started, true)
            // Kein Blockieren: done kam SOFORT (der Controller pollt später).
        }

        function test_keinVideoGenFnFehler() {
            var out = null
            vidTool.execute({ "prompt": "x" }, {}, function(t, extra) { out = { "t": t, "e": extra } })
            verify(out.t.indexOf("nicht verfügbar") >= 0)
            compare(out.e.status, "error")
        }

        function test_fehlgeschlagenMeldetError() {
            var out = null
            vidTool.execute({ "prompt": "x" }, makeCtx(function(req, cb) {
                cb({ "ok": false, "error": "Zu wenig Guthaben" })
            }), function(t, extra) { out = { "t": t, "e": extra } })
            verify(out.t.indexOf("fehlgeschlagen") >= 0)
            verify(out.t.indexOf("Zu wenig Guthaben") >= 0)
            compare(out.e.status, "error")
        }
    }
}