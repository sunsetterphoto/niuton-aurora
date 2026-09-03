import QtQuick
import QtTest
import net.niuton.aurora.engine

// OpenRouter-Audio-GENERIERUNG (nur Ausgabe; liegt in der Chat-API).
// Fakten (Doku, verifiziert):
//   Request : POST /v1/chat/completions, modalities ["text","audio"],
//             audio {voice, format:"wav"}, stream:true  (Audio ERFORDERT streaming)
//   Response: SSE-Chunks mit delta.audio.data (base64-Fragmente, zusammensetzen)
//             + delta.audio.transcript (Text)
// Lokale Wiedergabe: aplay (WAV) — kein neues Media-Framework nötig.
TestCase {
    name: "AudioClient"

    QtObject {
        id: mockHttp
        property var calls: []
        function postJson(url, body, cb, timeoutMs, headers) {
            calls.push({ "method": "post", "url": url, "body": body,
                         "cb": cb, "timeout": timeoutMs, "headers": headers })
        }
        function answer(i, result) { if (calls[i].cb) calls[i].cb(result) }
        function last() { return calls[calls.length - 1] }
    }

    // KeyRing-Mock (Auth)
    QtObject {
        id: mockKeyring
        property var reads: []
        property string secret: "sk-test"
        function readSecret(keyRef, cb) {
            reads.push(keyRef)
            cb({ "ok": true, "secret": mockKeyring.secret })
        }
    }

    Component {
        id: mockSseFactory
        QtObject {
            signal objectReceived(var obj)
            signal finished(bool ok, int status, string error)
            property int idleTimeoutMs: 0
            property bool sse: false
            property string postedUrl: ""
            property var postedBody: null
            property var postedHeaders: null
            property bool aborted: false
            function post(url, body, headers) { postedUrl = url; postedBody = body; postedHeaders = headers }
            function abort() { aborted = true }
        }
    }

    AudioClient {
        id: client
        baseUrl: "https://openrouter.ai/api"
        http: mockHttp
        keyring: mockKeyring
        keyRef: "openrouter"
        sseFactory: mockSseFactory
    }

    function init() {
        mockHttp.calls = []
        mockKeyring.reads = []
        mockKeyring.secret = "sk-test"
        client.keyRef = "openrouter"
    }

    // ---------- Request ----------

    function test_generateSendetModalitiesUndAudio() {
        var got = null
        client.generate("Sag Hallo", { "voice": "alloy", "format": "wav" },
                        function(r) { got = r })
        var job = client._lastJob
        var s = job._stream
        compare(s.postedUrl, "https://openrouter.ai/api/v1/chat/completions")
        compare(s.sse, true)
        compare(s.postedBody.stream, true)
        compare(s.postedBody.modalities[0], "text")
        compare(s.postedBody.modalities[1], "audio")
        compare(s.postedBody.audio.voice, "alloy")
        compare(s.postedBody.audio.format, "wav")
        compare(s.postedBody.messages[0].content, "Sag Hallo")
        compare(s.postedHeaders["Authorization"], "Bearer sk-test")
    }

    // ---------- Response: Audio-Fragmente + Transcript ----------

    function test_audioFragmenteWerdenZusammengesetzt() {
        var got = null
        client.generate("Hallo", {}, function(r) { got = r })
        var s = client._lastJob._stream
        s.objectReceived({ "choices": [{ "delta": { "audio": { "data": "QUJD", "transcript": "Hal" } } }] })
        s.objectReceived({ "choices": [{ "delta": { "audio": { "data": "REVG" } } }] })
        s.finished(true, 200, "")
        verify(got.ok)
        compare(got.wavBase64, "QUJDREVG")      // zusammengesetzt
        compare(got.transcript, "Hal")           // Transkript
    }

    function test_keinAudioDataMeldetLeer() {
        var got = null
        client.generate("x", {}, function(r) { got = r })
        var s = client._lastJob._stream
        s.objectReceived({ "choices": [{ "delta": { "content": "nur text" } }] })
        s.finished(true, 200, "")
        verify(got.ok)
        compare(got.wavBase64, "")
        compare(got.transcript, "")
    }

    function test_streamFehlerMeldetOkFalse() {
        var got = null
        client.generate("x", {}, function(r) { got = r })
        client._lastJob._stream.finished(false, 500, "HTTP 500")
        verify(!got.ok)
        verify(got.error !== undefined)
    }

    function test_abort() {
        var got = null
        client.generate("x", {}, function(r) { got = r })
        var s = client._lastJob._stream
        client.abort()
        compare(s.aborted, true)
        // abort ist still: kein done
        verify(got === null)
    }
}