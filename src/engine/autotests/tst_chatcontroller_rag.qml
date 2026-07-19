import QtQuick
import QtTest
import net.niuton.aurora.engine

// Wissensbasis Scheibe C: Retrieval-Fluss (embed -> searchSimilar -> Prompt-Injektion)
// und Attribution (ragSources-Rolle, extra.ragSources, stripRagSource). Netzfrei:
// embedFn und store.searchSimilar sind Mocks.
Item {
    Component {
        id: jobComp
        QtObject {
            signal token(string t)
            signal thinking(string t)
            signal done(var result)
            signal error(string message)
            property bool aborted: false
            function abort() { aborted = true }
        }
    }

    QtObject {
        id: storeMock
        property var appended: []
        property var updates: []
        property var mockRows: []
        property int _n: 0
        function newUuid() { _n++; return "uuid-" + _n }
        function appendMessage(m) { appended.push(m) }
        function updateMessage(id, f) { updates.push({ "id": id, "fields": f }) }
        function deleteMessage(id) {}
        function touchConversation(id, t) {}
        function messages(cid) { return mockRows }
        function conversation(id) { return ({}) }
        // Scheibe-C-Schnittstelle: liefert die gemockten Treffer
        property var mockHits: []
        property int searchCalls: 0
        function searchSimilar(vec, model, topK, threshold) { searchCalls++; return mockHits }
    }

    QtObject {
        id: settingsMock
        property int toolMaxRounds: 5
        property bool ragEnabled: true
        property int ragTopK: 3
        property double ragThreshold: 0.75
        function paramsFor(name) { return ({}) }
    }

    QtObject { id: registryMock
        function definitions(ctx) { return [] }
        function promptSection(ctx) { return "## Your Tools\n" }
        function permissionFor(n) { return "auto" }
        function describe(n, a) { return n }
        function execute(n, a, ctx, done) { done("") }
        function abortRunning() {}
    }

    property var lastJob: null
    property var lastReq: null
    property var embedCalls: []
    property var embedResult: null     // was embedFn an seinen Callback liefert
    property bool embedAsync: false    // true: Callbacks sammeln statt sofort zu antworten
    property var pendingEmbeds: []

    ChatController {
        id: ctl
        store: storeMock
        settings: settingsMock
        registry: registryMock
        activeModel: "qwen3.5:2b"
        activeCaps: ["tools"]
        homeDir: "/home/x"
        chatFn: function(req) { lastReq = req; var j = jobComp.createObject(ctl); lastJob = j; return j }
        embedFn: function(input, cb) {
            embedCalls.push(input)
            if (embedAsync) pendingEmbeds.push(cb)
            else cb(embedResult)
        }
    }

    TestCase {
        name: "ChatControllerRag"

        function init() {
            ctl.chatModel.clear(); storeMock.appended = []; storeMock.updates = []
            storeMock._n = 0; storeMock.searchCalls = 0
            storeMock.mockHits = [
                { "source": "rated", "id": "a1", "score": 0.91,
                  "question": "Wie boote ich ins BIOS?", "answer": "F2 drücken." },
                { "source": "knowledge", "id": "k1", "score": 0.83, "kind": "fact",
                  "title": "Piper-Pfad", "url": "", "content": "aurora/piper" }
            ]
            ctl.conversationId = ""; ctl._messages = []
            ctl._ragSources = []; ctl._ragByMsgId = ({}); ctl.state = "idle"
            lastJob = null; lastReq = null; embedCalls = []
            pendingEmbeds = []; embedAsync = false; storeMock.mockRows = []
            settingsMock.ragEnabled = true
            embedResult = { "vec": [1.0, 0.0, 0.0], "model": "nomic-embed-text" }
        }

        function test_retrievalInjectsKnowledgeSection() {
            ctl.send("Wie boote ich ins BIOS?", null)
            compare(embedCalls.length, 1)
            compare(embedCalls[0], "Wie boote ich ins BIOS?")
            compare(storeMock.searchCalls, 1)
            verify(lastJob !== null)                       // Zug gestartet
            var sys = lastReq.messages[0].content
            verify(sys.indexOf("## Knowledge base") >= 0)
            verify(sys.indexOf("- Q: Wie boote ich ins BIOS?") >= 0)
            verify(sys.indexOf("  A: F2 drücken.") >= 0)
            verify(sys.indexOf("- Piper-Pfad: aurora/piper") >= 0)
        }

        function test_ragDisabledSkipsEmbed() {
            settingsMock.ragEnabled = false
            ctl.send("Hallo Welt", null)
            compare(embedCalls.length, 0)
            compare(storeMock.searchCalls, 0)
            verify(lastJob !== null)                       // Chat läuft trotzdem
            verify(lastReq.messages[0].content.indexOf("## Knowledge base") < 0)
        }

        function test_embedFailureProceedsWithoutSection() {
            embedResult = null
            ctl.send("Hallo Welt", null)
            compare(embedCalls.length, 1)
            compare(storeMock.searchCalls, 0)
            verify(lastJob !== null)
            verify(lastReq.messages[0].content.indexOf("## Knowledge base") < 0)
        }

        function test_noHitsNoSection() {
            storeMock.mockHits = []
            ctl.send("Hallo Welt", null)
            compare(storeMock.searchCalls, 1)
            verify(lastReq.messages[0].content.indexOf("## Knowledge base") < 0)
        }

        function test_attributionOnFinalize() {
            ctl.send("Wie boote ich ins BIOS?", null)
            lastJob.done({ content: "Drück F2.", thinking: "", toolCalls: [] })
            var row = ctl.chatModel.get(1)
            var slim = JSON.parse(row.ragSources)
            compare(slim.length, 2)
            compare(slim[0].id, "a1")
            compare(slim[0].source, "rated")
            compare(slim[0].label, "Wie boote ich ins BIOS?")
            compare(slim[1].id, "k1")
            compare(slim[1].label, "Piper-Pfad")
            // persistiert: extra.ragSources am appendMessage der assistant-Zeile
            var last = storeMock.appended[storeMock.appended.length - 1]
            compare(last.role, "assistant")
            verify(last.extra && last.extra.ragSources)
            compare(last.extra.ragSources.length, 2)
            // _ragByMsgId gefüllt
            verify(ctl._ragByMsgId[row.msgId] !== undefined)
        }

        function test_stripRagSource() {
            ctl.send("Wie boote ich ins BIOS?", null)
            lastJob.done({ content: "Drück F2.", thinking: "", toolCalls: [] })
            var msgId = ctl.chatModel.get(1).msgId
            ctl.stripRagSource(msgId, "k1")
            var slim = JSON.parse(ctl.chatModel.get(1).ragSources)
            compare(slim.length, 1)
            compare(slim[0].id, "a1")
            // persistenter Strip: updateMessage mit gefiltertem extra
            compare(storeMock.updates.length, 1)
            compare(storeMock.updates[0].id, msgId)
            compare(storeMock.updates[0].fields.extra.ragSources.length, 1)
            // zweiter Strip entfernt den Rest -> Rolle leer, extra = {}
            ctl.stripRagSource(msgId, "a1")
            compare(JSON.parse(ctl.chatModel.get(1).ragSources).length, 0)
            compare(storeMock.updates.length, 2)
            compare(Object.keys(storeMock.updates[1].fields.extra).length, 0)
        }

        function test_newConversationClearsRag() {
            ctl.send("Wie boote ich ins BIOS?", null)
            lastJob.done({ content: "Drück F2.", thinking: "", toolCalls: [] })
            verify(ctl._ragSources.length > 0)
            ctl.newConversation()
            compare(ctl._ragSources.length, 0)
            compare(Object.keys(ctl._ragByMsgId).length, 0)
        }

        // Review-Befund I1: ein verspäteter Embed-Callback eines gestoppten Zuges
        // darf das Retrieval des NEUEN Zuges nicht kapern (send → stop → send).
        function test_staleEmbedCallbackDiscarded() {
            embedAsync = true
            ctl.send("Frage A", null)
            compare(embedCalls.length, 1)
            compare(ctl.state, "streaming")            // Retrieval A läuft
            ctl.stop()
            compare(ctl.state, "idle")
            ctl.send("Frage B", null)
            compare(embedCalls.length, 2)              // Retrieval B läuft
            // A's verspäteter Callback: muss verworfen werden — KEIN _startTurn
            pendingEmbeds[0]({ "vec": [1.0, 0.0, 0.0], "model": "m" })
            compare(lastJob, null)
            compare(storeMock.searchCalls, 0)
            // B's Callback: ganz normal weiter
            pendingEmbeds[1]({ "vec": [1.0, 0.0, 0.0], "model": "m" })
            compare(storeMock.searchCalls, 1)
            verify(lastJob !== null)
            verify(lastReq.messages[0].content.indexOf("## Knowledge base") >= 0)
        }

        // Liveness: der 8-s-Timeout startet den Zug ohne Treffer.
        function test_ragTimeoutProceedsWithoutHits() {
            embedAsync = true
            ctl.send("Frage", null)
            compare(lastJob, null)
            ctl._onRagTimeout()
            verify(lastJob !== null)
            compare(storeMock.searchCalls, 0)
            verify(lastReq.messages[0].content.indexOf("## Knowledge base") < 0)
            // ein späterer echter Callback ist verworfen (done)
            pendingEmbeds[0]({ "vec": [1.0], "model": "m" })
            compare(storeMock.searchCalls, 0)
        }

        // stop() während Retrieval: kein _startTurn, keine abgebrochene Zeile.
        function test_stopDuringRetrieval() {
            embedAsync = true
            ctl.send("Frage", null)
            ctl.stop()
            compare(ctl.state, "idle")
            compare(lastJob, null)
            compare(storeMock.appended.length, 1)      // nur die user-Nachricht
            compare(storeMock.appended[0].role, "user")
        }

        // Reload-Rundweg: Attribution aus extra.ragSources restaurieren + Strip.
        function test_loadConversationRestoresAttribution() {
            var slim = [ { "source": "rated", "id": "a1", "label": "BIOS?", "score": 0.91 } ]
            storeMock.mockRows = [
                { "id": "u1", "role": "user", "content": "frage", "createdAt": "2026-07-18T10:00:00.000Z",
                  "mediaPath": "", "extra": ({}), "rating": 0 },
                { "id": "a9", "role": "assistant", "content": "antwort", "createdAt": "2026-07-18T10:01:00.000Z",
                  "mediaPath": "", "extra": { "ragSources": slim }, "rating": 0 }
            ]
            ctl.loadConversation("c1")
            compare(ctl.chatModel.count, 2)
            var restored = JSON.parse(ctl.chatModel.get(1).ragSources)
            compare(restored.length, 1)
            compare(restored[0].id, "a1")
            verify(ctl._ragByMsgId["a9"] !== undefined)
            // Strip nach Reload schreibt updateMessage mit leerem extra
            ctl.stripRagSource("a9", "a1")
            compare(JSON.parse(ctl.chatModel.get(1).ragSources).length, 0)
            compare(storeMock.updates.length, 1)
            compare(storeMock.updates[0].id, "a9")
        }
    }
}
