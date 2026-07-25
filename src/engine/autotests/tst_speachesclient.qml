import QtQuick
import QtTest
import net.niuton.aurora.engine

// SpeachesClient ohne Netz/Prozesse: Mock-Http für /health, Mock-Runner für
// curl-Aufrufe (zeichnet argv, finished/failed von Hand auslösbar).
TestCase {
    name: "SpeachesClient"

    property var runners: []

    component MockRunner: QtObject {
        property int timeoutMs: 0
        property var started: null
        signal finished(int exitCode, string stdoutText, string stderrText,
                        bool truncated, bool timedOut)
        signal failed(string message)
        function start(program, args) { started = { "program": program, "args": args } }
        function destroy() {}
    }

    property QtObject mockHttp: QtObject {
        property var calls: []
        function getJson(url, cb, t) { calls.push({ "url": url, "cb": cb }) }
        function answer(i, res) { calls[i].cb(res) }
        function findLast(part) {
            for (var i = calls.length - 1; i >= 0; i--)
                if (calls[i].url.indexOf(part) !== -1) return i
            return -1
        }
    }

    SpeachesClient {
        id: client
        endpoint: ""   // Tests setzen ihn gezielt (Probe feuert bei Änderung)
        http: mockHttp
        runnerFactory: Component { MockRunner {} }
        autoStartPollMs: 1
        autoStartTimeoutS: 1
    }

    function init() {
        runners = []
        mockHttp.calls = []
        client.autoStart = false
        // Endpoint zurücksetzen, damit die Zuweisung im Test eine frische
        // Probe auslöst (gleicher Wert würde onEndpointChanged nicht feuern
        // und die Tests würden alte, schon beantwortete Calls sehen).
        client.endpoint = ""
    }

    function test_probeGesundSetztAvailable() {
        client.endpoint = "http://speaches:8000"
        var i = mockHttp.findLast("/health")
        verify(i !== -1)
        mockHttp.answer(i, { "ok": true })
        compare(client.available, true)
    }

    function test_probeKrankNichtVerfuegbarKeinAutoStart() {
        client.autoStart = false
        client.endpoint = "http://speaches:8000"
        var i = mockHttp.findLast("/health")
        mockHttp.answer(i, { "ok": false })
        compare(client.available, false)
    }

    function test_autoStartStartetUnitUndProbtErneut() {
        client.autoStart = true
        client.unitName = "speaches"
        client.endpoint = "http://speaches:8000"
        mockHttp.answer(mockHttp.findLast("/health"), { "ok": false })
        compare(client.available, false)
        // Auto-Start muss systemctl --user start speaches auslösen
        tryVerify(function() { return client._autoStartRunning }, 2000)
        // Runner ist in dieser Implementierung nicht in einer Map auffindbar —
        // wir greifen über das Signal: der letzte erzeugte Mock-Runner steht
        // in runners (s. runnerFactory-Verkettung unten)
        verify(runners.length > 0)
        compare(runners[0].started.program, "systemctl")
        compare(runners[0].started.args.join(" "), "--user start speaches")
        runners[0].finished(0, "", "", false, false)
        // Poll-Timer (1 ms) fragt /health erneut, bis ok
        tryVerify(function() { return mockHttp.findLast("/health") >= 0 && mockHttp.calls.length >= 2 }, 2000)
        mockHttp.answer(mockHttp.findLast("/health"), { "ok": true })
        tryVerify(function() { return client.available }, 2000)
    }

    function test_transcribeBautCurlMultipart() {
        client.endpoint = "http://speaches:8000"
        mockHttp.answer(mockHttp.findLast("/health"), { "ok": true })
        var result = null
        client.transcribe("/tmp/x.wav", "Systran/faster-whisper-large-v3", "de",
            function(ok, text) { result = { "ok": ok, "text": text } })
        verify(runners.length > 0)
        var a = runners[runners.length - 1].started.args
        compare(a[0], "-sS")
        verify(a.indexOf("http://speaches:8000/v1/audio/transcriptions") !== -1)
        verify(a.indexOf("file=@/tmp/x.wav") !== -1)
        verify(a.indexOf("model=Systran/faster-whisper-large-v3") !== -1)
        verify(a.indexOf("language=de") !== -1)
        runners[runners.length - 1].finished(0, '{"text":"Hallo Welt"}', "", false, false)
        compare(result.ok, true)
        compare(result.text, "Hallo Welt")
    }

    function test_transcribeAutoLaesstLanguageWeg() {
        client.endpoint = "http://speaches:8000"
        mockHttp.answer(mockHttp.findLast("/health"), { "ok": true })
        client.transcribe("/tmp/x.wav", "m", "auto", function(ok, text) {})
        var a = runners[runners.length - 1].started.args
        compare(a.indexOf("language=auto"), -1)
    }

    function test_transcribeFehlerGibtFehlertext() {
        client.endpoint = "http://speaches:8000"
        mockHttp.answer(mockHttp.findLast("/health"), { "ok": true })
        var result = null
        client.transcribe("/tmp/x.wav", "m", "", function(ok, text) { result = { "ok": ok, "text": text } })
        runners[runners.length - 1].finished(22, "", "HTTP 500", false, false)
        compare(result.ok, false)
        compare(result.text, "HTTP 500")
    }

    function test_speakBautJsonPostUndDatei() {
        client.endpoint = "http://speaches:8000"
        mockHttp.answer(mockHttp.findLast("/health"), { "ok": true })
        var result = null
        client.speak("Hallo", "speaches-ai/piper-de_DE-thorsten-high", "", "/tmp/out.wav",
            function(ok, path) { result = { "ok": ok, "path": path } })
        var a = runners[runners.length - 1].started.args
        verify(a.indexOf("http://speaches:8000/v1/audio/speech") !== -1)
        verify(a.indexOf("-o") !== -1 && a.indexOf("/tmp/out.wav") !== -1)
        var di = a.indexOf("-d")
        var body = JSON.parse(a[di + 1])
        compare(body.model, "speaches-ai/piper-de_DE-thorsten-high")
        compare(body.input, "Hallo")
        compare(body.response_format, "wav")
        verify(body.voice === undefined)   // leere Stimme wird weggelassen
        runners[runners.length - 1].finished(0, "", "", false, false)
        compare(result.ok, true)
        compare(result.path, "/tmp/out.wav")
    }

    // Fabrik-Verkettung: jeder erzeugte Runner landet in runners
    property Component _factoryTap: Component {
        MockRunner {
            Component.onCompleted: runners.push(this)
        }
    }
    Component.onCompleted: client.runnerFactory = _factoryTap
}
