import QtQuick
import net.niuton.aurora.core

// Sprach-Eingabe: pw-record (PipeWire) + aurora-transcribe (whisper.cpp).
// Zustände: idle -> recording -> transcribing -> idle
// Prozesse über ProcessRunner (argv); Stop via SIGINT an die Prozessgruppe.
Item {
    id: recorder

    property string recState: "idle"
    property bool available: false
    property string language: "auto"
    // Fest gewähltes Mikrofon aus den Einstellungen ("" = System-Standard/Auto-Probe).
    // Hat Vorrang vor der Auto-Ermittlung, weil eine Byte-Probe ein totes Mikrofon
    // (streamt trotzdem Null-Samples) nicht von einem funktionierenden unterscheiden kann.
    property string preferredSource: ""
    // Funktionierende Aufnahmequelle (ermittelt durch Probe; "" = Systemstandard)
    property string _target: ""
    // Erst nach dem Aufbau auf preferredSource-Änderungen reagieren, sonst
    // probt die anfängliche Config-Bindung zusätzlich zum onExpandedChanged.
    property bool _ready: false

    Component.onCompleted: _ready = true
    onPreferredSourceChanged: if (_ready) checkAvailability()

    signal transcriptReady(string text)
    signal errorOccurred(string message)

    readonly property string _wav: FileIO.standardPath("cache") + "/aurora-voice.wav"
    readonly property string _transcribe: FileIO.standardPath("home") + "/.local/bin/aurora-transcribe"

    ProcessRunner {
        id: probeProc
        onFinished: function(code, out, err, trunc, to) {
            var s = out.trim()
            if (s.indexOf("OK") === 0) {
                recorder.available = true
                recorder._target = s.length > 3 ? s.substring(3).trim() : ""
            } else {
                recorder.available = false
            }
        }
        onFailed: function(m) { recorder.available = false }
    }

    ProcessRunner {
        id: recordProc
        onFinished: function(code, out, err, trunc, to) {
            if (recorder.recState === "transcribing") {
                // regulärer Stop: pw-record per SIGINT beendet -> Transkription
                recorder._startTranscription()
            } else if (recorder.recState === "recording") {
                // pw-record ist von selbst gestorben (z.B. PipeWire-Fehler):
                // sauber zurück nach idle, sonst hängt der Zustandsautomat
                recorder.recState = "idle"
                recorder.errorOccurred("Aufnahme unerwartet beendet")
            }
        }
        onFailed: function(m) {
            recorder.recState = "idle"
            recorder.errorOccurred("Aufnahme fehlgeschlagen: " + m)
        }
    }

    ProcessRunner {
        id: transcribeProc
        // Großzügiger, aber endlicher Timeout: ohne ihn (Default 0 = unbegrenzt)
        // hängt ein gestörtes aurora-transcribe für immer, recState bleibt bei
        // "transcribing" und der Mikro-Knopf ist tot (toggle() kennt nur
        // idle/recording). Bei Zeitüberschreitung killt ProcessRunner die
        // Prozessgruppe und meldet über finished(..., timedOut=true) — hier
        // klar von "kein Text erkannt" unterschieden, damit die Fehlermeldung
        // den echten Hänger benennt statt einer leeren Transkription.
        timeoutMs: 60000
        onFinished: function(code, out, err, trunc, to) {
            // Verspätetes finished() nach cancelTranscription() verwerfen:
            // recState steht dann bereits auf "idle" — ohne den Guard meldete
            // der Abbruch fälschlich "Keine Sprache erkannt".
            if (recorder.recState !== "transcribing") return
            recorder.recState = "idle"
            if (to) { recorder.errorOccurred("Transkription fehlgeschlagen: Zeitüberschreitung"); return }
            var text = out.trim()
            if (text !== "") recorder.transcriptReady(text)
            else recorder.errorOccurred("Keine Sprache erkannt")
        }
        onFailed: function(m) {
            recorder.recState = "idle"
            recorder.errorOccurred("Transkription fehlgeschlagen: " + m)
        }
    }

    // Prüft Tools/Modell und ermittelt eine Aufnahmequelle, die wirklich Daten
    // liefert (manche Systeme haben ein totes Default-Mikrofon). Fester Shell-
    // Block OHNE JEDE Interpolation (einzige erlaubte Shell-Nutzung hier) —
    // Pfade laufen über $HOME, das die Shell selbst expandiert; so bleibt der
    // String ein Literal und Leerzeichen/Sonderzeichen in Pfaden sind egal.
    function checkAvailability() {
        // Fest gewähltes Mikrofon: nur Werkzeuge/Modell prüfen, Quelle wird direkt
        // verwendet (siehe start()). Kein Shell-String mit Interpolation nötig.
        if (preferredSource !== "") {
            var toolsScript =
                "command -v pw-record >/dev/null && test -x \"$HOME/.local/bin/aurora-transcribe\""
                + " && test -f \"$HOME/.local/share/aurora/whisper/ggml-small.bin\""
                + " && echo OK || echo NOMIC"
            probeProc.start("sh", ["-c", toolsScript])
            return
        }
        var probeScript =
            "command -v pw-record >/dev/null && test -x \"$HOME/.local/bin/aurora-transcribe\""
            + " && test -f \"$HOME/.local/share/aurora/whisper/ggml-small.bin\" || exit 0; "
            + "P=\"$HOME/.cache/aurora/aurora-probe.wav\"; mkdir -p \"$HOME/.cache/aurora\"; "
            + "probe() { rm -f \"$P\"; timeout 0.4 pw-record ${1:+--target \"$1\"} --rate 16000 --channels 1 \"$P\" 2>/dev/null; "
            + "[ $(stat -c %s \"$P\" 2>/dev/null || echo 0) -gt 4000 ]; }; "
            + "if probe \"\"; then echo OK; exit 0; fi; "
            + "for s in $(pactl list sources short 2>/dev/null | awk '$2 ~ /^alsa_input/ {print $2}'); do "
            + "if probe \"$s\"; then echo \"OK $s\"; exit 0; fi; done; "
            + "echo NOMIC"
        probeProc.start("sh", ["-c", probeScript])
    }

    function toggle() {
        if (recState === "idle") start()
        else if (recState === "recording") stop()
        else if (recState === "transcribing") cancelTranscription()
    }

    // Manueller Abbruch aus "transcribing": ohne diesen Ausstieg bliebe der
    // Mikro-Knopf bis zum 60-s-Timeout tot (toggle() kannte den Zustand nicht).
    // SIGKILL statt SIGTERM: die Transkription hält keinen schützenswerten
    // Zustand (liest nur das WAV, schreibt nach stdout) und soll sofort sterben,
    // damit ein zügig folgender Neustart nicht am noch laufenden Runner hängt
    // (start() auf laufendem ProcessRunner ist ein No-op). Das verspätete
    // finished() des abgebrochenen Prozesses verwirft der recState-Guard im
    // Handler (recState steht dann schon auf "idle").
    function cancelTranscription() {
        if (recState !== "transcribing") return
        recState = "idle"
        if (transcribeProc.running) transcribeProc.kill()
        errorOccurred("Transkription abgebrochen")
    }

    function start() {
        if (recState !== "idle") return
        recState = "recording"
        // Fest gewähltes Mikrofon hat Vorrang vor der Auto-Ermittlung.
        var src = preferredSource !== "" ? preferredSource : _target
        var args = []
        if (src !== "") { args.push("--target"); args.push(src) }
        args.push("--rate"); args.push("16000")
        args.push("--channels"); args.push("1")
        args.push(_wav)
        recordProc.start("pw-record", args)
    }

    function stop() {
        if (recState !== "recording") return
        recState = "transcribing"
        // pw-record sanft beenden (SIGINT=2 an die Prozessgruppe); WAV bleibt gültig.
        recordProc.sendSignal(2)
    }

    function _startTranscription() {
        transcribeProc.start(_transcribe, [_wav, language])
    }
}
