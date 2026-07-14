import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import net.niuton.aurora.ui

Rectangle {
    id: inputRoot

    signal messageSent(string text)
    signal attachRequested()
    signal searchRequested(string text)
    signal abortRequested()

    property bool isGenerating: false
    property alias text: inputField.text

    property var commands: []        // controller.commandList (Autovervollständigung)
    property var modelEntries: []    // controller.modelPickerEntries (/model-Argumentliste)
    property bool _acDismissed: false  // Esc hat das Popup für den aktuellen Text geschlossen

    // Aktueller Zustand aus dem Eingabetext:
    readonly property bool _cmdMode: /^\/(\S*)$/.test(inputField.text)   // "/wort" ohne Leerzeichen
    readonly property var _modelCmd: {
        var m = inputField.text.match(/^\/(\S+)\s/)                       // "/befehl " (Argument beginnt)
        if (!m) return null
        var cmds = inputRoot.commands || []
        for (var i = 0; i < cmds.length; i++)
            if (cmds[i].name === m[1] && cmds[i].argSource === "models")
                return cmds[i]
        return null
    }
    readonly property bool _argMode: _modelCmd !== null
    readonly property var _suggestions: {
        if (_cmdMode) {
            var w = inputField.text.substring(1).toLowerCase()
            var out = []
            var cmds = inputRoot.commands || []
            for (var i = 0; i < cmds.length; i++) {
                var c = cmds[i]
                if (c.name.toLowerCase().indexOf(w) === 0)
                    out.push({ display: "/" + c.name + (c.argHint ? " " + c.argHint : ""),
                               sub: c.description, insert: "/" + c.name, takesArg: c.takesArg })
            }
            return out
        }
        if (_argMode) {
            var mm = inputField.text.match(/^\/\S+\s+(.*)$/)
            var partial = (mm ? mm[1] : "").toLowerCase()
            var out2 = []
            var entries = inputRoot.modelEntries || []
            for (var j = 0; j < entries.length; j++) {
                var e = entries[j]
                if (e.kind === "header" || e.enabled === false) continue
                var nm = String(e.value).replace(/^(local|remote):/, "")
                if (partial === "" || nm.toLowerCase().indexOf(partial) === 0
                    || String(e.label).toLowerCase().indexOf(partial) !== -1)
                    out2.push({ display: e.label, sub: "", insert: "/model " + e.value, takesArg: false })
            }
            return out2
        }
        return []
    }
    readonly property bool _popupOpen: !_acDismissed && (_cmdMode || _argMode) && _suggestions.length > 0

    onTextChanged: { _acDismissed = false; acPopup.highlightIndex = 0 }  // Vorschläge geändert -> Markierung auf gültigen Top-Treffer

    // Sprach-Eingabe
    property bool voiceAvailable: false
    property string voiceState: "idle"   // idle | recording | transcribing
    signal voiceToggled()

    // Bild-Modus
    property bool comfyAvailable: false
    signal imageModeRequested()

    implicitHeight: inputRow.implicitHeight + Kirigami.Units.smallSpacing * 2
    radius: Kirigami.Units.gridUnit * 0.6
    color: Theme.withAlpha(Kirigami.Theme.textColor, 0.05)
    border.width: 1
    border.color: inputField.activeFocus
        ? Theme.withAlpha(Theme.auroraCyan, 0.6)
        : Theme.withAlpha(Kirigami.Theme.textColor, 0.12)

    Behavior on border.color { ColorAnimation { duration: 150 } }

    // Fokus-unabhängiger Esc-Abbruch: inputField ist während isGenerating disabled
    // und bekommt daher gar keine Key-Events mehr — der Shortcut wirkt trotzdem,
    // weil er am immer aktiven Root hängt statt am (dann deaktivierten) Feld.
    Shortcut {
        sequences: ["Escape"]
        enabled: inputRoot.isGenerating
        onActivated: inputRoot.abortRequested()
    }

    function _send() {
        if (inputField.text.trim() === "") return
        inputRoot.messageSent(inputField.text.trim())
        inputField.text = ""
    }

    function _acceptSuggestion(i) {
        if (i < 0 || i >= inputRoot._suggestions.length) i = 0   // Index gegen geschrumpfte Liste absichern
        var s = inputRoot._suggestions[i]
        if (!s) return
        if (inputRoot._argMode) {              // Modell gewählt -> vervollständigen + senden
            inputField.text = s.insert
            _send()
        } else if (s.takesArg) {               // Argument-Befehl -> auf Argument warten
            inputField.text = s.insert + " "
            inputField.cursorPosition = inputField.text.length
        } else {                               // arg-loser Befehl -> direkt ausführen
            inputField.text = s.insert
            _send()
        }
    }

    QQC2.Popup {
        id: acPopup
        visible: inputRoot._popupOpen && inputField.activeFocus
        x: Kirigami.Units.smallSpacing
        y: -height - Kirigami.Units.smallSpacing
        width: inputRoot.width - Kirigami.Units.smallSpacing * 2
        padding: 2
        closePolicy: QQC2.Popup.NoAutoClose
        property int highlightIndex: 0
        onVisibleChanged: highlightIndex = 0
        contentItem: ListView {
            id: acList
            implicitHeight: Math.min(contentHeight, Kirigami.Units.gridUnit * 12)
            clip: true
            model: inputRoot._suggestions
            currentIndex: acPopup.highlightIndex
            delegate: QQC2.ItemDelegate {
                width: ListView.view.width
                highlighted: index === acPopup.highlightIndex
                onClicked: inputRoot._acceptSuggestion(index)
                contentItem: ColumnLayout {
                    spacing: 0
                    QQC2.Label { text: modelData.display; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true }
                    QQC2.Label {
                        visible: modelData.sub !== ""
                        text: modelData.sub
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                        opacity: 0.6; elide: Text.ElideRight; Layout.fillWidth: true
                    }
                }
            }
        }
    }

    RowLayout {
        id: inputRow
        anchors.fill: parent
        anchors.leftMargin: Kirigami.Units.smallSpacing
        anchors.rightMargin: Kirigami.Units.smallSpacing
        anchors.verticalCenter: parent.verticalCenter
        spacing: 2

        QQC2.ToolButton {
            icon.name: "mail-attachment"
            enabled: !inputRoot.isGenerating
            onClicked: inputRoot.attachRequested()
            QQC2.ToolTip { text: "Datei anhängen"; visible: parent.hovered; delay: Kirigami.Units.toolTipDelay }
        }

        // Mikrofon: Klick startet/stoppt die Aufnahme
        QQC2.ToolButton {
            id: micButton
            visible: inputRoot.voiceAvailable
            enabled: !inputRoot.isGenerating && inputRoot.voiceState !== "transcribing"
            icon.name: inputRoot.voiceState === "recording"
                ? "media-record" : "audio-input-microphone"
            icon.color: inputRoot.voiceState === "recording"
                ? Kirigami.Theme.negativeTextColor : undefined
            onClicked: inputRoot.voiceToggled()

            // Pulsieren während der Aufnahme
            SequentialAnimation on opacity {
                running: inputRoot.voiceState === "recording"
                loops: Animation.Infinite
                NumberAnimation { to: 0.35; duration: 550 }
                NumberAnimation { to: 1.0; duration: 550 }
                onRunningChanged: if (!running) micButton.opacity = 1.0
            }

            QQC2.BusyIndicator {
                anchors.fill: parent
                anchors.margins: 4
                visible: inputRoot.voiceState === "transcribing"
                running: visible
            }

            QQC2.ToolTip {
                text: inputRoot.voiceState === "recording" ? "Aufnahme stoppen"
                    : inputRoot.voiceState === "transcribing" ? "Transkribiere..."
                    : "Spracheingabe"
                visible: parent.hovered
                delay: Kirigami.Units.toolTipDelay
            }
        }

        QQC2.TextField {
            id: inputField
            Layout.fillWidth: true
            placeholderText: "Frag Aurora etwas..."
            enabled: !inputRoot.isGenerating
            background: null

            Keys.onUpPressed: function(event) {
                if (inputRoot._popupOpen) { acPopup.highlightIndex = Math.max(0, acPopup.highlightIndex - 1); event.accepted = true }
                else event.accepted = false
            }
            Keys.onDownPressed: function(event) {
                if (inputRoot._popupOpen) { acPopup.highlightIndex = Math.min(inputRoot._suggestions.length - 1, acPopup.highlightIndex + 1); event.accepted = true }
                else event.accepted = false
            }
            Keys.onReturnPressed: {
                if (inputRoot._popupOpen) inputRoot._acceptSuggestion(acPopup.highlightIndex)
                else inputRoot._send()
            }
            Keys.onEnterPressed: {
                if (inputRoot._popupOpen) inputRoot._acceptSuggestion(acPopup.highlightIndex)
                else inputRoot._send()
            }
            Keys.onEscapePressed: {
                // Der Abbruch-Zweig läuft jetzt über den Shortcut oben (fokus-unabhängig,
                // greift auch wenn das Feld während der Generierung disabled ist).
                if (inputRoot._popupOpen) inputRoot._acDismissed = true
            }
            Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Tab && inputRoot._popupOpen) {
                    inputRoot._acceptSuggestion(acPopup.highlightIndex); event.accepted = true
                }
            }
        }

        // Bild-Modus öffnen
        QQC2.ToolButton {
            icon.name: "insert-image"
            visible: inputRoot.comfyAvailable
            enabled: !inputRoot.isGenerating
            onClicked: inputRoot.imageModeRequested()
            QQC2.ToolTip { text: "Bild generieren (ComfyUI)"; visible: parent.hovered; delay: Kirigami.Units.toolTipDelay }
        }

        QQC2.ToolButton {
            icon.name: "search"
            enabled: !inputRoot.isGenerating && inputField.text.trim() !== ""
            onClicked: {
                if (inputField.text.trim() !== "") {
                    inputRoot.searchRequested(inputField.text.trim())
                    inputField.text = ""
                }
            }
            QQC2.ToolTip { text: "Web-Suche"; visible: parent.hovered; delay: Kirigami.Units.toolTipDelay }
        }

        QQC2.ToolButton {
            icon.name: inputRoot.isGenerating ? "media-playback-stop" : "document-send"
            enabled: inputRoot.isGenerating || inputField.text.trim() !== ""
            onClicked: {
                if (inputRoot.isGenerating) {
                    inputRoot.abortRequested()
                } else {
                    inputRoot._send()
                }
            }
            QQC2.ToolTip {
                text: inputRoot.isGenerating ? "Stoppen (Esc)" : "Senden"
                visible: parent.hovered
                delay: Kirigami.Units.toolTipDelay
            }
        }
    }
}
