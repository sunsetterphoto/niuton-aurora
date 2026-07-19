import QtQuick
import QtTest
import net.niuton.aurora.engine

Item {
    Component { id: jobComp; QtObject {
        signal token(string t); signal thinking(string t); signal toolCalls(var calls)
        signal done(var result); signal error(string message)
        function abort(){}
    } }
    QtObject { id: storeMock; property int _n: 0; property var appended: []
        function newUuid(){ _n++; return "u"+_n } function appendMessage(m){ appended.push(m) }
        function updateMessage(i,f){} function deleteMessage(i){} function touchConversation(i,t){}
        function messages(c){ return [] } function appendToolCall(t){} function updateToolCall(i,f){}
        function listConversations(l){ return [ { id:"c1", title:"Chat", createdAt:0 } ] }
        function deleteConversation(i){} }
    QtObject { id: settingsMock; property int toolMaxRounds: 5; property string comfyDefaultModel: "z"
        function paramsFor(name) { return ({}) } }
    QtObject { id: registryMock
        function definitions(c){ return [] } function promptSection(c){ return "" }
        function permissionFor(n){ return "auto" } function categoryOf(n){ return "local" }
        function describe(n,a){ return n } function execute(n,a,c,done){ done("",{status:"ok"}) } function abortRunning(){} }
    QtObject { id: mmMock; property string activeModel: "m"; property var activeCaps: ["tools"]
        property bool isRemote: false; property string selectedModel: "m"
        function selectModel(v){ selectedModel = v } }
    // Grants-Mocks fuer den deleteConversation-Audit-Fix: einer MIT Zaehler,
    // einer bewusst OHNE clearConversation (Feature-Detect muss greifen)
    QtObject { id: grantsMock; property var cleared: []
        function grant(c, t) {} function hasGrant(c, t) { return false }
        function clearConversation(id) { cleared.push(id) } }
    QtObject { id: slimGrants
        function grant(c, t) {} function hasGrant(c, t) { return false } }

    property var lastJob: null
    AuroraEngine {
        id: engine
        modelManager: mmMock; store: storeMock; settings: settingsMock; registry: registryMock
        homeDir: "/h"
        chatFn: function(req){ var j = jobComp.createObject(engine); lastJob = j; return j }
    }

    TestCase {
        name: "AuroraEngine"
        function test_sendDelegatesAndExposesState() {
            engine.newConversation()
            engine.send("Hallo", null)
            compare(engine.busy, true)
            compare(engine.state, "streaming")
            verify(engine.chatModel.count >= 2)
            lastJob.done({ content:"Hi", thinking:"", toolCalls:[] })
            compare(engine.state, "idle")
            compare(engine.busy, false)
        }
        function test_conversationApi() {
            var list = engine.listConversations()
            compare(list.length, 1)
            compare(list[0].id, "c1")
        }
        // Audit-Fix (Klein/resource-leak): Per-Konversation-Grants werden beim
        // Loeschen der Konversation mit aufgeraeumt (feature-detektiert, damit
        // schlanke Mocks ohne clearConversation gruen bleiben).
        function test_deleteConversationCleartGrants() {
            var orig = engine.grants
            engine.grants = grantsMock
            grantsMock.cleared = []
            engine.deleteConversation("c-del")
            compare(grantsMock.cleared.length, 1)
            compare(grantsMock.cleared[0], "c-del")
            // schlanker Mock OHNE clearConversation: kein Throw
            engine.grants = slimGrants
            engine.deleteConversation("c-del2")
            engine.grants = orig
        }
        function test_modelApiDelegates() {
            engine.selectModel("qwen3.5:9b")
            compare(mmMock.selectedModel, "qwen3.5:9b")
        }
    }
}
