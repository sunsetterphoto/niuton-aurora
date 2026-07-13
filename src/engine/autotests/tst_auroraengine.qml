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
        function test_modelApiDelegates() {
            engine.selectModel("qwen3.5:9b")
            compare(mmMock.selectedModel, "qwen3.5:9b")
        }
    }
}
