import QtQml
import net.niuton.aurora.core as Core

// Speaches-Client: OpenAI-kompatible STT/TTS-Endpunkte des lokalen
// Speaches-Servers (Quadlet). Health-Probe, Transkription und Synthese laufen
// über curl im ProcessRunner (Multipart-Upload bzw. POST→Datei — dafür gibt
// es bewusst keine C++-Erweiterung). Host-neutral, Primitive injizierbar.
//
// autoStart: wenn die Probe fehlschlägt und eine Unit bekannt ist, wird der
// Dienst per systemctl --user start angestoßen und die Probe wiederholt,
// bis er gesund ist oder das Timeout zuschlägt (dGPU-Power-Policy: kein
// Autostart beim Login, aber auf Feature-Wunsch).
QtObject {
    id: client

    property string endpoint: ""
    property bool available: false
    property bool autoStart: false
    property string unitName: "speaches"

    property var http: Core.Http
    property Component runnerFactory: Component { Core.ProcessRunner {} }
    property int transcribeTimeoutMs: 180000   // erster Lauf lädt das Modell nach
    property int speakTimeoutMs: 60000
    property int probeTimeoutMs: 4000
    property int autoStartTimeoutS: 180
    property int autoStartPollMs: 3000

    onEndpointChanged: probe()
    Component.onCompleted: probe()

    function probe() {
        if (endpoint === "") { available = false; return }
        http.getJson(endpoint + "/health", function(res) {
            if (res.ok) { client.available = true; return }
            client.available = false
            if (client.autoStart) client._autoStart()
        }, probeTimeoutMs)
    }

    // ---------- Auto-Start ----------

    property int _autoStartLeft: 0
    property bool _autoStartRunning: false

    function _autoStart() {
        if (_autoStartRunning || unitName === "") return
        _autoStartRunning = true
        _autoStartLeft = Math.max(1, Math.round(autoStartTimeoutS * 1000 / autoStartPollMs))
        var r = runnerFactory.createObject(client, { "timeoutMs": 30000 })
        r.finished.connect(function(code, out, err, trunc, to) {
            r.destroy()
            if (code !== 0) { client._autoStartRunning = false; return }
            startPollTimer.start()
        })
        r.failed.connect(function(m) { r.destroy(); client._autoStartRunning = false })
        r.start("systemctl", ["--user", "start", unitName])
    }

    property Timer startPollTimer: Timer {
        interval: client.autoStartPollMs
        repeat: true
        onTriggered: {
            if (client._autoStartLeft <= 0) {
                stop()
                client._autoStartRunning = false
                return
            }
            client._autoStartLeft--
            client.http.getJson(client.endpoint + "/health", function(res) {
                if (res.ok) {
                    startPollTimer.stop()
                    client._autoStartRunning = false
                    client.available = true
                }
            }, client.probeTimeoutMs)
        }
    }

    // ---------- STT ----------

    // cb(ok, textOderFehler); language "" = auto (Parameter wird weggelassen)
    function transcribe(wavPath, model, language, cb) {
        var args = ["-sS", "-f", "-X", "POST", endpoint + "/v1/audio/transcriptions",
                    "-F", "file=@" + wavPath,
                    "-F", "model=" + model,
                    "-F", "response_format=json"]
        if (language && language !== "" && language !== "auto")
            args.push("-F", "language=" + language)
        _curl(args, transcribeTimeoutMs, function(ok, out, err) {
            if (!ok) { cb(false, err); return }
            try {
                var j = JSON.parse(out)
                cb(true, String(j.text || "").trim())
            } catch (e) {
                cb(false, "Antwort nicht lesbar")
            }
        })
    }

    // ---------- TTS ----------

    // cb(ok, wavPathOderFehler)
    function speak(text, model, voice, wavOut, cb) {
        var body = { "model": model, "input": text, "response_format": "wav" }
        if (voice && voice !== "") body.voice = voice
        var args = ["-sS", "-f", "-X", "POST", endpoint + "/v1/audio/speech",
                    "-H", "Content-Type: application/json",
                    "-d", JSON.stringify(body),
                    "-o", wavOut]
        _curl(args, speakTimeoutMs, function(ok, out, err) {
            cb(ok, ok ? wavOut : err)
        })
    }

    // ---------- intern ----------

    function _curl(args, timeoutMs, cb) {
        var r = runnerFactory.createObject(client, { "timeoutMs": timeoutMs })
        r.finished.connect(function(code, out, err, trunc, to) {
            r.destroy()
            if (to) { cb(false, "", "Zeitüberschreitung"); return }
            if (code !== 0) { cb(false, out, err !== "" ? err : ("Exit " + code)); return }
            cb(true, out, "")
        })
        r.failed.connect(function(m) { r.destroy(); cb(false, "", m) })
        r.start("curl", args)
    }
}
