import QtQuick
import QtTest
import net.niuton.aurora.engine

// RoutineScheduler: Zeitplan-Mathematik, CRUD-Normalisierung, Claim->Lauf->
// Buchhaltung in der eigenen Engine. Der Store ist ein Mock, der die echte
// Async-Grenze (routinesClaimed nach claimRoutines) synchron nachbildet.
Item {
    Component { id: jobComp; QtObject {
        signal token(string t); signal thinking(string t); signal toolCalls(var calls)
        signal done(var result); signal error(string message)
        function abort(){}
    } }

    QtObject { id: storeMock
        property bool ready: true
        property int _n: 0
        property var rows: []                  // canned routines() Antwort
        property var added: []                 // addRoutine Aufrufe
        property var updates: []               // [id, fields]
        property var deleted: []
        property var touched: []               // [convId, title]
        property var due: []                   // Antwort der nächsten claimRoutines
        signal routinesClaimed(var rows)
        signal writeCompleted(string op)
        function newUuid() { _n++; return "u" + _n }
        function routines() { return rows }
        function addRoutine(f) { added.push(f); writeCompleted("addRoutine") }
        function updateRoutine(id, f) { updates.push([id, f]); writeCompleted("updateRoutine") }
        function deleteRoutine(id) {
            deleted.push(id)
            for (var i = 0; i < rows.length; i++)
                if (rows[i].id === id) { rows.splice(i, 1); break }
            writeCompleted("deleteRoutine")
        }
        function claimRoutines(nowMs) {
            var d = due; due = []
            // Modell der echten Welt: der Claim setzt die Zeilen auf 'running'
            // (atomar im Store) — refresh() nach writeCompleted sieht sie.
            for (var i = 0; i < d.length; i++) {
                var r = d[i]
                rows.push({ "id": r.id, "title": r.title, "prompt": r.prompt, "kind": r.kind,
                            "timeOfDay": r.timeOfDay, "weekday": r.weekday,
                            "intervalMinutes": r.intervalMinutes, "enabled": true,
                            "nextRun": nowMs, "lastRun": nowMs, "lastStatus": "running",
                            "lastConversation": "" })
            }
            routinesClaimed(d)
            writeCompleted("claimRoutines")
        }
        function touchConversation(id, t) { touched.push([id, t]) }
        // ChatController-Interface
        function appendMessage(m) {} function updateMessage(i,f){}
        function deleteMessage(i){} function messages(c){ return [] }
        function appendToolCall(t){} function updateToolCall(i,f){}
    }
    QtObject { id: settingsMock
        property bool ragEnabled: false
        property int toolMaxRounds: 5
        function paramsFor(name) { return ({}) } }
    QtObject { id: registryMock
        function definitions(c){ return [] } function promptSection(c){ return "" }
        function permissionFor(n){ return "auto" } function categoryOf(n){ return "local" }
        function describe(n,a){ return n } function execute(n,a,c,done){ done("",{status:"ok"}) }
        function abortRunning(){} }
    QtObject { id: mmMock
        property string activeModel: "m"; property var activeCaps: ["tools"]
        property bool isRemote: false }

    property var lastJob: null
    RoutineScheduler {
        id: sched
        store: storeMock
        modelManager: mmMock
        registry: registryMock
        settings: settingsMock
        homeDir: "/h"
        chatFn: function(req){ var j = jobComp.createObject(sched); lastJob = j; return j }
    }

    TestCase {
        name: "RoutineScheduler"

        function init() {
            storeMock.rows = []; storeMock.added = []; storeMock.updates = []
            storeMock.deleted = []; storeMock.touched = []; storeMock.due = []
            storeMock._n = 0
            lastJob = null
        }

        // ---- Zeitplan-Mathematik ----
        function test_computeNextRun_daily() {
            // 11:00 -> heute 12:00; 13:00 -> morgen 12:00
            var from = new Date(2026, 8, 19, 11, 0).getTime()
            var want = new Date(2026, 8, 19, 12, 0).getTime()
            compare(sched.computeNextRun("daily", "12:00", 0, 60, from), want)
            from = new Date(2026, 8, 19, 13, 0).getTime()
            want = new Date(2026, 8, 20, 12, 0).getTime()
            compare(sched.computeNextRun("daily", "12:00", 0, 60, from), want)
        }
        function test_computeNextRun_weekly() {
            // 19.09.2026 ist ein Samstag (JS getDay 6). Montag (0): +2 Tage 9:00
            var from = new Date(2026, 8, 19, 10, 0).getTime()
            var want = new Date(2026, 8, 21, 9, 0).getTime()
            compare(sched.computeNextRun("weekly", "09:00", 0, 60, from), want)
            // gleicher Tag (Samstag = 5), Zeit vorbei -> +7 Tage
            from = new Date(2026, 8, 19, 18, 0).getTime()
            want = new Date(2026, 8, 26, 9, 0).getTime()
            compare(sched.computeNextRun("weekly", "09:00", 5, 60, from), want)
        }
        function test_computeNextRun_intervalUndOnce() {
            var from = new Date(2026, 8, 19, 10, 0).getTime()
            compare(sched.computeNextRun("interval", "", 0, 30, from), from + 30 * 60000)
            // once in der Zukunft heute
            var want = new Date(2026, 8, 19, 22, 30).getTime()
            compare(sched.computeNextRun("once", "22:30", 0, 60, from), want)
            // once vorbei -> morgen
            want = new Date(2026, 8, 20, 8, 0).getTime()
            compare(sched.computeNextRun("once", "08:00", 0, 60, from), want)
        }

        // ---- CRUD ----
        function test_createRoutine_normalisiert_undPlant() {
            var res = sched.createRoutine({ "prompt": "  Prüfe Brent  ", "kind": "daily",
                                            "timeOfDay": "9:05" })
            compare(res.ok, true)
            compare(storeMock.added.length, 1)
            var f = storeMock.added[0]
            compare(f.title, "Prüfe Brent")          // Titel-Fallback aus dem Prompt
            compare(f.prompt, "Prüfe Brent")
            compare(f.timeOfDay, "09:05")            // normalisiert
            verify(f.nextRun > Date.now())           // 09:05 liegt nach jetzt (immer)
            compare(sched.routineList.length, 0)     // Liste kommt erst per writeCompleted
        }
        function test_createRoutine_ohnePrompt_liestFehler() {
            var res = sched.createRoutine({ "title": "x" })
            compare(res.ok, false)
            compare(storeMock.added.length, 0)
        }
        function test_updateRoutine_rescheduleRechnetNeu() {
            storeMock.rows = [{ "id": "r1", "title": "t", "prompt": "p", "kind": "daily",
                                "timeOfDay": "23:00", "weekday": 0, "intervalMinutes": 60,
                                "enabled": true, "nextRun": Date.now() + 3600000,
                                "lastRun": 0, "lastStatus": "", "lastConversation": "" }]
            sched.refresh()
            compare(sched.routineList.length, 1)
            // nur Titel -> kein Reschedule
            sched.updateRoutine("r1", { "title": "neu" })
            compare(storeMock.updates.length, 1)
            verify(!("nextRun" in storeMock.updates[0][1]))
            // Zeitplan-Änderung -> nextRun neu
            sched.updateRoutine("r1", { "timeOfDay": "23:30" })
            compare(storeMock.updates.length, 2)
            verify(storeMock.updates[1][1].nextRun > Date.now())
            // Pausieren -> nextRun 0 (ungeplant)
            sched.updateRoutine("r1", { "enabled": false })
            compare(storeMock.updates[2][1].nextRun, 0)
        }
        function test_scheduleText() {
            compare(sched.scheduleText({ "kind": "daily", "timeOfDay": "12:00" }), "täglich 12:00")
            compare(sched.scheduleText({ "kind": "weekly", "timeOfDay": "09:00", "weekday": 0 }), "Mo 09:00")
            compare(sched.scheduleText({ "kind": "interval", "intervalMinutes": 90 }), "alle 90 min")
            compare(sched.scheduleText({ "kind": "interval", "intervalMinutes": 120 }), "alle 2 h")
            compare(sched.scheduleText({ "kind": "interval", "intervalMinutes": 30 }), "alle 30 min")
            compare(sched.scheduleText({ "kind": "once", "timeOfDay": "22:00" }), "einmalig 22:00")
        }

        // ---- Claim -> Lauf -> Buchhaltung ----
        function test_claimStartetLaufInEigenerEngine() {
            var res = { ok: false }
            storeMock.due = [{ "id": "r9", "title": "Brent-Preis", "prompt": "Prüfe den Preis",
                               "kind": "daily", "timeOfDay": "12:00", "weekday": 0,
                               "intervalMinutes": 60 }]
            storeMock.claimRoutines(Date.now())
            compare(sched.activeRunId, "r9")
            compare(sched._engine.busy, true)
            compare(sched._engine.state, "streaming")
            // eigene Konversation, Prompt mit Routine-Stempel; Titel-Zweikampf:
            // _maybeSetTitle (Prompt-Ausschnitt) + Scheduler-Touch (⟳) — der
            // Scheduler-Touch ist in der Write-Queue der LETZTE und gewinnt.
            compare(sched._engine.chatModel.get(0).text, "⟳ Brent-Preis")
            compare(storeMock.touched.length, 2)
            compare(storeMock.touched[1][1], "⟳ Brent-Preis")
            compare(storeMock.updates.length, 0)   // noch keine Buchhaltung während des Laufs

            lastJob.done({ content: "Brent liegt bei 70 USD.", thinking: "", toolCalls: [] })
            wait(1)    // Qt.callLater: Finish läuft nach dem busyChanged-Stack
            compare(sched._engine.busy, false)
            compare(sched.activeRunId, "")
            // Buchhaltung: ok + Claim frei + nächster Lauf in der Zukunft
            compare(storeMock.updates.length, 1)
            compare(storeMock.updates[0][0], "r9")
            var f = storeMock.updates[0][1]
            compare(f.lastStatus, "ok")
            compare(f.claimToken, "")
            verify(f.nextRun > Date.now())
            compare(f.lastConversation, sched._engine.conversationId)
        }
        function test_claimFehlerFuehrtZuErrorStatus() {
            storeMock.due = [{ "id": "r1", "title": "t", "prompt": "p", "kind": "daily",
                               "timeOfDay": "12:00", "weekday": 0, "intervalMinutes": 60 }]
            storeMock.claimRoutines(Date.now())
            lastJob.error("Verbindung fehlgeschlagen")
            wait(1)
            compare(sched.activeRunId, "")
            compare(storeMock.updates.length, 1)
            compare(storeMock.updates[0][1].lastStatus, "error")
            verify(storeMock.updates[0][1].nextRun > Date.now())
        }
        function test_onceDeaktiviertSichNachLauf() {
            storeMock.rows = [{ "id": "r2", "title": "einmal", "prompt": "p", "kind": "once",
                                "timeOfDay": "23:59", "weekday": 0, "intervalMinutes": 60,
                                "enabled": true, "nextRun": Date.now() - 1000,
                                "lastRun": 0, "lastStatus": "", "lastConversation": "" }]
            sched.refresh()
            storeMock.due = [{ "id": "r2", "title": "einmal", "prompt": "p", "kind": "once",
                               "timeOfDay": "23:59", "weekday": 0, "intervalMinutes": 60 }]
            storeMock.claimRoutines(Date.now())
            lastJob.done({ content: "erledigt", thinking: "", toolCalls: [] })
            wait(1)
            compare(storeMock.updates.length, 1)
            compare(storeMock.updates[0][1].enabled, false)
            compare(storeMock.updates[0][1].nextRun, 0)
        }
        function test_zweiClaimsLaufenNacheinander() {
            storeMock.due = [
                { "id": "rA", "title": "A", "prompt": "pa", "kind": "daily", "timeOfDay": "12:00",
                  "weekday": 0, "intervalMinutes": 60 },
                { "id": "rB", "title": "B", "prompt": "pb", "kind": "daily", "timeOfDay": "13:00",
                  "weekday": 0, "intervalMinutes": 60 }
            ]
            storeMock.claimRoutines(Date.now())
            compare(sched.activeRunId, "rA")
            compare(sched._queue.length, 1)        // B wartet
            lastJob.done({ content: "a", thinking: "", toolCalls: [] })
            wait(1)
            // A abgeschlossen (Buchhaltung), B startet automatisch
            compare(storeMock.updates.length, 1)
            compare(sched.activeRunId, "rB")
            compare(sched._engine.busy, true)
            lastJob.done({ content: "b", thinking: "", toolCalls: [] })
            wait(1)
            compare(sched.activeRunId, "")
            compare(storeMock.updates.length, 2)
        }
        function test_runNowAußerDerReihe() {
            storeMock.rows = [{ "id": "r5", "title": "manuell", "prompt": "p", "kind": "daily",
                                "timeOfDay": "12:00", "weekday": 0, "intervalMinutes": 60,
                                "enabled": true, "nextRun": Date.now() + 7200000,
                                "lastRun": 0, "lastStatus": "", "lastConversation": "" }]
            sched.refresh()
            var res = sched.runNow("r5")
            compare(res.ok, true)
            compare(sched.activeRunId, "r5")
            lastJob.done({ content: "x", thinking: "", toolCalls: [] })
            wait(1)
            compare(storeMock.updates.length, 1)
            verify(storeMock.updates[0][1].nextRun > Date.now())   // regulär neu angesetzt
        }
        function test_geloeschteRoutineKeineBuchhaltung() {
            storeMock.due = [{ "id": "rX", "title": "weg", "prompt": "p", "kind": "daily",
                               "timeOfDay": "12:00", "weekday": 0, "intervalMinutes": 60 }]
            storeMock.claimRoutines(Date.now())
            compare(sched.activeRunId, "rX")
            // Nutzer löscht während des Laufs
            sched.deleteRoutine("rX")
            lastJob.done({ content: "x", thinking: "", toolCalls: [] })
            wait(1)
            compare(sched.activeRunId, "")
            compare(storeMock.updates.length, 0)   // keine Wiederauferstehung
        }
    }
}
