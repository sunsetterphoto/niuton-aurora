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
        property var toolCalls: []
        property var toolUpdates: []
        property var toolCallsReply: []
        property var messagesReply: []
        function newUuid(){ _n++; return "u"+_n } function appendMessage(m){ appended.push(m) }
        function updateMessage(i,f){} function deleteMessage(i){} function touchConversation(i,t){}
        function messages(c){ return messagesReply } function appendToolCall(t){ toolCalls.push(t) }
        function updateToolCall(i,f){ toolUpdates.push({ "id": i, "fields": f }) }
        function toolCallsForConversation(c){ return toolCallsReply }
        function conversation(id){ return null } }
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
                         realGrants.clearConversation(""); storeMock.appended=[]
                         storeMock.toolCalls=[]; storeMock.toolUpdates=[]
                         storeMock.toolCallsReply=[]; storeMock.messagesReply=[] }

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

        // Task 4 (Fix nach Review): tool-initiiertes Bild erscheint sichtbar +
        // persistiert, aber KEIN assistant-Eintrag in die API-History (_messages) —
        // sonst zerreißt die Reihenfolge zwischen assistant(tool_calls) und dem
        // tool-Ergebnis. Manuelles Bild (Flag false/undefined) gehört sehr wohl rein.
        function test_toolImageNotPushedToApiHistory() {
            var before = ctl._messages.length
            ctl.appendGeneratedImage("/t.png", "x", true)
            compare(ctl._messages.length, before)                              // NICHT in _messages
            compare(ctl.chatModel.get(ctl.chatModel.count - 1).mediaPath, "/t.png")  // aber sichtbar
        }
        function test_manualImagePushedToApiHistory() {
            var before = ctl._messages.length
            ctl.appendGeneratedImage("/m.png", "y", false)
            compare(ctl._messages.length, before + 1)                          // manuell: in _messages
        }

        // Video: gleiche Bubble-Semantik wie Bild, aber mediaType "video".
        function test_appendGeneratedVideoAppendsAndPersists() {
            ctl.appendGeneratedVideo("/v.mp4", "eine Welle")
            var idx = ctl.chatModel.count - 1
            compare(ctl.chatModel.get(idx).mediaPath, "/v.mp4")
            compare(ctl.chatModel.get(idx).mediaType, "video/mp4")
            var found = false
            for (var i = 0; i < storeMock.appended.length; i++)
                if (storeMock.appended[i].mediaPath === "/v.mp4") found = true
            verify(found)
        }
        function test_toolVideoNotPushedToApiHistory() {
            var before = ctl._messages.length
            ctl.appendGeneratedVideo("/t.mp4", "x", true)
            compare(ctl._messages.length, before)                              // NICHT in _messages
            compare(ctl.chatModel.get(ctl.chatModel.count - 1).mediaPath, "/t.mp4")
        }

        // Audio wie Bild/Video, aber mediaType "audio/wav" (Wiedergabe via aplay).
        function test_appendGeneratedAudioAppendsAndPersists() {
            ctl.appendGeneratedAudio("/a.wav", "etwas Melodisches")
            var idx = ctl.chatModel.count - 1
            compare(ctl.chatModel.get(idx).mediaPath, "/a.wav")
            compare(ctl.chatModel.get(idx).mediaType, "audio/wav")
            var found = false
            for (var i = 0; i < storeMock.appended.length; i++)
                if (storeMock.appended[i].mediaPath === "/a.wav") found = true
            verify(found)
        }
        function test_toolAudioNotPushedToApiHistory() {
            var before = ctl._messages.length
            ctl.appendGeneratedAudio("/t.wav", "x", true)
            compare(ctl._messages.length, before)
            compare(ctl.chatModel.get(ctl.chatModel.count - 1).mediaPath, "/t.wav")
        }

        // Persistenz-Spur (toolActivity-Reload): der Zug schreibt tool_calls-
        // Zeilen (appendToolCall pending) und aktualisiert sie über den Lauf
        // (running -> ok mit finishedAt + resultMessageId, gleiche dbId).
        function test_toolCallsWerdenPersistiert() {
            ctl.send("Lies", null)
            lastJob.done({ content:"", thinking:"", toolCalls:[ call("read_file", { path:"/x" }) ] })
            compare(storeMock.toolCalls.length, 1)
            var tc = storeMock.toolCalls[0]
            compare(tc.toolName, "read_file")
            compare(tc.status, "pending")
            compare(tc.callIndex, 0)
            compare(tc.messageId, storeMock.appended[1].id)   // assistant-Zwischenzeile
            var statuses = []
            for (var i = 0; i < storeMock.toolUpdates.length; i++)
                statuses.push(storeMock.toolUpdates[i].fields.status)
            verify(statuses.indexOf("running") !== -1)
            verify(statuses.indexOf("ok") !== -1)
            var okUpd = null
            for (var j = 0; j < storeMock.toolUpdates.length; j++)
                if (storeMock.toolUpdates[j].fields.status === "ok") okUpd = storeMock.toolUpdates[j]
            compare(okUpd.id, tc.id)                          // gleiche dbId
            verify(okUpd.fields.finishedAt.length > 0)
            verify(okUpd.fields.resultMessageId !== undefined && okUpd.fields.resultMessageId !== "")
        }

        // Reload: leere assistant-Zwischenzeile mit tool_calls-Spur bleibt als
        // reine Chip-Bubble sichtbar (DB-"ok" -> UI-"done", Dauer aus den
        // Zeitstempeln), geht aber NICHT in die API-History (_messages).
        function test_reloadRestauriertToolActivity() {
            storeMock.messagesReply = [
                { id: "u1", role: "user", content: "Lies /x", createdAt: "2026-07-25T10:00:00.000", extra: ({}) },
                { id: "a1", role: "assistant", content: "", createdAt: "2026-07-25T10:00:01.000", extra: ({}) }
            ]
            storeMock.toolCallsReply = [
                { messageId: "a1", callIndex: 0, toolName: "read_file",
                  arguments: ({ path: "/x" }), status: "ok",
                  startedAt: "2026-07-25T10:00:01.100", finishedAt: "2026-07-25T10:00:02.600",
                  resultMessageId: "t1" }
            ]
            ctl.loadConversation("c1")
            compare(ctl.chatModel.count, 2)
            var act = activityOf(1)
            compare(act.length, 1)
            compare(act[0].name, "read_file")
            compare(act[0].status, "done")
            compare(act[0].durationMs, 1500)
            verify(act[0].describe.indexOf("/x") >= 0)
            compare(ctl._messages.length, 1)
            compare(ctl._messages[0].role, "user")
        }
    }
}
