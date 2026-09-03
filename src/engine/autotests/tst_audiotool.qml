import QtQuick
import QtTest
import net.niuton.aurora.engine

Item {
    GenerateAudioTool { id: audTool }

    // Audio ist ein STREAMING-Job (kein Poll): Das Tool bestätigt sofort
    // (done), die fertige WAV spielt der Controller ab.
    function makeCtx(fn) { return { "audioGenFn": fn } }

    TestCase {
        name: "GenerateAudioTool"

        function test_metadata() {
            compare(audTool.name, "generate_audio")
            compare(audTool.category, "generate")
        }

        function test_executeNutztAudioGenFnUndMeldetSofort() {
            var got = null
            var doneCalled = null
            audTool.execute({ "prompt": "melodisches Klavierriff" },
                makeCtx(function(req, cb) {
                    got = req
                    cb({ "ok": true, "started": true })
                }),
                function(text, extra) { doneCalled = { "text": text, "extra": extra } })
            verify(doneCalled !== null)
            compare(got.prompt, "melodisches Klavierriff")
            compare(doneCalled.extra.status, "ok")
        }

        function test_keinAudioGenFnFehler() {
            var out = null
            audTool.execute({ "prompt": "x" }, {}, function(t, extra) { out = { "t": t, "e": extra } })
            verify(out.t.indexOf("nicht verfügbar") >= 0)
            compare(out.e.status, "error")
        }
        function test_fehlgeschlagenMeldetError() {
            var out = null
            audTool.execute({ "prompt": "x" }, makeCtx(function(req, cb) {
                cb({ "ok": false, "error": "zu wenig Guthaben" })
            }), function(t, extra) { out = { "t": t, "e": extra } })
            verify(out.t.indexOf("fehlgeschlagen") >= 0)
            compare(out.e.status, "error")
        }
    }
}