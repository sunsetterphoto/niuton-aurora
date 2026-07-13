import QtQuick
import QtTest
import net.niuton.aurora.engine

Item {
    Component { id: jobComp; QtObject {
        signal token(string t); signal thinking(string t); signal toolCalls(var calls)
        signal done(var result); signal error(string message)
        property bool aborted: false; function abort(){ aborted = true }
    } }
    QtObject { id: storeMock; property var appended: []; property var deleted: []; property int _n: 0
        property var rows: []
        function newUuid(){ _n++; return "u"+_n } function appendMessage(m){ appended.push(m) }
        function updateMessage(i,f){} function deleteMessage(i){ deleted.push(i) } function touchConversation(i,t){}
        function messages(c){ return rows } function appendToolCall(t){} function updateToolCall(i,f){}
        function conversation(id){ return ({ "extra": ({}) }) } function updateConversation(id,f){} }
    QtObject { id: settingsMock; property int toolMaxRounds: 5; property string comfyDefaultModel: "z"
        function paramsFor(name) { return ({}) } }
    QtObject { id: registryMock; property var execLog: []; property var perm: ({})
        function definitions(c){ return [] } function promptSection(c){ return "" }
        function permissionFor(n){ return perm[n] || "auto" } function categoryOf(n){ return "local" }
        function describe(n,a){ return n } function execute(n,a,c,done){ execLog.push(n); done("R",{status:"ok"}) }
        property bool abortCalled: false; function abortRunning(){ abortCalled = true } }

    // echte 5b-Logikbausteine injizieren (sonst wirft der guardlose _decide null.decide)
    PermissionResolver { id: realResolver }
    GrantStore { id: realGrants }

    property var lastJob: null
    ChatController { id: ctl; store: storeMock; settings: settingsMock; registry: registryMock
        resolver: realResolver; grants: realGrants
        activeModel: "m"; activeCaps: ["tools"]; homeDir: "/h"
        chatFn: function(req){ var j = jobComp.createObject(ctl); lastJob = j; return j } }
    function call(n,a){ return { "function": { "name": n, "arguments": a||{} } } }

    TestCase {
        name: "ChatControllerStop"
        function init(){ ctl.chatModel.clear(); storeMock.appended=[]; storeMock.deleted=[]
                         storeMock.rows=[]; storeMock._n=0; ctl.conversationId="c1"; ctl._messages=[]
                         registryMock.execLog=[]; registryMock.abortCalled=false; registryMock.perm={}
                         realGrants.clearConversation("c1")
                         ctl.state="idle"; ctl._activeJob=null }

        function test_stopDuringStreamPersistsAborted() {
            ctl.send("Hi", null)
            lastJob.token("Teilant")
            ctl.stop()
            compare(lastJob.aborted, true)
            compare(ctl.state, "idle")
            var last = storeMock.appended[storeMock.appended.length - 1]
            compare(last.status, "aborted")
            verify(last.content.indexOf("Teilant") >= 0)
        }

        function test_lateSignalAfterStopIgnored() {
            ctl.send("Hi", null)
            var job = lastJob
            ctl.stop()
            var cntNach = ctl.chatModel.count
            job.token("späte tokens")            // Generation veraltet -> ignoriert
            job.done({ content:"x", thinking:"", toolCalls:[] })
            compare(ctl.chatModel.count, cntNach)
            compare(ctl.state, "idle")
        }

        function test_stopDuringToolPendingDiscards() {
            // toolPending simulieren: confirm-Tool (Datenzuweisung, KEIN Funktions-Reassign
            // — QML-Methoden sind read-only)
            registryMock.perm = { "run_command": "confirm" }
            ctl.send("Befehl", null)
            lastJob.done({ content:"", thinking:"", toolCalls:[ call("run_command", { command:"x" }) ] })
            compare(ctl.state, "toolPending")
            ctl.stop()
            compare(ctl.state, "idle")
            // Klick nach Stopp darf nicht ausführen
            ctl.confirmOnce()
            compare(registryMock.execLog.length, 0)
        }

        function test_regenerateDeletesAndResends() {
            ctl.send("Frage", null)
            lastJob.done({ content:"Antwort", thinking:"", toolCalls:[] })
            var appendedBefore = storeMock.appended.length
            ctl.regenerate()
            // letzte assistant + user aus DB gelöscht, neuer Zug gestartet
            verify(storeMock.deleted.length >= 2)
            verify(ctl.busy)
        }

        function test_loadConversationRebuildsModel() {
            storeMock.rows = [
                { id:"1", role:"user", content:"Frage", status:"final", createdAt: 0, thinking:"" },
                { id:"2", role:"assistant", content:"Antwort", status:"final", createdAt: 0, thinking:"" }
            ]
            ctl.loadConversation("c9")
            compare(ctl.conversationId, "c9")
            compare(ctl.chatModel.count, 2)
            compare(ctl.chatModel.get(0).isUser, true)
            compare(ctl.chatModel.get(1).text, "Antwort")
        }

        function test_abortedPartialStaysInContext() {
            ctl.send("Erste", null)
            lastJob.token("Teil")
            ctl.stop()
            ctl.send("Zweite", null)
            // Keine zwei aufeinanderfolgenden user-Turns: die abgebrochene assistant-
            // Teilantwort muss zwischen den beiden user-Nachrichten im Kontext liegen.
            var twoUsersInARow = false, prevRole = ""
            for (var i = 0; i < ctl._messages.length; i++) {
                if (ctl._messages[i].role === "user" && prevRole === "user") twoUsersInARow = true
                prevRole = ctl._messages[i].role
            }
            verify(!twoUsersInARow)
            var hasAborted = false
            for (var j = 0; j < ctl._messages.length; j++)
                if (ctl._messages[j].role === "assistant" && ctl._messages[j].content.indexOf("Teil") >= 0)
                    hasAborted = true
            verify(hasAborted)
        }

        function test_regenerateAfterLoadDeletesRows() {
            storeMock.rows = [
                { id:"r1", role:"user", content:"Frage", status:"final", createdAt: 0, thinking:"" },
                { id:"r2", role:"assistant", content:"Antwort", status:"final", createdAt: 0, thinking:"" }
            ]
            ctl.loadConversation("c9")
            var delBefore = storeMock.deleted.length
            ctl.regenerate()
            verify(storeMock.deleted.length - delBefore >= 2)   // beide geladenen Rows gelöscht
            verify(storeMock.deleted.indexOf("r2") >= 0)
            verify(ctl.busy)
        }

        function test_regenerateAfterToolTurn() {
            ctl.send("Frage mit Tool", null)
            lastJob.done({ content:"", thinking:"", toolCalls:[ call("read_file", { path:"/x" }) ] })  // Tool-Zug
            lastJob.done({ content:"Endantwort", thinking:"", toolCalls:[] })                            // finale Antwort
            var delBefore = storeMock.deleted.length
            ctl.regenerate()
            // user + asst(tool_calls) + tool + asst(final) = 4 DB-Rows des Zuges gelöscht
            verify(storeMock.deleted.length - delBefore >= 4)
            verify(ctl.busy)     // neuer Zug gestartet (nicht haengengeblieben)
        }
    }
}
