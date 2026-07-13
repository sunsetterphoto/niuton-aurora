import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM
import net.niuton.aurora.core

KCM.SimpleKCM {
    id: root

    property var voices: []
    property var micSources: [{ "value": "", "label": "System-Standard" }]
    property string testStatus: ""

    readonly property var sttLanguages: [
        { "value": "auto", "label": "Automatisch erkennen" },
        { "value": "de", "label": "Deutsch" },
        { "value": "en", "label": "Englisch" }
    ]

    Component.onCompleted: { scanVoices(); scanMics() }

    readonly property string _piperDir: FileIO.standardPath("appData") + "/piper/"
    readonly property string _testWav: FileIO.standardPath("cache") + "/aurora-voicetest.wav"

    // Aufnahmequellen via PipeWire/PulseAudio auflisten (Monitore ausgeblendet).
    ProcessRunner {
        id: scanMicsProc
        onFinished: function(code, out, err, trunc, to) {
            var list = [{ "value": "", "label": "System-Standard" }]
            try {
                var arr = JSON.parse(out)
                for (var i = 0; i < arr.length; i++) {
                    var name = arr[i].name || ""
                    if (name === "" || name.endsWith(".monitor")) continue
                    var label = (arr[i].description && arr[i].description !== "")
                        ? arr[i].description : name
                    var parts = name.split("__")
                    if (parts.length >= 3) label += " · " + parts[parts.length - 2]
                    list.push({ "value": name, "label": label })
                }
            } catch (e) { /* Ausgabe unlesbar: nur System-Standard anbieten */ }
            // Gespeicherte, aktuell nicht vorhandene Quelle sichtbar halten
            var savedSource = ConfigStore.value("sttSource")
            var found = false
            for (var j = 0; j < list.length; j++)
                if (list[j].value === savedSource) { found = true; break }
            if (!found && savedSource !== "")
                list.push({ "value": savedSource, "label": "(nicht verbunden) " + savedSource })
            root.micSources = list
            micCombo.refresh()
        }
        onFailed: function(m) { micCombo.refresh() }
    }

    function scanMics() {
        scanMicsProc.start("pactl", ["-f", "json", "list", "sources"])
    }

    ProcessRunner {
        id: testPiper
        onFinished: function(code, out, err, trunc, to) {
            if (code === 0) testAplay.start("aplay", ["-q", root._testWav])
            else root.testStatus = ""
        }
        onFailed: function(m) { root.testStatus = "" }
    }

    ProcessRunner {
        id: testAplay
        onFinished: function(code, out, err, trunc, to) { root.testStatus = "" }
        onFailed: function(m) { root.testStatus = "" }
    }

    function scanVoices() {
        var ld = FileIO.listDir(_piperDir)
        var names = []
        if (ld.ok) {
            for (var i = 0; i < ld.entries.length; i++) {
                var n = ld.entries[i].name
                if (!ld.entries[i].isDir && n.endsWith(".onnx"))
                    names.push(n.substring(0, n.length - 5))
            }
        }
        root.voices = names
        voiceCombo.refresh()
    }

    function testVoice(voice) {
        if (testPiper.running || testAplay.running) return   // Test läuft schon
        testStatus = "Spiele Testsatz..."
        testPiper.start(FileIO.standardPath("home") + "/.local/bin/piper",
                        ["--model", _piperDir + voice + ".onnx", "--output_file", _testWav])
        testPiper.writeStdin("Hallo! Ich bin Aurora, deine lokale Assistentin.")
        testPiper.closeStdin()
    }

    Kirigami.FormLayout {
        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: "Sprachausgabe (Piper TTS)"
        }

        RowLayout {
            Kirigami.FormData.label: "Stimme:"

            QQC2.ComboBox {
                id: voiceCombo
                Layout.preferredWidth: Kirigami.Units.gridUnit * 14
                model: root.voices
                function refresh() {
                    var idx = find(ConfigStore.value("ttsVoice"))
                    if (idx >= 0) currentIndex = idx
                }
                onActivated: ConfigStore.setValue("ttsVoice", currentText)
            }

            QQC2.Button {
                text: "Anhören"
                icon.name: "media-playback-start"
                enabled: voiceCombo.currentText !== ""
                onClicked: root.testVoice(voiceCombo.currentText)
            }
        }

        QQC2.CheckBox {
            Kirigami.FormData.label: "Auto-Vorlesen:"
            text: "Antworten automatisch vorlesen"
            checked: (ConfigStore.revision, ConfigStore.value("ttsAutoSpeak"))
            onToggled: ConfigStore.setValue("ttsAutoSpeak", checked)
        }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: "Spracheingabe (Whisper)"
        }

        RowLayout {
            Kirigami.FormData.label: "Mikrofon:"

            QQC2.ComboBox {
                id: micCombo
                Layout.preferredWidth: Kirigami.Units.gridUnit * 18
                textRole: "label"
                valueRole: "value"
                model: root.micSources
                function refresh() {
                    var idx = indexOfValue(ConfigStore.value("sttSource"))
                    currentIndex = idx >= 0 ? idx : 0
                }
                onActivated: ConfigStore.setValue("sttSource", currentValue)
            }

            QQC2.Button {
                icon.name: "view-refresh"
                display: QQC2.AbstractButton.IconOnly
                onClicked: root.scanMics()
                QQC2.ToolTip.text: "Mikrofonliste aktualisieren"
                QQC2.ToolTip.visible: hovered
            }
        }

        QQC2.ComboBox {
            id: sttLangCombo
            Kirigami.FormData.label: "Sprache:"
            Layout.preferredWidth: Kirigami.Units.gridUnit * 14
            textRole: "label"
            valueRole: "value"
            model: root.sttLanguages
            Component.onCompleted: currentIndex = Math.max(0, indexOfValue(ConfigStore.value("sttLanguage")))
            onActivated: ConfigStore.setValue("sttLanguage", currentValue)
        }

        QQC2.Label {
            text: "Standardmäßig wird das System-Standardmikrofon verwendet. Falls\nkeine Sprache erkannt wird, hier gezielt ein anderes Mikrofon wählen."
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            opacity: 0.6
        }

        QQC2.Label {
            visible: testStatus !== ""
            text: testStatus
            opacity: 0.8
        }

        QQC2.Label {
            text: "Stimmen liegen in ~/.local/share/aurora/piper/ — weitere Stimmen\nkönnen von huggingface.co/rhasspy/piper-voices installiert werden."
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            opacity: 0.6
        }
    }
}
