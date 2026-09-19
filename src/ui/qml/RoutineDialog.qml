import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import net.niuton.aurora.ui

// Bearbeiten/Anlegen einer Routine als Overlay (kein fensterbasiertes QQC2.
// Dialog: das Widget-Popup ist ein eigenes Window — ein separates Fenster
// könnte hinter dem Popup landen; ein Anker-Overlay funktioniert im Widget
// UND in der App identisch). Dumb-View: openFor(routine|null) füllt die
// Felder, saved(var fields)/runRequested(string id) gehen an den Host.
Rectangle {
    id: dialog

    signal saved(var fields)
    signal runRequested(string id)

    // editing = null => Anlegen, sonst die bearbeitete Zeile (controller.routineList-Shape)
    property var _editing: null
    readonly property var _kinds: ["daily", "weekly", "interval", "once"]
    readonly property var _kindLabels: ["Täglich", "Wöchentlich", "Intervall", "Einmalig"]
    readonly property var _weekdayLabels: ["Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag", "Sonntag"]
    readonly property var _intervalChoices: [
        { "label": "15 Minuten", "v": 15 }, { "label": "30 Minuten", "v": 30 },
        { "label": "1 Stunde", "v": 60 },   { "label": "3 Stunden", "v": 180 },
        { "label": "6 Stunden", "v": 360 }, { "label": "12 Stunden", "v": 720 },
        { "label": "1 Tag", "v": 1440 },    { "label": "1 Woche", "v": 10080 }
    ]
    property string _error: ""

    // Intern-Exposure für Tests (Konvention wie Header.qml) — Aliase, damit
    // die Tests lesen UND schreiben können.
    property alias _titleText: titleField.text
    property alias _promptText: promptArea.text
    property alias _kindIndex: kindCombo.currentIndex
    property alias _timeText: timeField.text
    property alias _weekdayIndex: weekdayCombo.currentIndex
    property alias _intervalIndex: intervalCombo.currentIndex
    readonly property alias _enabled: enabledSwitch.checked
    readonly property var _runBtn: runBtn

    function openFor(routine) {
        dialog._editing = routine || null
        dialog._error = ""
        titleField.text = routine ? (routine.title || "") : ""
        promptArea.text = routine ? (routine.prompt || "") : ""
        kindCombo.currentIndex = Math.max(0, dialog._kinds.indexOf(routine ? routine.kind : "daily"))
        var t = (routine && /^([01]?\d|2[0-3]):([0-5]\d)$/.test(routine.timeOfDay || ""))
            ? routine.timeOfDay : "12:00"
        timeField.text = t
        weekdayCombo.currentIndex = routine ? Math.min(6, Math.max(0, routine.weekday || 0)) : 0
        var iv = routine ? (routine.intervalMinutes || 60) : 60
        intervalCombo.currentIndex = 0
        for (var i = 0; i < dialog._intervalChoices.length; i++)
            if (dialog._intervalChoices[i].v === iv) intervalCombo.currentIndex = i
        enabledSwitch.checked = routine ? (routine.enabled !== false) : true
        visible = true
        titleField.forceActiveFocus()
    }

    function _close() {
        visible = false
        dialog._editing = null
    }

    function _save() {
        var prompt = promptArea.text.trim()
        if (prompt === "") {
            dialog._error = "Bitte beschreiben, was bei jedem Lauf getan werden soll."
            return
        }
        var kind = dialog._kinds[kindCombo.currentIndex]
        var f = {
            "title": titleField.text.trim(),
            "prompt": prompt,
            "kind": kind,
            "enabled": enabledSwitch.checked
        }
        if (dialog._editing) f.id = dialog._editing.id
        if (kind === "daily" || kind === "weekly" || kind === "once") {
            if (!/^([01]?\d|2[0-3]):([0-5]\d)$/.test(timeField.text.trim())) {
                dialog._error = "Uhrzeit im Format HH:MM angeben (z. B. 12:00)."
                return
            }
            f.timeOfDay = timeField.text.trim()
        }
        if (kind === "weekly") f.weekday = weekdayCombo.currentIndex
        if (kind === "interval")
            f.intervalMinutes = dialog._intervalChoices[Math.max(0, intervalCombo.currentIndex)].v
        dialog._error = ""
        dialog.saved(f)
        dialog._close()
    }

    anchors.fill: parent
    visible: false
    color: Qt.rgba(0, 0, 0, 0.45)
    z: 100

    // Klick auf den Dimmer schließt (ohne Speichern)
    TapHandler {
        onTapped: dialog._close()
    }

    Rectangle {
        id: panel
        anchors.centerIn: parent
        width: Math.min(parent.width - Kirigami.Units.gridUnit * 2, Kirigami.Units.gridUnit * 34)
        height: Math.min(parent.height - Kirigami.Units.gridUnit * 2, panelLayout.implicitHeight
                         + Kirigami.Units.largeSpacing * 2)
        radius: Kirigami.Units.smallSpacing * 2
        color: Kirigami.Theme.window
        border.width: 1
        border.color: Kirigami.Theme.backgroundColor

        // Klicks im Panel dürfen nicht zum Dimmer durchschlagen
        TapHandler { onTapped: { /* konsumieren */ } }

        ColumnLayout {
            id: panelLayout
            anchors.fill: parent
            anchors.margins: Kirigami.Units.largeSpacing
            spacing: Kirigami.Units.smallSpacing

            QQC2.Label {
                Layout.fillWidth: true
                text: dialog._editing ? "Routine bearbeiten" : "Neue Routine"
                font.bold: true
                font.pointSize: Kirigami.Theme.smallFont.pointSize + 2
            }

            Kirigami.FormLayout {
                Layout.fillWidth: true

                QQC2.TextField {
                    id: titleField
                    Layout.preferredWidth: Kirigami.Units.gridUnit * 14
                    Kirigami.FormData.label: "Titel:"
                    placeholderText: "z. B. Brent-Preis prüfen"
                }

                QQC2.ComboBox {
                    id: kindCombo
                    Kirigami.FormData.label: "Zeitplan:"
                    model: dialog._kindLabels
                    onActivated: dialog._error = ""
                }

                QQC2.TextField {
                    id: timeField
                    Layout.preferredWidth: Kirigami.Units.gridUnit * 4
                    Kirigami.FormData.label: "Uhrzeit:"
                    placeholderText: "12:00"
                    inputMethodHints: Qt.ImhTime
                    visible: dialog._kinds[kindCombo.currentIndex] !== "interval"
                }

                QQC2.ComboBox {
                    id: weekdayCombo
                    Kirigami.FormData.label: "Wochentag:"
                    model: dialog._weekdayLabels
                    visible: dialog._kinds[kindCombo.currentIndex] === "weekly"
                }

                QQC2.ComboBox {
                    id: intervalCombo
                    Kirigami.FormData.label: "Abstand:"
                    model: dialog._intervalChoices.map(function(c) { return c.label })
                    visible: dialog._kinds[kindCombo.currentIndex] === "interval"
                }

                QQC2.Switch {
                    id: enabledSwitch
                    Kirigami.FormData.label: "Aktiv:"
                    text: checked ? "läuft nach Zeitplan" : "pausiert"
                }
            }

            QQC2.Label {
                Layout.fillWidth: true
                text: "Aufgabe (Prompt) — Aurora führt dies bei jedem Lauf selbstständig aus:"
                wrapMode: Text.WordWrap
                opacity: 0.7
                font.pointSize: Kirigami.Theme.smallFont.pointSize
            }

            QQC2.ScrollView {
                Layout.fillWidth: true
                Layout.preferredHeight: Kirigami.Units.gridUnit * 4

                QQC2.TextArea {
                    id: promptArea
                    placeholderText: "z. B. Prüfe den aktuellen Preis von Brent crude oil und fasse ihn in einem Satz zusammen."
                    wrapMode: TextArea.Wrap
                    onTextChanged: dialog._error = ""
                }
            }

            QQC2.Label {
                Layout.fillWidth: true
                visible: dialog._error !== ""
                text: dialog._error
                color: Kirigami.Theme.negativeTextColor
                wrapMode: Text.WordWrap
                font.pointSize: Kirigami.Theme.smallFont.pointSize
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                QQC2.Button {
                    id: runBtn
                    visible: dialog._editing !== null
                    icon.name: "media-playback-start"
                    text: "Jetzt ausführen"
                    onClicked: {
                        dialog.runRequested(dialog._editing.id)
                        dialog._close()
                    }
                }

                Item { Layout.fillWidth: true }

                QQC2.Button {
                    text: "Abbrechen"
                    onClicked: dialog._close()
                }

                QQC2.Button {
                    text: "Speichern"
                    icon.name: "dialog-ok-apply"
                    highlighted: true
                    onClicked: dialog._save()
                }
            }
        }
    }
}
