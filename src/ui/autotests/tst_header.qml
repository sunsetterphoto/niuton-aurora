import QtQuick
import QtTest
import net.niuton.aurora.ui

// Picker-Verhalten des Headers: Das Pickermodell ist eine flache Liste, aber
// die Cloud-Gruppe kann riesig sein (OpenRouter 425 Eintraege). Der Picker ist
// deshalb ein Popup mit Suchfeld (cloudSearchChanged), keine ComboBox.
TestCase {
    name: "HeaderPicker"
    when: windowShown

    property var testEntries: [
        { "label": "Auto (Energieprofil)", "value": "auto", "kind": "auto", "enabled": true },
        { "label": "Lokal", "value": "", "kind": "header", "enabled": false },
        { "label": "gemma4:e4b (5 GB)", "value": "local:gemma4:e4b", "kind": "local", "enabled": true },
        { "label": "OpenRouter ☁", "value": "", "kind": "header", "enabled": false },
        { "label": "openrouter/free · 200K", "value": "openrouter:openrouter/free", "kind": "cloud", "enabled": true },
        { "label": "openai/gpt-4o", "value": "openrouter:openai/gpt-4o", "kind": "cloud", "enabled": true }
    ]

    Header {
        id: header
        pickerEntries: testEntries
    }

    SignalSpy { id: searchSpy; target: header; signalName: "cloudSearchChanged" }
    SignalSpy { id: selectSpy; target: header; signalName: "modelSelected" }
    SignalSpy { id: effortSpy; target: header; signalName: "effortSelected" }
    SignalSpy { id: thinkSpy; target: header; signalName: "thinkingToggled" }

    function init() {
        // Erst Zustand zurücksetzen (Signale feuern dabei), DANN die Spys
        // leeren — so zählen sie nur noch Signale der Testfunktion.
        header._pickerPopup.close()
        header._searchField.text = ""
        searchSpy.clear()
        selectSpy.clear()
        effortSpy.clear()
        thinkSpy.clear()
    }

    // Effort-Dropdown: Auswahl emittiert effortSelected (Host -> Controller)
    function test_effortAuswahlEmittiertSignal() {
        header._effortComboBox.currentIndex = 3   // index 3 = "high" im Modell
        compare(effortSpy.count, 1)
        compare(effortSpy.signalArguments[0][0], "high")
    }

    // Effort-Dropdown: nur verfügbar, wenn das aktive Modell Effort kann.
    // (Sichtbarkeit via visible ist in der Test-Szene layout-abhängig; enabled
    // ist deterministisch und spiegelt die Nutzbarkeit — das eigentliche
    // Ein-/Ausblenden läuft über visible im Header.)
    function test_effortNurBeiFaehigkeit() {
        header.effortAvailable = false
        wait(30)
        compare(header._effortCombo.enabled, false)
        compare(header._effortCombo.visible, false)
        header.effortAvailable = true
        wait(30)
        compare(header._effortCombo.enabled, true)
    }

    // Thinking-Toggle: Bestand wird nicht neu getestet (bestehende Suiten
    // decken ihn über MainView/Controller); hier nur die Effort-Emissionen.
    function test_thinkingToggleBestehtUnveraendert() {
        // Der Toggle existiert weiterhin (Regression Guard)
        verify(header._thinkToggle !== null)
        verify(header._thinkToggle.checkable)
    }

    // Der Button ist der Einstieg; das Popup zeigt die Einträge als Liste.
    function test_popupZeigtEintraege() {
        header._pickerButton.clicked()
        verify(header._pickerPopup.opened)
        compare(header._pickerList.count, 6)
    }

    // Tippen im Suchfeld emittiert cloudSearchChanged (der Host reicht es an
    // den Controller/ModelManager weiter — Header bleibt "dumb").
    function test_sucheEmittiertSignal() {
        header._searchField.text = "gpt"
        compare(searchSpy.count, 1)
        compare(searchSpy.signalArguments[0][0], "gpt")
    }

    // Beim Schließen wird die Suche zurückgesetzt — danach zeigt der Picker
    // wieder die Favoriten, keine Suchreste. Der Popup muss dafür GEÖFFNET
    // gewesen sein (onClosed feuert sonst nie); close() selbst ist asynchron.
    function test_sucheResetBeimSchliessen() {
        header._pickerPopup.open()
        wait(100)
        header._searchField.text = "gpt"
        header._pickerPopup.close()
        wait(100)
        compare(searchSpy.count, 2)
        compare(searchSpy.signalArguments[1][0], "")
        verify(header._searchField.text === "")
    }

    // Auswahl eines Eintrags emittiert modelSelected (wie der alte ComboBox-
    // onActivated) — der Host wählt das Modell.
    function test_auswahlEmittiertModelSelected() {
        header._pickerPopup.open()
        wait(100)   // Delegates erst nach dem Öffnen instanziiert
        var idx = -1
        for (var i = 0; i < header._pickerList.count; i++) {
            if (header._pickerList.model[i].value === "openrouter:openrouter/free")
                idx = i
        }
        verify(idx !== -1)
        var delegate = header._pickerList.itemAtIndex(idx)
        verify(delegate !== null)
        delegate.clicked()
        compare(selectSpy.count, 1)
        compare(selectSpy.signalArguments[0][0], "openrouter:openrouter/free")
    }
}