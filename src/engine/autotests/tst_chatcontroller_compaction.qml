import QtQuick
import QtTest
import net.niuton.aurora.engine

Item {
    Component {
        id: jobComp
        QtObject {
            signal token(string t)
            signal thinking(string t)
            signal toolCalls(var calls)
            signal done(var result)
            signal error(string message)
            function abort() {}
        }
    }
    QtObject {
        id: storeMock
        property var lastExtra: null
        property int updateConvCount: 0
        property int _n: 0
        function newUuid() { _n++; return "c" + _n }
        function appendMessage(m) {}
        function updateMessage(id, f) {}
        function deleteMessage(id) {}
        function touchConversation(id, t) {}
        function messages(cid) { return [] }
        function appendToolCall(tc) {}
        function updateToolCall(id, f) {}
        function conversation(id) { return ({ "extra": ({}) }) }
        function updateConversation(id, f) { lastExtra = f.extra; updateConvCount++ }
    }
    QtObject { id: settingsMock; property int toolMaxRounds: 5; property string comfyDefaultModel: "z"
        // kleines num_ctx -> Budget klein -> Kompaktierung greift
        function paramsFor(name) { return ({ "num_ctx": 512 }) } }

    property var lastJob: null
    ChatController {
        id: ctl
        store: storeMock
        settings: settingsMock
        activeModel: "qwen3.5:2b"
        conversationId: "c-test"
        chatFn: function(req) { var j = jobComp.createObject(ctl); lastJob = j; return j }
    }

    function _bigHistory(n) {
        var a = []; var s = ""; for (var k = 0; k < 400; k++) s += "x"
        for (var i = 0; i < n; i++) a.push({ role: (i % 2 === 0 ? "user" : "assistant"), content: s, _msgId: "m" + i })
        return a
    }

    // 30 Nachrichten, Faltgrenze (Index 23 = length - keepRecent - 1) ist eine
    // tool-Zeile ("t99"); die letzte user/assistant davor (Index 22) ist "mKnown".
    function _historyWithToolBoundary() {
        var a = []; var s = ""; for (var k = 0; k < 400; k++) s += "x"
        for (var i = 0; i < 30; i++) {
            if (i === 23) a.push({ role: "tool", content: s, _msgId: "t99" })
            else if (i === 22) a.push({ role: "assistant", content: s, _msgId: "mKnown" })
            else a.push({ role: (i % 2 === 0 ? "user" : "assistant"), content: s, _msgId: "m" + i })
        }
        return a
    }

    TestCase {
        name: "ChatControllerCompaction"

        function init() {
            ctl._messages = []
            ctl._contextSummary = ""
            ctl._summarizedCount = 0
            ctl.state = "idle"                 // busy-Leck aus vorherigem Test verhindern
            ctl.conversationId = "c-test"      // Persist-Ziel je Test isolieren
            lastJob = null
            storeMock.updateConvCount = 0
            storeMock.lastExtra = null
        }

        function test_maybeCompact_fasstZusammenUndPersistiert() {
            ctl._messages = _bigHistory(30)
            var called = false
            ctl._maybeCompact(function() { called = true })
            // _summarize hat via chatFn einen Job gestartet -> Synopse einspeisen
            verify(lastJob !== null)
            verify(ctl.busy)                                  // state busy während der Kompaktierung
            lastJob.token("Synopse.")
            lastJob.done({ content: "Synopse.", thinking: "", toolCalls: [] })
            verify(called)
            compare(ctl._contextSummary, "Synopse.")
            compare(ctl._summarizedCount, 24)                 // 30 - keepRecent(6)
            compare(storeMock.updateConvCount, 1)
            compare(storeMock.lastExtra.contextSummary, "Synopse.")
            compare(storeMock.lastExtra.contextSummaryThroughMsgId, "m23")
            // _buildMessages: system + synopsis-system + 6 wörtliche
            var msgs = ctl._buildMessages()
            compare(msgs.length, 2 + 6)
            compare(msgs[1].content.indexOf("Synopse.") >= 0, true)
        }

        function test_summarize_leer_laesstZustandUnveraendert() {
            ctl._messages = _bigHistory(30)
            var called = false
            ctl._maybeCompact(function() { called = true })
            lastJob.done({ content: "", thinking: "", toolCalls: [] })   // leer -> best-effort
            verify(called)
            compare(ctl._contextSummary, "")
            compare(ctl._summarizedCount, 0)
            compare(storeMock.updateConvCount, 0)
        }

        function test_compact_erzwingtUnterSchwelle() {
            ctl._messages = _bigHistory(10)                   // klein, aber > keepRecent
            ctl.compact()
            verify(lastJob !== null)
            lastJob.done({ content: "Kurz.", thinking: "", toolCalls: [] })
            compare(ctl._contextSummary, "Kurz.")
            compare(ctl._summarizedCount, 4)                  // 10 - 6
            compare(ctl.busy, false)                          // manueller Pfad: danach nicht busy
        }

        // Cross-Conversation-Guard: wechselt der Nutzer während eines laufenden
        // Kompaktierungs-Jobs die Konversation, darf der stale Job den neuen Zustand
        // NICHT anfassen (kein Persist in die neue Konversation, kein Turn).
        function test_staleJobNachKonversationswechselIgnoriert() {
            ctl._messages = _bigHistory(30)
            ctl._maybeCompact(function() {})                  // Job in flight
            verify(lastJob !== null)
            verify(ctl.busy)                                  // busy -> Konversationswechsel ruft stop()
            var staleJob = lastJob
            // Epochenwechsel: newConversation() sieht state != "idle", ruft stop()
            // -> _generation++ + _activeJob.abort()/destroy(); Zustand wird geleert.
            ctl.newConversation()
            compare(ctl.busy, false)                          // stop() -> idle
            compare(lastJob, staleJob)                        // kein neuer Job durch den Wechsel
            // Stale Job feuert verspätet -> Generation-Guard verwirft ihn still.
            staleJob.done({ content: "A-Synopse", thinking: "", toolCalls: [] })
            compare(ctl._contextSummary, "")                  // neue Konversation unverändert
            compare(ctl._summarizedCount, 0)
            compare(storeMock.updateConvCount, 0)             // KEIN Persist der stale Synopse
            compare(lastJob, staleJob)                        // KEIN _startTurn -> kein zweiter Job
        }

        // Persistenz-Anker muss den Reload-Filter überleben: liegt an der Faltgrenze
        // eine tool-Zeile, verankert die Synopse an der letzten user/assistant-Zeile
        // davor (die loadConversation wieder in _messages aufnimmt) — nicht an "t99".
        function test_anker_ueberspringtToolZeile() {
            ctl._messages = _historyWithToolBoundary()
            ctl._maybeCompact(function() {})
            verify(lastJob !== null)
            lastJob.done({ content: "S.", thinking: "", toolCalls: [] })
            compare(storeMock.lastExtra.contextSummaryThroughMsgId, "mKnown")
        }
    }
}
