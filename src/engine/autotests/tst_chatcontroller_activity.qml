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
        function messages(c){ return [] } function appendToolCall(t){} function updateToolCall(i,f){} }
    QtObject { id: settingsMock; property int toolMaxRounds: 5; property string comfyDefaultModel: "z"
        function paramsFor(name) { return ({}) } }
    QtObject { id: registryMock; property var perm: ({})
        function definitions(c){ return [] } function promptSection(c){ return "" }
        function permissionFor(n){ return perm[n] || "auto" } function categoryOf(n){ return "local" }
        function describe(n,a){ return n + ":" + (a.path || a.query || "") }
        function execute(n,a,c,done){ done("RES", { status:"ok" }) } function abortRunning(){} }
    PermissionResolver { id: realResolver }
    GrantStore { id: realGrants }

    property var lastJob: null
    ChatController { id: ctl; store: storeMock; settings: settingsMock; registry: registryMock
        resolver: realResolver; grants: realGrants
        activeModel: "m"; activeCaps: ["tools"]; homeDir: "/h"
        chatFn: function(req){ var j = jobComp.createObject(ctl); lastJob = j; return j } }
    function call(n,a){ return { "function": { "name": n, "arguments": a||{} } } }
    function activityOf(idx) { return JSON.parse(ctl.chatModel.get(idx).toolActivity) }

    TestCase {
        name: "ChatControllerActivity"
        function init(){ ctl.chatModel.clear(); ctl.conversationId=""; ctl._messages=[]
                         ctl.state="idle"; ctl._activeJob=null; registryMock.perm={}
                         realGrants.clearConversation(""); storeMock.appended=[] }

        function test_toolActivityReflectsRunAndDone() {
            ctl.send("Lies", null)
            lastJob.done({ content:"", thinking:"", toolCalls:[ call("read_file", { path:"/x" }) ] })
            // Die Assistant(tool_calls)-Bubble ist Index 1 (user=0)
            var act = activityOf(1)
            compare(act.length, 1)
            compare(act[0].name, "read_file")
            verify(act[0].describe.indexOf("/x") >= 0)
            compare(act[0].status, "done")           // auto-Tool lief synchron durch
            verify(act[0].durationMs >= 0)
        }

        function test_statusTextDuringTools() {
            ctl.send("Lies", null)
            compare(ctl.statusText.length > 0, true)  // „Aurora denkt/antwortet…"
            lastJob.done({ content:"", thinking:"", toolCalls:[ call("read_file", { path:"/x" }) ] })
            // Nach dem Tool läuft der Folge-Request -> statusText nicht leer
            verify(ctl.statusText.length > 0)
            lastJob.done({ content:"fertig", thinking:"", toolCalls:[] })
            compare(ctl.statusText, "")               // idle -> leer
        }

        function test_pendingToolExposed() {
            registryMock.perm = { "run_command": "confirm" }
            ctl.send("Befehl", null)
            lastJob.done({ content:"", thinking:"", toolCalls:[ call("run_command", { path:"" }) ] })
            compare(ctl.state, "toolPending")
            verify(ctl.pendingTool !== null)
            compare(ctl.pendingTool.name, "run_command")
            // Chip-Status ist "pending"
            compare(activityOf(1)[0].status, "pending")
            ctl.confirmOnce()
            compare(ctl.pendingTool, null)            // nach Bestätigung geräumt
            compare(activityOf(1)[0].status, "done")
        }

        function test_deniedReflectedInActivity() {
            registryMock.perm = { "run_command": "confirm" }
            ctl.send("Befehl", null)
            lastJob.done({ content:"", thinking:"", toolCalls:[ call("run_command", { path:"" }) ] })
            ctl.reject()
            compare(ctl.pendingTool, null)
            compare(activityOf(1)[0].status, "denied")
        }

        function test_appendGeneratedImageAppendsAndPersists() {
            ctl.appendGeneratedImage("/img.png", "a cat")
            var idx = ctl.chatModel.count - 1
            compare(ctl.chatModel.get(idx).mediaPath, "/img.png")
            compare(ctl.chatModel.get(idx).mediaType, "image")
            var found = false
            for (var i = 0; i < storeMock.appended.length; i++)
                if (storeMock.appended[i].mediaPath === "/img.png") found = true
            verify(found)
        }
    }
}
