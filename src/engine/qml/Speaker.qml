import QtQuick
import net.niuton.aurora.core

// Sprachausgabe: Piper TTS schreibt eine WAV-Datei (Text über stdin), aplay
// spielt sie. Prozesse laufen über ProcessRunner (argv-only, sauberes stop()
// über Prozessgruppen-Signal statt pkill).
Item {
    id: speaker

    property bool available: false
    property bool speaking: false
    // Stimmenname, z.B. "de_DE-thorsten-high" (liegt in ~/.local/share/aurora/piper/)
    property string voice: "de_DE-thorsten-high"

    readonly property string _voiceDir: FileIO.standardPath("appData") + "/piper/"
    readonly property string _piper: FileIO.standardPath("home") + "/.local/bin/piper"
    readonly property string _wav: FileIO.standardPath("cache") + "/aurora-tts.wav"

    // Neuer Text, der auf das (asynchrone) Ende eines noch sterbenden Laufs
    // wartet: terminate() ist SIGTERM, der Runner ist erst nach finished wieder
    // startbar — ohne dieses Parken würde ein schnelles erneutes speak()
    // verschluckt (start() auf laufendem Runner ist ein No-op).
    property string _pendingText: ""

    // Meldet TTS-Fehler nach außen (AuroraController zeigt sie als transienten
    // Status). Wird NICHT emittiert, wenn gerade ein neuer speak()-Aufruf den
    // alten Lauf abgelöst hat (_pendingText gesetzt) — das ist kein Nutzer-
    // sichtbarer Fehler, sondern der interne Neustart-Pfad.
    signal errorOccurred(string message)

    ProcessRunner {
        id: piperProc
        onFinished: function(code, out, err, trunc, to) {
            if (speaker._pendingText !== "") { speaker._maybeStartPending(); return }
            if (!speaker.speaking) return              // per stop() abgebrochen
            if (code !== 0) {
                speaker.speaking = false
                speaker.errorOccurred("Sprachausgabe fehlgeschlagen" + (err ? ": " + err : ""))
                return
            }
            aplayProc.start("aplay", ["-q", speaker._wav])
        }
        onFailed: function(m) {
            if (speaker._pendingText !== "") { speaker._maybeStartPending(); return }
            speaker.speaking = false
            speaker.errorOccurred("Sprachausgabe fehlgeschlagen: " + m)
        }
    }

    ProcessRunner {
        id: aplayProc
        onFinished: function(code, out, err, trunc, to) {
            if (speaker._pendingText !== "") { speaker._maybeStartPending(); return }
            speaker.speaking = false
        }
        onFailed: function(m) {
            if (speaker._pendingText !== "") { speaker._maybeStartPending(); return }
            speaker.speaking = false
            speaker.errorOccurred("Sprachausgabe fehlgeschlagen: " + m)
        }
    }

    // Probe: aplay muss startbar sein, piper-Binary und Stimme müssen existieren.
    // Piper braucht NEBEN voice.onnx auch voice.onnx.json (Modell-Konfiguration) —
    // ohne die JSON-Datei meldet sich die Stimme sonst fälschlich verfügbar und
    // scheitert erst beim ersten speak() still (piper bricht ab, onFailed/Exit
    // ungesehen ohne diesen Fix).
    ProcessRunner {
        id: aplayProbe
        onFinished: function(code, out, err, trunc, to) {
            speaker.available = (code === 0)
                && FileIO.exists(speaker._piper)
                && FileIO.exists(speaker._voiceDir + speaker.voice + ".onnx")
                && FileIO.exists(speaker._voiceDir + speaker.voice + ".onnx.json")
        }
        onFailed: function(m) { speaker.available = false }
    }

    function checkAvailability() {
        aplayProbe.start("aplay", ["--version"])
    }

    // Markdown/Format-Zeichen entfernen, damit die Stimme nur Inhalt liest
    function _cleanForSpeech(text) {
        var t = text
        t = t.replace(/```[\s\S]*?```/g, ". Codeblock. ")
        t = t.replace(/`([^`]*)`/g, "$1")
        t = t.replace(/!\[[^\]]*\]\([^)]*\)/g, "")
        t = t.replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
        t = t.replace(/^#{1,6}\s+/gm, "")
        t = t.replace(/[*_~#>|]/g, "")
        t = t.replace(/\s+/g, " ").trim()
        return t
    }

    function speak(text) {
        var clean = _cleanForSpeech(text)
        if (clean === "") return
        _pendingText = clean
        speaking = true
        if (piperProc.running) piperProc.terminate()
        if (aplayProc.running) aplayProc.terminate()
        _maybeStartPending()   // startet sofort, wenn nichts (mehr) läuft
    }

    // Startet die Synthese, sobald beide Runner frei sind (finished-Handler
    // rufen erneut hierher, wenn ein alter Lauf gerade gestorben ist).
    function _maybeStartPending() {
        if (_pendingText === "" || piperProc.running || aplayProc.running) return
        var text = _pendingText
        _pendingText = ""
        piperProc.start(_piper, ["--model", _voiceDir + voice + ".onnx",
                                 "--output_file", _wav])
        piperProc.writeStdin(text)
        piperProc.closeStdin()
    }

    function stop() {
        _pendingText = ""
        if (piperProc.running) piperProc.terminate()
        if (aplayProc.running) aplayProc.terminate()
        speaking = false
    }
}
