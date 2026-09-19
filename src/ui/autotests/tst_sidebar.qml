import QtQuick
import QtTest
import net.niuton.aurora.ui

// Sidebar-Sektionen: Routinen oberhalb der Chats, beide einklappbar; die
// Routinenzeile meldet Editieren/Löschen (Zwei-Klick)/Sofortlauf, die
// Chatliste bleibt in ihrem bekannten Verhalten (Suche, Laden, Löschen).
TestCase {
    name: "SidebarSections"
    when: windowShown

    width: 300
    height: 500

    property var testRoutines: [
        { "id": "r1", "title": "Brent-Preis", "prompt": "Prüfe den Preis", "kind": "daily",
          "timeOfDay": "12:00", "weekday": 0, "intervalMinutes": 60, "enabled": true,
          "nextRun": Date.now() + 3600000, "lastRun": 0, "lastStatus": "ok",
          "lastConversation": "c9", "scheduleText": "täglich 12:00" },
        { "id": "r2", "title": "Backup", "prompt": "Räume auf", "kind": "interval",
          "timeOfDay": "", "weekday": 0, "intervalMinutes": 120, "enabled": false,
          "nextRun": 0, "lastRun": Date.now() - 7200000, "lastStatus": "error",
          "lastConversation": "", "scheduleText": "alle 2 h" }
    ]
    property var testConvs: [
        { "id": "c1", "title": "Erster Chat", "created_at": "2026-09-19T10:00:00",
          "updated_at": "2026-09-19T10:00:00" }
    ]

    Sidebar {
        id: sidebar
        anchors.fill: parent
        routines: testRoutines
        runningRoutineId: ""
        routinesOpen: true
        conversations: testConvs
        currentId: ""
        canNewChat: true
        chatsOpen: true
        searchResults: []
    }

    SignalSpy { id: routinesToggleSpy; target: sidebar; signalName: "routinesToggleRequested" }
    SignalSpy { id: chatsToggleSpy; target: sidebar; signalName: "chatsToggleRequested" }
    SignalSpy { id: addSpy; target: sidebar; signalName: "routineAddRequested" }
    SignalSpy { id: editSpy; target: sidebar; signalName: "routineEditRequested" }
    SignalSpy { id: deleteSpy; target: sidebar; signalName: "routineDeleteRequested" }
    SignalSpy { id: runSpy; target: sidebar; signalName: "routineRunRequested" }
    SignalSpy { id: loadSpy; target: sidebar; signalName: "loadRequested" }

    function init() {
        visible = true               // qmltestrunner hält die Wurzel unsichtbar —
                                     // ohne das liest sich .visible als false ein
        sidebar.routines = testRoutines
        sidebar.routinesOpen = true
        sidebar.chatsOpen = true
        sidebar.searchResults = []
        sidebar._searchField.text = ""
        sidebar._routineConfirmId = ""
        sidebar._confirmId = ""
        routinesToggleSpy.clear(); chatsToggleSpy.clear(); addSpy.clear()
        editSpy.clear(); deleteSpy.clear(); runSpy.clear(); loadSpy.clear()
    }

    function test_routinenListeZeigtZeilen() {
        // ListView des Routinen-Bereichs: eine Zeile je Routine
        compare(sidebar._routineListView.count, 2)
    }

    function test_routinenSektionEinklappen() {
        var chevron = sidebar._routinesToggleBtn
        chevron.clicked()
        compare(routinesToggleSpy.count, 1)
        compare(routinesToggleSpy.signalArguments[0][0], false)
        // Die Liste folgt der Property (Host schreibt sie zurück)
        sidebar.routinesOpen = false
        verify(!sidebar._routineListView.visible)
    }

    function test_chatsSektionEinklappen() {
        sidebar._chatsToggleBtn.clicked()
        compare(chatsToggleSpy.count, 1)
        compare(chatsToggleSpy.signalArguments[0][0], false)
        sidebar.chatsOpen = false
        verify(!sidebar._convListView.visible)
        // Suche erzwingt die Chatliste trotz eingeklappter Sektion (ab 2 Zeichen
        // im Suchfeld gilt die Trefferliste als Modell)
        sidebar.searchResults = [{ "id": "c1", "title": "Erster Chat",
                                   "created_at": "", "updated_at": "", "snippet": "x" }]
        sidebar._searchField.text = "erst"
        wait(10)
        verify(sidebar._convListView.visible)
    }

    function test_routineZeileEditierenUndLauf() {
        var list = sidebar._routineListView
        var row = list.itemAtIndex(0)
        verify(row !== null)
        // Zeilen-Klick (MouseArea z: -1) -> Editieren mit der ganzen Routine
        row.click()
        compare(editSpy.count, 1)
        compare(editSpy.signalArguments[0][0].id, "r1")
        // Play-Knopf -> Sofortlauf
        row._runBtn.clicked()
        compare(runSpy.count, 1)
        compare(runSpy.signalArguments[0][0], "r1")
    }

    function test_routineLoeschenMitBestaetigung() {
        var row = sidebar._routineListView.itemAtIndex(0)
        row._deleteBtn.clicked()
        compare(deleteSpy.count, 0)              // erst bewaffnet
        compare(sidebar._routineConfirmId, "r1")
        row._deleteBtn.clicked()
        compare(deleteSpy.count, 1)              // bestätigt
        compare(deleteSpy.signalArguments[0][0], "r1")
    }

    function test_laenderBadgeLaufenderRoutine() {
        sidebar.runningRoutineId = "r1"
        var row = sidebar._routineListView.itemAtIndex(0)
        verify(row._statusLabel.text.indexOf("läuft") !== -1)
    }

    function test_leererRoutinenHinweis() {
        sidebar.routines = []
        wait(10)
        verify(sidebar._routineEmptyHint.visible)
        compare(sidebar._routineListView.count, 0)
    }

    function test_addKnopf() {
        sidebar._routineAddBtn.clicked()
        compare(addSpy.count, 1)
    }
}
