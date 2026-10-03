import QtQuick
import QtTest
import net.niuton.aurora.ui

// RoutineDialog: Overlay-Formular für Anlegen/Bearbeiten. Füllverhalten,
// Feld-Normalisierung beim Speichern, Prompt-Pflicht, Abbrechen.
TestCase {
    name: "RoutineDialog"
    when: windowShown

    width: 500
    height: 600

    RoutineDialog {
        id: dlg
        anchors.fill: parent
    }

    SignalSpy { id: savedSpy; target: dlg; signalName: "saved" }
    SignalSpy { id: runSpy; target: dlg; signalName: "runRequested" }

    function init() {
        visible = true               // qmltestrunner hält die Wurzel unsichtbar —
                                     // ohne das liest sich .visible als false ein
        dlg.visible = false
        dlg._editing = null
        savedSpy.clear()
        runSpy.clear()
    }

    function test_openForAnlegen_fülltDefaults() {
        dlg.openFor(null)
        verify(dlg.visible)
        compare(dlg._editing, null)
        compare(dlg._titleText, "")
        compare(dlg._promptText, "")
        compare(dlg._kindIndex, 0)          // daily
        compare(dlg._timeText, "12:00")
        compare(dlg._enabled, true)
    }

    function test_openForBearbeiten_fülltFelder() {
        dlg.openFor({ "id": "r7", "title": "Brent", "prompt": "Prüfe", "kind": "weekly",
                      "timeOfDay": "08:15", "weekday": 2, "intervalMinutes": 60,
                      "enabled": false })
        compare(dlg._editing.id, "r7")
        compare(dlg._titleText, "Brent")
        compare(dlg._promptText, "Prüfe")
        compare(dlg._kindIndex, 1)          // weekly
        compare(dlg._timeText, "08:15")
        compare(dlg._weekdayIndex, 2)
        compare(dlg._enabled, false)
    }

    function test_speichernAnlegen_bautFelder() {
        dlg.openFor(null)
        dlg._titleText = "Ölpreis"
        dlg._promptText = "Prüfe den Brent-Preis"
        dlg._kindIndex = 0
        dlg._timeText = "12:30"
        dlg._save()
        compare(savedSpy.count, 1)
        var f = savedSpy.signalArguments[0][0]
        compare(f.title, "Ölpreis")
        compare(f.prompt, "Prüfe den Brent-Preis")
        compare(f.kind, "daily")
        compare(f.timeOfDay, "12:30")
        verify(!("id" in f))                // Anlegen: keine id
        verify(!dlg.visible)
    }

    function test_speichernIntervall_undWochentag() {
        dlg.openFor(null)
        dlg._promptText = "Räume auf"
        dlg._kindIndex = 2                  // interval
        dlg._intervalIndex = 3              // 3 Stunden
        dlg._save()
        compare(savedSpy.count, 1)
        var f = savedSpy.signalArguments[0][0]
        compare(f.kind, "interval")
        compare(f.intervalMinutes, 180)
        verify(!("timeOfDay" in f))

        dlg.openFor(null)
        dlg._promptText = "Wöchentlich was"
        dlg._kindIndex = 1                  // weekly
        dlg._timeText = "09:00"
        dlg._weekdayIndex = 4
        dlg._save()
        f = savedSpy.signalArguments[1][0]
        compare(f.kind, "weekly")
        compare(f.weekday, 4)
        compare(f.timeOfDay, "09:00")
    }

    function test_ohnePromptKeinSpeichern() {
        dlg.openFor(null)
        dlg._titleText = "nur Titel"
        dlg._save()
        compare(savedSpy.count, 0)
        verify(dlg.visible)
        verify(dlg._error !== "")
    }

    function test_ungültigeZeitBlockiert() {
        dlg.openFor(null)
        dlg._promptText = "etwas"
        dlg._timeText = "25:99"
        dlg._save()
        compare(savedSpy.count, 0)
        verify(dlg._error !== "")
    }

    function test_speichernBearbeiten_trägtId() {
        dlg.openFor({ "id": "r3", "title": "t", "prompt": "p", "kind": "daily",
                      "timeOfDay": "07:00", "weekday": 0, "intervalMinutes": 60,
                      "enabled": true })
        dlg._timeText = "07:45"
        dlg._save()
        compare(savedSpy.count, 1)
        var f = savedSpy.signalArguments[0][0]
        compare(f.id, "r3")
        compare(f.timeOfDay, "07:45")
    }

    function test_abbrechenOhneSignal() {
        dlg.openFor(null)
        dlg._close()
        compare(savedSpy.count, 0)
        verify(!dlg.visible)
    }

    function test_jetztAusführen() {
        dlg.openFor({ "id": "r4", "title": "t", "prompt": "p", "kind": "daily",
                      "timeOfDay": "07:00", "weekday": 0, "intervalMinutes": 60,
                      "enabled": true })
        dlg._runBtn.clicked()
        compare(runSpy.count, 1)
        compare(runSpy.signalArguments[0][0], "r4")
        verify(!dlg.visible)
    }
}
