import QtQuick
import QtTest
import net.niuton.aurora.engine

Item {
    // Mock-Store: zeichnet updateMessage-Aufrufe auf
    QtObject {
        id: storeMock
        property var lastUpdate: null
        property int updateCount: 0
        function newUuid() { return "u" }
        function appendMessage(m) {}
        function updateMessage(id, f) { lastUpdate = { "id": id, "fields": f }; updateCount++ }
        function deleteMessage(id) {}
        function touchConversation(id, t) {}
        function messages(cid) { return [] }
        function appendToolCall(tc) {}
        function updateToolCall(id, f) {}
    }
    QtObject { id: settingsMock; property int toolMaxRounds: 5; property string comfyDefaultModel: "z_image_turbo"
        function paramsFor(name) { return ({}) } }

    ChatController {
        id: ctl
        store: storeMock
        settings: settingsMock
        activeModel: "qwen3.5:2b"
    }

    TestCase {
        name: "ChatControllerRating"

        function init() {
            ctl.chatModel.clear()
            storeMock.updateCount = 0
            storeMock.lastUpdate = null
        }

        function test_rateMessage_persistiertUndAktualisiertModell() {
            ctl._appendRow({ msgId: "m1", isUser: false, text: "antwort" })
            ctl.rateMessage("m1", 1)
            compare(storeMock.updateCount, 1)
            compare(storeMock.lastUpdate.id, "m1")
            compare(storeMock.lastUpdate.fields.rating, 1)
            compare(ctl.chatModel.get(0).rating, 1)
        }

        function test_rateMessage_toggleZurueckAufNeutral() {
            ctl._appendRow({ msgId: "m1", isUser: false, text: "antwort", rating: 1 })
            ctl.rateMessage("m1", 0)          // in-place-Entfernen
            compare(storeMock.lastUpdate.fields.rating, 0)
            compare(ctl.chatModel.get(0).rating, 0)
        }

        function test_rateMessage_leereMsgId_istNoop() {
            ctl.rateMessage("", 1)
            compare(storeMock.updateCount, 0)
        }
    }
}
