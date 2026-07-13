import QtQuick
import QtTest
import net.niuton.aurora.engine

Item {
    id: root

    property var embedResult: null    // was die Mock-embedFn zurückgibt
    property string embedInput: ""
    property int embedCalls: 0

    QtObject {
        id: storeMock
        property string questionReturn: ""
        property var lastEmbedding: null
        property int embeddingCount: 0
        property int clearCount: 0
        function newUuid() { return "u" }
        function appendMessage(m) {}
        function updateMessage(id, f) {}
        function deleteMessage(id) {}
        function touchConversation(id, t) {}
        function messages(cid) { return [] }
        function appendToolCall(tc) {}
        function updateToolCall(id, f) {}
        function questionForAnswer(id) { return questionReturn }
        function setEmbedding(id, vec, model) {
            lastEmbedding = { "id": id, "vec": vec, "model": model }
            if (vec && vec.length > 0) embeddingCount++
            else clearCount++
        }
    }
    QtObject { id: settingsMock; property int toolMaxRounds: 5
        function paramsFor(name) { return ({}) } }

    ChatController {
        id: ctl
        store: storeMock
        settings: settingsMock
        activeModel: "qwen3.5:2b"
        embedFn: function(input, cb) {
            root.embedInput = input
            root.embedCalls++
            cb(root.embedResult)
        }
    }

    TestCase {
        name: "ChatControllerEmbed"

        function init() {
            ctl.chatModel.clear()
            storeMock.lastEmbedding = null
            storeMock.embeddingCount = 0
            storeMock.clearCount = 0
            storeMock.questionReturn = ""
            root.embedResult = null
            root.embedInput = ""
            root.embedCalls = 0
        }

        function test_daumenHoch_bettetFrageEinUndSpeichertVektor() {
            storeMock.questionReturn = "Was ist die Hauptstadt von Frankreich?"
            root.embedResult = { "vec": [0.1, 0.2, 0.3], "model": "nomic-embed-text" }
            ctl._appendRow({ msgId: "a1", isUser: false, text: "Paris" })
            ctl.rateMessage("a1", 1)
            compare(root.embedCalls, 1)
            compare(root.embedInput, "Was ist die Hauptstadt von Frankreich?")
            compare(storeMock.embeddingCount, 1)
            compare(storeMock.lastEmbedding.id, "a1")
            compare(storeMock.lastEmbedding.vec.length, 3)
            compare(storeMock.lastEmbedding.model, "nomic-embed-text")
        }

        function test_neutral_loeschtVektor() {
            ctl._appendRow({ msgId: "a1", isUser: false, text: "Paris", rating: 1 })
            ctl.rateMessage("a1", 0)
            compare(root.embedCalls, 0)
            compare(storeMock.clearCount, 1)
            compare(storeMock.lastEmbedding.id, "a1")
            compare(storeMock.lastEmbedding.vec.length, 0)
            compare(storeMock.lastEmbedding.model, "")
        }

        function test_embedNull_speichertNichtsRatingBleibt() {
            storeMock.questionReturn = "Frage"
            root.embedResult = null
            ctl._appendRow({ msgId: "a1", isUser: false, text: "Antwort" })
            ctl.rateMessage("a1", 1)
            compare(root.embedCalls, 1)
            compare(storeMock.embeddingCount, 0)
            compare(ctl.chatModel.get(0).rating, 1)
        }

        function test_leereFrage_bettetNichtEin() {
            storeMock.questionReturn = ""
            root.embedResult = { "vec": [1], "model": "m" }
            ctl._appendRow({ msgId: "a1", isUser: false, text: "Antwort" })
            ctl.rateMessage("a1", 1)
            compare(root.embedCalls, 0)
            compare(storeMock.embeddingCount, 0)
        }
    }
}
