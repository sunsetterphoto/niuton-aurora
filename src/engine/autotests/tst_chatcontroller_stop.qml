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
    // FileIO-Mock: readText/standardPath wie der Null-Fall (ok:false / Dummy-Pfad),
    // damit _systemPrompt() unverändert läuft; readBase64 liest aus `files` (Pfad->b64)
    // — steuert den Reload-Regenerate-Disk-Fallback (Task 10, Fix nach Review).
    QtObject { id: fileioMock; property var files: ({})
        property var readCounts: ({})           // Pfad -> Anzahl readText-Aufrufe
        function readBase64(path){ return files[path] !== undefined
            ? ({ "ok": true, "data": files[path], "mime": "image/png", "error": "" })
            : ({ "ok": false, "data": "", "mime": "", "error": "nicht gefunden" }) }
        function readText(path, max){ readCounts[path] = (readCounts[path] || 0) + 1
            return ({ "ok": false, "text": "", "error": "" }) }
        function standardPath(kind){ return "/h/.local/share/aurora" } }

    // echte 5b-Logikbausteine injizieren (sonst wirft der guardlose _decide null.decide)
    PermissionResolver { id: realResolver }
    GrantStore { id: realGrants }

    property var lastJob: null
    property var lastReq: null
    ChatController { id: ctl; store: storeMock; settings: settingsMock; registry: registryMock
        resolver: realResolver; grants: realGrants; fileio: fileioMock
        activeModel: "m"; activeCaps: ["tools"]; homeDir: "/h"
        chatFn: function(req){ lastReq = req; var j = jobComp.createObject(ctl); lastJob = j; return j } }
    function call(n,a){ return { "function": { "name": n, "arguments": a||{} } } }

    TestCase {
        name: "ChatControllerStop"
        function init(){ ctl.chatModel.clear(); storeMock.appended=[]; storeMock.deleted=[]
                         storeMock.rows=[]; storeMock._n=0; ctl.conversationId="c1"; ctl._messages=[]
                         registryMock.execLog=[]; registryMock.abortCalled=false; registryMock.perm={}
                         realGrants.clearConversation("c1")
                         fileioMock.files=({}); fileioMock.readCounts=({})
                         ctl.state="idle"; ctl._activeJob=null; lastReq=null }

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

        // regenerate() darf den Bild-Kontext des letzten User-Zuges nicht verwerfen
        // (Audit ChatController.qml:616/Task 10, Fix B) — sonst wird aus einer
        // Vision-Antwort eine unpassende Text-Antwort.
        function test_regenerateKeepsImageContext() {
            ctl.send("Bildfrage", { images: ["b64daten"], imagePath: "/tmp/bild.png", displayText: "Bildfrage  📎 bild.png" })
            lastJob.done({ content:"Antwort", thinking:"", toolCalls:[] })
            ctl.regenerate()
            // Neuer Request an chatFn enthält wieder das Bild in der letzten user-Nachricht.
            verify(lastReq !== null)
            var msgs = lastReq.messages
            var lastUserMsg = null
            for (var i = msgs.length - 1; i >= 0; i--) {
                if (msgs[i].role === "user") { lastUserMsg = msgs[i]; break }
            }
            verify(lastUserMsg !== null)
            verify(lastUserMsg.images !== undefined)
            compare(lastUserMsg.images[0], "b64daten")
            // ListModel-Zeile zeigt den Bildpfad wieder an (Bubble-Anzeige).
            compare(ctl.chatModel.get(0).mediaPath, "/tmp/bild.png")
            compare(ctl.chatModel.get(0).text, "Bildfrage  📎 bild.png")
        }

        // Nach Reload trägt _messages KEINE base64-images (nicht persistiert), nur der
        // mediaPath ist aus der DB da. regenerate() muss die Bytes von der Platte
        // nachladen, damit der Request das Bild wieder trägt (Task 10, Fix nach Review).
        function test_regenerateReloadReadsImageFromDisk() {
            fileioMock.files = { "/tmp/bild.png": "b64vonplatte" }
            storeMock.rows = [
                { id:"r1", role:"user", content:"Bildfrage", status:"final", createdAt:0, thinking:"", mediaPath:"/tmp/bild.png" },
                { id:"r2", role:"assistant", content:"Antwort", status:"final", createdAt:0, thinking:"" }
            ]
            ctl.loadConversation("c9")
            verify(ctl._messages[0].images === undefined)     // Reload verliert die base64-Bytes
            ctl.regenerate()
            var msgs = lastReq.messages
            var lastUserMsg = null
            for (var i = msgs.length - 1; i >= 0; i--)
                if (msgs[i].role === "user") { lastUserMsg = msgs[i]; break }
            verify(lastUserMsg !== null)
            verify(lastUserMsg.images !== undefined)          // Bytes von der Platte im Request
            compare(lastUserMsg.images[0], "b64vonplatte")
            compare(ctl.chatModel.get(0).mediaPath, "/tmp/bild.png")   // Thumbnail bleibt (Bytes da)
        }

        // Datei nach Reload verschwunden: readBase64 schlägt fehl -> ehrlich Text-only,
        // KEINE irreführende Bild-Bubble (kein imagePath), Zug läuft trotzdem.
        function test_regenerateReloadFileGoneNoMisleadingThumbnail() {
            fileioMock.files = ({})                            // Datei nicht auffindbar
            storeMock.rows = [
                { id:"r1", role:"user", content:"Bildfrage", status:"final", createdAt:0, thinking:"", mediaPath:"/tmp/weg.png" },
                { id:"r2", role:"assistant", content:"Antwort", status:"final", createdAt:0, thinking:"" }
            ]
            ctl.loadConversation("c9")
            ctl.regenerate()
            var msgs = lastReq.messages
            var lastUserMsg = null
            for (var i = msgs.length - 1; i >= 0; i--)
                if (msgs[i].role === "user") { lastUserMsg = msgs[i]; break }
            verify(lastUserMsg !== null)
            verify(lastUserMsg.images === undefined)           // kein Bild im Request
            compare(ctl.chatModel.get(0).mediaPath, "")        // KEINE irreführende Bild-Bubble
            verify(ctl.busy)                                   // Text-only-Zug lief trotzdem
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

        // Audit-Fix (Klein/ux): persistierte assistant-Zwischenzeilen eines
        // Tool-Zuges (tool_calls, leerer content) duerfen nach dem Reload NICHT
        // als leere Ghost-Bubbles erscheinen — bewusste Ausblend-Variante aus dem
        // Audit (toolActivity-Persistenz bleibt Backlog): weder Bubble noch
        // _messages-Eintrag. Eine assistant-Zeile MIT mediaPath (Bild) bleibt.
        function test_loadConversationSkipptLeereAssistantZwischenzeilen() {
            storeMock.rows = [
                { id:"r1", role:"user", content:"Frage", status:"final", createdAt:0, thinking:"" },
                { id:"r2", role:"assistant", content:"", status:"final", createdAt:0, thinking:"" },   // Ghost (tool_calls)
                { id:"r3", role:"assistant", content:"Antwort", status:"final", createdAt:0, thinking:"" },
                { id:"r4", role:"assistant", content:"", status:"final", createdAt:0, thinking:"", mediaPath:"/tmp/img.png" }
            ]
            ctl.loadConversation("c9")
            compare(ctl.chatModel.count, 3)                 // user + Antwort + Bild, kein Ghost
            compare(ctl._messages.length, 3)
            compare(ctl.chatModel.get(1).text, "Antwort")
            compare(ctl.chatModel.get(2).mediaPath, "/tmp/img.png")
            for (var i = 0; i < ctl._messages.length; i++)
                verify(ctl._messages[i]._msgId !== "r2")    // Ghost auch nicht im Kontext
        }

        // Audit-Fix (Klein/perf): _systemPrompt() las bisher bei JEDEM
        // _buildMessages() /etc/hostname, /etc/os-release, /proc/meminfo UND
        // memory.md synchron auf dem GUI-Thread (5-Runden-Tool-Zug ≈ 24 Reads).
        // Der statische Teil (hostname/os/ram) aendert sich zur Laufzeit nicht
        // -> einmalig; memory.md ist nutzer-editierbar -> pro ZUG einmal frisch.
        function test_systemPromptLiestStatischEinmalUndMemoryProZug() {
            ctl._sysStatic = null; ctl._memoryCache = null
            // Zug 1 MIT Tool-Runde: _systemPrompt laeuft 3x (_maybeCompact + 2 Streams)
            ctl.send("Erste", null)
            lastJob.done({ content:"", thinking:"", toolCalls:[ call("read_file", { path:"/x" }) ] })
            lastJob.done({ content:"ok", thinking:"", toolCalls:[] })
            compare(ctl.state, "idle")
            compare(fileioMock.readCounts["/etc/hostname"] || 0, 1)
            compare(fileioMock.readCounts["/h/.local/share/aurora/memory.md"] || 0, 1)
            // Zug 2: statisch weiter aus dem Cache, memory.md pro Zug frisch
            ctl.send("Zweite", null)
            lastJob.done({ content:"ok", thinking:"", toolCalls:[] })
            compare(ctl.state, "idle")
            compare(fileioMock.readCounts["/etc/hostname"] || 0, 1)
            compare(fileioMock.readCounts["/h/.local/share/aurora/memory.md"] || 0, 2)
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
