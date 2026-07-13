import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import net.niuton.aurora.ui

// Pro-Modell-Inference-Parameter-Editor (Ollama-options). Dumb-View: params rein,
// saveRequested/closeRequested raus. Aktiv-Schalter pro Parameter: an = gesetzt
// (gespeichert/gesendet), aus = ungesetzt (Ollama-Default, zugleich der Reset).
// Slider für begrenzte Spannen, Freitext für num_ctx/num_predict/seed/stop.
Rectangle {
    id: tuner

    property string modelName: ""
    property var params: ({})     // vorbefüllte Werte, z. B. { num_ctx: 8192, stop: ["</s>"] }

    signal saveRequested(var params)
    signal closeRequested()

    // Test-/Interaktions-Schnittstelle: Aktiv-Schalter + Wert je Parameter.
    property alias temperatureActive: temperatureRow.active
    property alias temperatureValue: temperatureRow.value
    property alias topPActive: topPRow.active
    property alias topPValue: topPRow.value
    property alias topKActive: topKRow.active
    property alias topKValue: topKRow.value
    property alias repeatPenaltyActive: repeatPenaltyRow.active
    property alias repeatPenaltyValue: repeatPenaltyRow.value
    property alias minPActive: minPRow.active
    property alias minPValue: minPRow.value
    property alias numCtxActive: numCtxRow.active
    property alias numCtxText: numCtxRow.text
    property alias numPredictActive: numPredictRow.active
    property alias numPredictText: numPredictRow.text
    property alias seedActive: seedRow.active
    property alias seedText: seedRow.text
    property alias stopActive: stopRow.active
    property alias stopText: stopRow.text

    implicitHeight: tunerColumn.implicitHeight + Kirigami.Units.smallSpacing * 2
    radius: Kirigami.Units.gridUnit * 0.6
    color: Theme.withAlpha(Kirigami.Theme.textColor, 0.05)
    border.width: 1
    border.color: Theme.withAlpha(Theme.auroraCyan, 0.45)

    // ---- Laden: params -> Aktiv-Schalter + Werte ----
    function _load() {
        var p = tuner.params || ({})
        _loadSlider(temperatureRow, p, "temperature")
        _loadSlider(topPRow, p, "top_p")
        _loadSlider(topKRow, p, "top_k")
        _loadSlider(repeatPenaltyRow, p, "repeat_penalty")
        _loadSlider(minPRow, p, "min_p")
        _loadField(numCtxRow, p, "num_ctx")
        _loadField(numPredictRow, p, "num_predict")
        _loadField(seedRow, p, "seed")
        _loadStop(stopRow, p)
        // Erweitert automatisch aufklappen, wenn ein erweiterter Parameter aktiv ist
        // (nie zwangsweise zuklappen).
        advancedToggle.checked = advancedToggle.checked
            || numPredictRow.active || seedRow.active || minPRow.active || stopRow.active
    }
    function _loadSlider(row, p, key) {
        if (p[key] !== undefined) { row.active = true; row.value = p[key] }
        else { row.active = false; row.value = row.refValue }
    }
    function _loadField(row, p, key) {
        if (p[key] !== undefined) { row.active = true; row.text = String(p[key]) }
        else { row.active = false; row.text = "" }
    }
    function _loadStop(row, p) {
        if (p.stop !== undefined && p.stop.length > 0) { row.active = true; row.text = p.stop.join(", ") }
        else { row.active = false; row.text = "" }
    }
    onParamsChanged: _load()
    onVisibleChanged: if (visible) _load()
    Component.onCompleted: _load()

    // ---- Speichern: nur aktive Parameter, korrekte Typen ----
    function _save() {
        var o = {}
        if (temperatureRow.active)   o.temperature    = temperatureRow.value
        if (topPRow.active)          o.top_p          = topPRow.value
        if (topKRow.active)          o.top_k          = Math.round(topKRow.value)
        if (repeatPenaltyRow.active) o.repeat_penalty = repeatPenaltyRow.value
        if (minPRow.active)          o.min_p          = minPRow.value
        _saveInt(numCtxRow, o, "num_ctx")
        _saveInt(numPredictRow, o, "num_predict")
        _saveInt(seedRow, o, "seed")
        if (stopRow.active) {
            var arr = stopRow.text.split(",").map(function(x) { return x.trim() })
                                  .filter(function(x) { return x !== "" })
            if (arr.length) o.stop = arr
        }
        tuner.saveRequested(o)
    }
    function _saveInt(row, o, key) {
        if (!row.active) return
        var t = row.text.trim(); if (t === "") return
        var v = parseInt(t); if (!isNaN(v)) o[key] = v
    }

    // ---- Zeilen-Komponenten ----
    // Slider-Zeile: [aktiv] Label ⓘ  Slider  Wert
    component SliderRow: RowLayout {
        id: row
        property string label: ""
        property string tooltip: ""
        property real minValue: 0
        property real maxValue: 1
        property real step: 0.01
        property real refValue: 0
        property int decimals: 2
        property alias active: activeBox.checked
        property alias value: slider.value
        Layout.fillWidth: true
        spacing: Kirigami.Units.smallSpacing
        QQC2.CheckBox {
            id: activeBox
            // Beim manuellen Deaktivieren zurück auf den Referenzwert, damit ein
            // erneutes Aktivieren wieder beim Standard startet.
            onToggled: if (!checked) slider.value = row.refValue
        }
        QQC2.Label {
            text: row.label
            Layout.preferredWidth: Kirigami.Units.gridUnit * 7
            elide: Text.ElideRight
        }
        Kirigami.Icon {
            source: "documentinfo"
            Layout.preferredWidth: Kirigami.Units.iconSizes.small
            Layout.preferredHeight: Kirigami.Units.iconSizes.small
            opacity: 0.7
            HoverHandler { id: hh }
            QQC2.ToolTip.text: row.tooltip
            QQC2.ToolTip.visible: hh.hovered
            QQC2.ToolTip.delay: 300
        }
        QQC2.Slider {
            id: slider
            Layout.fillWidth: true
            enabled: activeBox.checked
            from: row.minValue
            to: row.maxValue
            stepSize: row.step
            value: row.refValue
        }
        QQC2.Label {
            Layout.preferredWidth: Kirigami.Units.gridUnit * 3
            horizontalAlignment: Text.AlignRight
            opacity: activeBox.checked ? 1.0 : 0.5
            text: activeBox.checked ? slider.value.toFixed(row.decimals) : "Standard"
        }
    }

    // Freitext-Zeile: [aktiv] Label ⓘ  TextField
    component FieldRow: RowLayout {
        id: row
        property string label: ""
        property string tooltip: ""
        property int inputHints: Qt.ImhNone
        property alias active: activeBox.checked
        property alias text: field.text
        Layout.fillWidth: true
        spacing: Kirigami.Units.smallSpacing
        QQC2.CheckBox {
            id: activeBox
            // Beim manuellen Deaktivieren das Feld leeren, damit "Standard"
            // (placeholder) erscheint und ein erneutes Aktivieren leer startet
            // — analog zu SliderRow.
            onToggled: if (!checked) field.text = ""
        }
        QQC2.Label {
            text: row.label
            Layout.preferredWidth: Kirigami.Units.gridUnit * 7
            elide: Text.ElideRight
        }
        Kirigami.Icon {
            source: "documentinfo"
            Layout.preferredWidth: Kirigami.Units.iconSizes.small
            Layout.preferredHeight: Kirigami.Units.iconSizes.small
            opacity: 0.7
            HoverHandler { id: hh }
            QQC2.ToolTip.text: row.tooltip
            QQC2.ToolTip.visible: hh.hovered
            QQC2.ToolTip.delay: 300
        }
        QQC2.TextField {
            id: field
            Layout.fillWidth: true
            enabled: activeBox.checked
            inputMethodHints: row.inputHints
            placeholderText: "Standard"
        }
    }

    ColumnLayout {
        id: tunerColumn
        anchors.fill: parent
        anchors.margins: Kirigami.Units.smallSpacing
        spacing: Kirigami.Units.smallSpacing

        RowLayout {
            Layout.fillWidth: true
            QQC2.Label {
                text: "Parameter · " + (tuner.modelName !== "" ? tuner.modelName : "(kein Modell)")
                font.bold: true
                elide: Text.ElideRight
                Layout.fillWidth: true
            }
            QQC2.ToolButton {
                icon.name: "dialog-close"
                onClicked: tuner.closeRequested()
                QQC2.ToolTip.text: "Schließen"
                QQC2.ToolTip.visible: hovered
            }
        }

        FieldRow {
            id: numCtxRow
            label: "num_ctx"
            inputHints: Qt.ImhDigitsOnly
            tooltip: "Kontextfenster — wie viele Tokens (Verlauf + Eingabe) das Modell gleichzeitig sieht. Größer = mehr Erinnerung, aber mehr Speicher und langsamer. Leer = Ollama-Standard (oft klein, 2048–4096)."
        }
        SliderRow {
            id: temperatureRow
            label: "temperature"
            minValue: 0.0; maxValue: 2.0; step: 0.05; refValue: 0.8; decimals: 2
            tooltip: "Kreativität bzw. Zufall. Niedrig (0.2) = fokussiert und vorhersehbar, hoch (1.0+) = kreativer und variabler."
        }
        SliderRow {
            id: topPRow
            label: "top_p"
            minValue: 0.0; maxValue: 1.0; step: 0.01; refValue: 0.9; decimals: 2
            tooltip: "Nucleus-Sampling — berücksichtigt nur die wahrscheinlichsten Tokens, bis ihre Summe p erreicht. Niedriger = konservativer."
        }
        SliderRow {
            id: topKRow
            label: "top_k"
            minValue: 0; maxValue: 200; step: 1; refValue: 40; decimals: 0
            tooltip: "Beschränkt die Auswahl auf die k wahrscheinlichsten Tokens. Niedriger = fokussierter, höher = vielfältiger."
        }
        SliderRow {
            id: repeatPenaltyRow
            label: "repeat_penalty"
            minValue: 0.5; maxValue: 2.0; step: 0.01; refValue: 1.1; decimals: 2
            tooltip: "Bestraft Wortwiederholungen. Über 1 verringert sie; zu hoch klingt unnatürlich."
        }

        QQC2.CheckBox { id: advancedToggle; text: "Erweitert" }
        ColumnLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing
            visible: advancedToggle.checked
            FieldRow {
                id: numPredictRow
                label: "num_predict"
                inputHints: Qt.ImhDigitsOnly
                tooltip: "Maximale Anzahl erzeugter Tokens pro Antwort. Leer = kein Limit (Modell-Standard)."
            }
            FieldRow {
                id: seedRow
                label: "seed"
                inputHints: Qt.ImhDigitsOnly
                tooltip: "Fester Startwert für reproduzierbare Antworten (gleiche Eingabe → gleiche Ausgabe). Leer = zufällig."
            }
            SliderRow {
                id: minPRow
                label: "min_p"
                minValue: 0.0; maxValue: 1.0; step: 0.01; refValue: 0.05; decimals: 2
                tooltip: "Mindest-Wahrscheinlichkeit eines Tokens relativ zum besten. Alternative zu top_p; höher = konservativer."
            }
            FieldRow {
                id: stopRow
                label: "stop (Komma)"
                tooltip: "Stopp-Sequenzen (Komma-getrennt): die Generierung endet, sobald eine davon erscheint."
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Item { Layout.fillWidth: true }
            QQC2.Button {
                text: "Abbrechen"
                onClicked: tuner.closeRequested()
            }
            QQC2.Button {
                text: "Speichern"
                highlighted: true
                onClicked: tuner._save()
            }
        }
    }
}
