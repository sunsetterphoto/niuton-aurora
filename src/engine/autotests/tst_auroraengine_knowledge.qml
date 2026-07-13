import QtQuick
import QtTest
import net.niuton.aurora.engine

Item {
    id: root

    property var embedResult: null
    property string embedInput: ""
    property int embedCalls: 0

    // Voller Store-Mock (Basis wie tst_auroraengine) + knowledge-Methoden.
    QtObject {
        id: storeMock
        property var added: null
        property var updated: null
        property string deleted: ""
        property var lastEmb: null
        property int embCount: 0
        property int clearCount: 0
        property var entries: []
        function newUuid() { return "kid" }
        function appendMessage(m) {}
        function updateMessage(i, f) {}
        function deleteMessage(i) {}
        function touchConversation(i, t) {}
        function messages(c) { return [] }
        function appendToolCall(t) {}
        function updateToolCall(i, f) {}
        function listConversations(l) { return [] }
        function deleteConversation(i) {}
        function addKnowledge(f) {
            added = f
            entries = [{ "id": f.id, "kind": f.kind, "title": f.title, "url": f.url,
                         "content": f.content, "hasEmbedding": false, "createdAt": "", "updatedAt": "" }]
        }
        function updateKnowledge(id, f) { updated = { "id": id, "fields": f } }
        function deleteKnowledge(id) { deleted = id }
        function setKnowledgeEmbedding(id, vec, model) {
            lastEmb = { "id": id, "vec": vec, "model": model }
            if (vec && vec.length > 0) embCount++
            else clearCount++
        }
        function knowledgeEntries() { return entries }
    }
    QtObject { id: settingsMock; property int toolMaxRounds: 5
        function paramsFor(name) { return ({}) } }

    AuroraEngine {
        id: engine
        store: storeMock
        settings: settingsMock
        embedFn: function(input, cb) { root.embedInput = input; root.embedCalls++; cb(root.embedResult) }
    }

    TestCase {
        name: "AuroraEngineKnowledge"

        function init() {
            storeMock.added = null; storeMock.updated = null; storeMock.deleted = ""
            storeMock.lastEmb = null; storeMock.embCount = 0; storeMock.clearCount = 0
            storeMock.entries = []
            root.embedResult = null; root.embedInput = ""; root.embedCalls = 0
        }

        function test_add_erzeugtIdSchreibtUndBettetEin() {
            root.embedResult = { "vec": [0.1, 0.2], "model": "nomic-embed-text" }
            var id = engine.addKnowledge("link", "Titel", "http://x", "Inhalt")
            compare(id, "kid")
            compare(storeMock.added.kind, "link")
            compare(storeMock.added.title, "Titel")
            compare(storeMock.added.url, "http://x")
            compare(root.embedCalls, 1)
            compare(root.embedInput, "Titel\nInhalt")
            compare(storeMock.embCount, 1)
            compare(storeMock.lastEmb.id, "kid")
            compare(storeMock.lastEmb.vec.length, 2)
            compare(storeMock.lastEmb.model, "nomic-embed-text")
        }

        function test_add_embedNull_keinVektorEintragBleibt() {
            root.embedResult = null
            var id = engine.addKnowledge("note", "T", "", "C")
            compare(storeMock.added.title, "T")
            compare(root.embedCalls, 1)
            compare(storeMock.embCount, 0)
        }

        function test_add_leererText_loeschtOhneEmbed() {
            var id = engine.addKnowledge("note", "", "", "")
            compare(root.embedCalls, 0)     // leerer Text -> kein embedFn
            compare(storeMock.clearCount, 1)
            compare(storeMock.lastEmb.vec.length, 0)
        }

        function test_update_schreibtUndReembed() {
            engine.updateKnowledge("id7", "fact", "NT", "", "NC")
            compare(storeMock.updated.id, "id7")
            compare(storeMock.updated.fields.title, "NT")
            compare(storeMock.updated.fields.kind, "fact")
            compare(root.embedInput, "NT\nNC")
            compare(root.embedCalls, 1)
        }

        function test_remove_loescht() {
            engine.removeKnowledge("id9")
            compare(storeMock.deleted, "id9")
        }

        function test_knowledgeEntries_passthrough() {
            engine.addKnowledge("link", "A", "http://a", "b")
            compare(engine.knowledgeEntries().length, 1)
            compare(engine.knowledgeEntries()[0].title, "A")
        }
    }
}
