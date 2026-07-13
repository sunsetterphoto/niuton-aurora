import QtQuick
import QtTest
import net.niuton.aurora.engine

Item {
    // Mock-ChatJob: Signale, die der Test von außen feuert
    Component {
        id: jobComp
        QtObject {
            signal token(string t)
            signal thinking(string t)
            signal toolCalls(var calls)
            signal done(var result)
            signal error(string message)
            property bool aborted: false
            function abort() { aborted = true }
        }
    }

    // Mock-Store: zeichnet appendMessage-Aufrufe auf
    QtObject {
        id: storeMock
        property var appended: []
        property int _n: 0
        function newUuid() { _n++; return "uuid-" + _n }
        function appendMessage(m) { appended.push(m) }
        function updateMessage(id, f) {}
        function deleteMessage(id) {}
        function touchConversation(id, t) {}
        function messages(cid) { return [] }
        function appendToolCall(tc) {}
        function updateToolCall(id, f) {}
    }

    QtObject { id: settingsMock; property int toolMaxRounds: 5; property string comfyDefaultModel: "z_image_turbo"
        function paramsFor(name) { return ({}) } }
    QtObject { id: registryMock
        function definitions(ctx) { return [] }
        function promptSection(ctx) { return "## Your Tools\n" }
        function permissionFor(n) { return "auto" }
        function describe(n, a) { return n }
        function execute(n, a, ctx, done) { done("") }
        function abortRunning() {}
    }

    property var lastJob: null
    ChatController {
        id: ctl
        store: storeMock
        settings: settingsMock
        registry: registryMock
        activeModel: "qwen3.5:2b"
        activeCaps: ["tools"]
        homeDir: "/home/x"
        chatFn: function(req) { var j = jobComp.createObject(ctl); lastJob = j; return j }
    }

    SignalSpy { id: finalSpy; target: ctl; signalName: "assistantFinal" }

    TestCase {
        name: "ChatControllerStream"
        function init() { ctl.chatModel.clear(); storeMock.appended = []; storeMock._n = 0
                          ctl.conversationId = ""; ctl._messages = []
                          // qmltestrunner ruft Testfunktionen alphabetisch auf (nicht in
                          // Deklarationsreihenfolge); test_sendAppendsUserAndPlaceholder lässt
                          // seinen Job absichtlich offen (state bleibt "streaming"), das würde
                          // sonst in nachfolgende Tests durchsickern.
                          ctl.state = "idle" }

        function test_sendAppendsUserAndPlaceholder() {
            ctl.send("Hallo", null)
            compare(ctl.chatModel.count, 2)                 // user + assistant-Platzhalter
            compare(ctl.chatModel.get(0).isUser, true)
            compare(ctl.chatModel.get(0).text, "Hallo")
            compare(ctl.chatModel.get(1).isUser, false)
            compare(ctl.chatModel.get(1).streaming, true)
            compare(ctl.state, "streaming")
            compare(ctl.busy, true)
            // user-Msg sofort persistiert
            compare(storeMock.appended.length, 1)
            compare(storeMock.appended[0].role, "user")
        }

        function test_tokensAccumulateIntoPlaceholder() {
            ctl.send("Hi", null)
            lastJob.token("Hal")
            lastJob.token("lo!")
            compare(ctl.chatModel.get(1).text, "Hallo!")
        }

        function test_doneFinalizesAndPersists() {
            ctl.send("Hi", null)
            lastJob.token("Antwort")
            lastJob.done({ content: "Antwort", thinking: "", toolCalls: [] })
            compare(ctl.chatModel.get(1).streaming, false)
            compare(ctl.chatModel.get(1).text, "Antwort")
            compare(ctl.state, "idle")
            compare(ctl.busy, false)
            // assistant final persistiert
            var last = storeMock.appended[storeMock.appended.length - 1]
            compare(last.role, "assistant")
            compare(last.status, "final")
        }

        function test_errorShowsMessageAndFinalizes() {
            ctl.send("Hi", null)
            lastJob.error("boom")
            verify(ctl.chatModel.get(1).text.indexOf("boom") >= 0)
            compare(ctl.state, "idle")
            var last = storeMock.appended[storeMock.appended.length - 1]
            compare(last.status, "error")
        }

        function test_emptyAnswerFinalizesNoLoop() {
            ctl.send("Hi", null)
            lastJob.done({ content: "", thinking: "", toolCalls: [] })
            compare(ctl.state, "idle")
            compare(ctl.busy, false)
        }

        function test_sendIgnoredWhileBusy() {
            ctl.send("Erste", null)
            var cntNach1 = ctl.chatModel.count
            ctl.send("Zweite", null)                        // busy -> no-op
            compare(ctl.chatModel.count, cntNach1)
        }

        // Auto-Vorlesen-Trigger: assistantFinal feuert bei "final" mit dem Text,
        // aber NICHT bei error/aborted.
        function test_assistantFinalFiresOnDone() {
            finalSpy.clear()
            ctl.send("Hi", null)
            lastJob.token("Antwort")                        // _content akkumuliert aus Tokens
            lastJob.done({ content: "Antwort", thinking: "", toolCalls: [] })
            compare(finalSpy.count, 1)
            compare(finalSpy.signalArguments[0][0], "Antwort")
        }

        function test_assistantFinalNotOnError() {
            finalSpy.clear()
            ctl.send("Hi", null)
            lastJob.error("boom")
            compare(finalSpy.count, 0)
        }

        function test_assistantFinalNotOnAbort() {
            finalSpy.clear()
            ctl.send("Hi", null)
            lastJob.token("Teil")
            ctl.stop()
            compare(finalSpy.count, 0)
        }
    }
}
