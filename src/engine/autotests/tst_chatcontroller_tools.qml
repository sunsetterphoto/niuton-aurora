import QtQuick
import QtTest
import net.niuton.aurora.engine

Item {
    Component { id: jobComp; QtObject {
        signal token(string t); signal thinking(string t); signal toolCalls(var calls)
        signal done(var result); signal error(string message)
        property bool aborted: false; function abort() { aborted = true }
    } }
    QtObject { id: storeMock
        property var appended: []; property var toolCalls: []; property int _n: 0
        function newUuid() { _n++; return "u" + _n }
        function appendMessage(m) { appended.push(m) }
        function updateMessage(i,f){} function deleteMessage(i){} function touchConversation(i,t){}
        function messages(c){ return [] } function appendToolCall(tc){ toolCalls.push(tc) } function updateToolCall(i,f){}
    }
    QtObject { id: settingsMock; property int toolMaxRounds: 3; property string comfyDefaultModel: "z"
        function paramsFor(name) { return ({}) } }
    // Registry-Mock: konfigurierbare Permission + execute-Ergebnis + Kategorie
    QtObject { id: registryMock
        property var perm: ({})            // name -> "auto"|"confirm"|"off"
        property var cat: ({})             // name -> "local"|"network"|"generate"
        property var execLog: []
        function definitions(ctx){ return [] }
        property string promptOut: "## Your Tools\nX"
        function promptSection(ctx){ return promptOut }
        function permissionFor(n){ return perm[n] || "auto" }
        function categoryOf(n){ return cat[n] || "local" }
        function describe(n,a){ return n }
        function execute(n,a,ctx,done){ execLog.push(n); done("RESULT:" + n, { status: "ok" }) }
        function abortRunning(){}
    }

    // echte 5b-Logikbausteine injizieren (guardloser _decide ab Task 4 braucht resolver)
    PermissionResolver { id: realResolver }
    GrantStore { id: realGrants }

    property var lastJob: null
    property var reqLog: []
    ChatController {
        id: ctl; store: storeMock; settings: settingsMock; registry: registryMock
        resolver: realResolver; grants: realGrants
        activeModel: "m"; activeCaps: ["tools"]; homeDir: "/h"
        chatFn: function(req) { reqLog.push(req); var j = jobComp.createObject(ctl); lastJob = j; return j }
    }

    function call(name, args) { return { "function": { "name": name, "arguments": args || {} } } }

    TestCase {
        name: "ChatControllerTools"
        function init() { ctl.chatModel.clear(); storeMock.appended = []; storeMock.toolCalls = []
                          storeMock._n = 0; ctl.conversationId = ""; ctl._messages = []; reqLog = []
                          settingsMock.toolMaxRounds = 3
                          registryMock.perm = {}; registryMock.cat = {}; registryMock.execLog = []
                          ctl.state = "idle"; ctl._activeJob = null; ctl.activeCaps = ["tools"] }

        function test_singleAutoToolThenAnswer() {
            ctl.send("Lies Datei", null)
            // Runde 1: Modell ruft read_file
            lastJob.done({ content: "", thinking: "", toolCalls: [ call("read_file", { path: "/x" }) ] })
            // read_file (auto) wurde ausgeführt, Ergebnis in Kontext, Folge-Request gestartet
            compare(registryMock.execLog.length, 1)
            compare(registryMock.execLog[0], "read_file")
            verify(ctl.state === "streaming" || ctl.state === "toolRunning")
            // Runde 2: finale Antwort
            lastJob.token("Der Inhalt ist X")
            lastJob.done({ content: "Der Inhalt ist X", thinking: "", toolCalls: [] })
            compare(ctl.state, "idle")
        }

        function test_sequentialOrderPreserved() {
            ctl.send("Zwei Tools", null)
            lastJob.done({ content: "", thinking: "",
                toolCalls: [ call("read_file", { path: "/a" }), call("list_directory", { path: "/b" }) ] })
            compare(registryMock.execLog.length, 2)
            compare(registryMock.execLog[0], "read_file")     // call_index-Reihenfolge
            compare(registryMock.execLog[1], "list_directory")
        }

        function test_roundLimitForcesTextClose() {
            settingsMock.toolMaxRounds = 2
            ctl.send("Endlos-Tools", null)
            lastJob.done({ content: "", thinking: "", toolCalls: [ call("read_file", { path: "/1" }) ] })  // Runde 1
            lastJob.done({ content: "", thinking: "", toolCalls: [ call("read_file", { path: "/2" }) ] })  // Runde 2 = Limit
            lastJob.done({ content: "Fertig", thinking: "", toolCalls: [] })                                // Abschluss
            compare(ctl.state, "idle")
            verify(registryMock.execLog.length >= 2)
            // Kern-Invariante §5: der Folge-Request NACH dem Limit trägt keine tools mehr.
            // (reqLog[0]/[1] = tool-tragende Runden mit req.tools; reqLog[2] = Folge-Request ohne)
            compare(reqLog.length, 3)
            verify(reqLog[0].tools !== undefined)
            verify(reqLog[2].tools === undefined)
        }

        function test_loopGuardReturnsCachedResult() {
            ctl.send("Gleicher Call zweimal", null)
            lastJob.done({ content: "", thinking: "", toolCalls: [ call("read_file", { path: "/same" }) ] })
            lastJob.done({ content: "", thinking: "", toolCalls: [ call("read_file", { path: "/same" }) ] })
            // identischer Call -> zweites Mal aus Cache, execute nur EINMAL
            compare(registryMock.execLog.length, 1)
            lastJob.done({ content: "ok", thinking: "", toolCalls: [] })
            compare(ctl.state, "idle")
        }

        function test_disabledToolFeedsResultNotExecute() {
            registryMock.perm = { "run_command": "off" }
            ctl.send("Verbotenes Tool", null)
            lastJob.done({ content: "", thinking: "", toolCalls: [ call("run_command", { command: "rm -rf /" }) ] })
            compare(registryMock.execLog.length, 0)           // nicht ausgeführt
            // Ergebnis "deaktiviert" in den Kontext gespeist -> Folge-Request läuft
            lastJob.done({ content: "ok", thinking: "", toolCalls: [] })
            compare(ctl.state, "idle")
        }

        function test_toolSectionGatedByCapability() {
            // ctl.activeCaps == ["tools"] (init()) -> Tool-Sektion muss im System-Prompt landen
            ctl.send("Erster Zug", null)
            verify(reqLog[0].messages[0].content.indexOf(registryMock.promptOut) !== -1)
            lastJob.done({ content: "ok", thinking: "", toolCalls: [] })
            compare(ctl.state, "idle")

            // Ohne tools-Capability darf die Tool-Sektion NICHT mehr auftauchen
            // (Spec §3.2/§8: gegen Tool-Halluzinationen bei Modellen ohne Tool-Support).
            ctl.activeCaps = []
            ctl.send("Zweiter Zug", null)
            verify(reqLog[1].messages[0].content.indexOf(registryMock.promptOut) === -1)
            lastJob.done({ content: "ok", thinking: "", toolCalls: [] })
            compare(ctl.state, "idle")
        }

        // Hartes Rundenlimit (Audit ChatController.qml:390): der Cap steuerte bisher
        // nur, ob Tools ANGEBOTEN werden (req.tools) — nicht, ob die Schleife weiter-
        // läuft. Liefert das Backend TROTZDEM tool_calls in der tools-losen Folge-
        // Antwort (Runde nach dem Limit), muss das ignoriert werden: keine weitere
        // Ausführung, kein zweiter „Rundenlimit"-Hinweis, State landet in idle.
        function test_hardRoundCeiling_ignoresToolCallsAfterCap() {
            settingsMock.toolMaxRounds = 2
            ctl.send("Backend hält sich nicht an das Limit", null)
            // Runde 1
            lastJob.done({ content: "", thinking: "", toolCalls: [ call("read_file", { path: "/1" }) ] })
            // Runde 2 = Limit erreicht -> _afterRound hängt die Rundenlimit-Notiz an
            // und startet die Folge-Anfrage OHNE tools (reqLog[2].tools === undefined)
            lastJob.done({ content: "", thinking: "", toolCalls: [ call("read_file", { path: "/2" }) ] })
            // Das Backend ignoriert das fehlende tools-Feld und liefert TROTZDEM
            // weiter tool_calls auf die tools-lose Folge-Anfrage.
            lastJob.done({ content: "", thinking: "", toolCalls: [ call("read_file", { path: "/3" }) ] })

            // Cap: genau 2 Tool-Ausführungen (eine je Runde bis zum Limit) — NICHT 3.
            compare(registryMock.execLog.length, 2)
            // _round darf den Cap nicht überschreiten.
            verify(ctl._round <= settingsMock.toolMaxRounds)
            // State darf nicht in toolRunning/streaming klemmen bleiben.
            compare(ctl.state, "idle")
            // Rundenlimit-Notiz höchstens einmal im Kontext (nicht pro ignoriertem Versuch).
            var noticeCount = 0
            for (var i = 0; i < ctl._messages.length; i++) {
                if (ctl._messages[i].content && ctl._messages[i].content.indexOf("Rundenlimit erreicht") !== -1)
                    noticeCount++
            }
            compare(noticeCount, 1)
        }

        function test_turnIdPersistedPerTurn() {
            ctl.send("Erster Zug", null)
            lastJob.done({ content: "Antwort 1", thinking: "", toolCalls: [] })
            compare(ctl.state, "idle")
            compare(storeMock.appended.length, 2)              // user + assistant
            var turn1 = storeMock.appended[0].turnId
            verify(turn1 !== undefined && turn1 !== "")
            compare(storeMock.appended[1].turnId, turn1)       // gleicher Zug -> gleiche turnId

            ctl.send("Zweiter Zug", null)
            lastJob.done({ content: "Antwort 2", thinking: "", toolCalls: [] })
            compare(ctl.state, "idle")
            compare(storeMock.appended.length, 4)
            var turn2 = storeMock.appended[2].turnId
            verify(turn2 !== undefined && turn2 !== "")
            compare(storeMock.appended[3].turnId, turn2)
            verify(turn2 !== turn1)                            // neuer Zug -> neue turnId
        }
    }
}
