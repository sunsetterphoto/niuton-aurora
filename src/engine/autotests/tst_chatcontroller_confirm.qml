import QtQuick
import QtTest
import net.niuton.aurora.engine

Item {
    Component { id: jobComp; QtObject {
        signal token(string t); signal thinking(string t); signal toolCalls(var calls)
        signal done(var result); signal error(string message)
        property bool aborted: false; function abort(){ aborted = true }
    } }
    QtObject { id: storeMock; property var appended: []; property int _n: 0
        function newUuid(){ _n++; return "u"+_n } function appendMessage(m){ appended.push(m) }
        function updateMessage(i,f){} function deleteMessage(i){} function touchConversation(i,t){}
        function messages(c){ return [] } function appendToolCall(t){} function updateToolCall(i,f){} }
    QtObject { id: settingsMock; property int toolMaxRounds: 5; property string comfyDefaultModel: "z"
        function paramsFor(name) { return ({}) } }
    QtObject { id: registryMock
        property var perm: ({}); property var cat: ({}); property var execLog: []
        function definitions(c){ return [] } function promptSection(c){ return "" }
        function permissionFor(n){ return perm[n] || "auto" } function categoryOf(n){ return cat[n] || "local" }
        function describe(n,a){ return n + ":" + JSON.stringify(a) }
        function execute(n,a,c,done){ execLog.push(n); done("RES:"+n, { status:"ok" }) } function abortRunning(){} }

    // echte 5b-Logikbausteine
    PermissionResolver { id: realResolver }
    GrantStore { id: realGrants }

    property var lastJob: null
    ChatController { id: ctl; store: storeMock; settings: settingsMock; registry: registryMock
        resolver: realResolver; grants: realGrants
        activeModel: "m"; activeCaps: ["tools"]; homeDir: "/h"
        chatFn: function(req){ var j = jobComp.createObject(ctl); lastJob = j; return j } }
    // Audit-Fix (null-safety): Controller OHNE injizierten Resolver — _decide
    // darf nicht werfen (State klemmte sonst in toolRunning).
    property var lastJob2: null
    ChatController { id: ctlOhneResolver; store: storeMock; settings: settingsMock; registry: registryMock
        grants: realGrants
        activeModel: "m"; activeCaps: ["tools"]; homeDir: "/h"
        chatFn: function(req){ var j = jobComp.createObject(ctlOhneResolver); lastJob2 = j; return j } }
    function call(n,a){ return { "function": { "name": n, "arguments": a || {} } } }

    TestCase {
        name: "ChatControllerConfirm"
        function init(){ ctl.chatModel.clear(); storeMock.appended = []; storeMock._n = 0
                         ctl.conversationId = "c1"; ctl._messages = []; registryMock.perm = {}
                         registryMock.cat = {}; registryMock.execLog = []; realGrants.clearConversation("c1")
                         ctl.state = "idle"; ctl._activeJob = null
                         ctlOhneResolver.chatModel.clear(); ctlOhneResolver._messages = []
                         ctlOhneResolver.conversationId = "c1"
                         ctlOhneResolver.state = "idle"; ctlOhneResolver._activeJob = null; lastJob2 = null }

        function test_confirmToolWaitsThenRunsOnYes() {
            registryMock.perm = { "run_command": "confirm" }
            ctl.send("Befehl", null)
            lastJob.done({ content:"", thinking:"", toolCalls:[ call("run_command", { command:"ls" }) ] })
            compare(ctl.state, "toolPending")               // wartet auf Bestätigung
            compare(registryMock.execLog.length, 0)
            ctl.confirmOnce()
            compare(registryMock.execLog.length, 1)         // jetzt ausgeführt
            lastJob.done({ content:"ok", thinking:"", toolCalls:[] })
            compare(ctl.state, "idle")
        }

        function test_rejectFeedsDeniedAndContinues() {
            registryMock.perm = { "run_command": "confirm" }
            ctl.send("Befehl", null)
            lastJob.done({ content:"", thinking:"", toolCalls:[ call("run_command", { command:"rm x" }) ] })
            compare(ctl.state, "toolPending")
            ctl.reject()
            compare(registryMock.execLog.length, 0)         // nicht ausgeführt
            // denied-Result gespeist, Schleife läuft weiter
            lastJob.done({ content:"ok", thinking:"", toolCalls:[] })
            compare(ctl.state, "idle")
        }

        function test_grantForChatSkipsSecondConfirm() {
            registryMock.perm = { "run_command": "confirm" }
            ctl.send("Erst", null)
            lastJob.done({ content:"", thinking:"", toolCalls:[ call("run_command", { command:"a" }) ] })
            ctl.confirmForConversation()
            compare(registryMock.execLog.length, 1)
            lastJob.done({ content:"", thinking:"", toolCalls:[ call("run_command", { command:"b" }) ] })
            // Grant vorhanden -> KEIN erneutes toolPending, direkt ausgeführt
            compare(ctl.state !== "toolPending", true)
            compare(registryMock.execLog.length, 2)
            lastJob.done({ content:"ok", thinking:"", toolCalls:[] })
        }

        function test_categorySwitchEscalatesDespiteAuto() {
            registryMock.perm = { "web_search": "auto", "read_file": "auto" }
            registryMock.cat = { "web_search": "network", "read_file": "local" }
            ctl.send("Erst web, dann datei", null)
            // Runde 1: web_search (auto, network) -> läuft ohne Bestätigung
            lastJob.done({ content:"", thinking:"", toolCalls:[ call("web_search", { query:"x" }) ] })
            compare(registryMock.execLog.length, 1)
            // Runde 2: read_file (auto, local) NACH network -> Eskalation erzwingt Bestätigung
            lastJob.done({ content:"", thinking:"", toolCalls:[ call("read_file", { path:"/x" }) ] })
            compare(ctl.state, "toolPending")               // eskaliert trotz auto
            ctl.confirmOnce()
            compare(registryMock.execLog.length, 2)
            lastJob.done({ content:"ok", thinking:"", toolCalls:[] })
        }

        // Audit-Fix (Klein/ux): ein ABGELEHNTES Tool lief nie — es darf die
        // Kategorie-Policy nicht fuettern (noteResult nur fuer tatsaechlich
        // ausgefuehrte Tools). Sonst eskaliert das naechste Tool der anderen
        // Kategorie grundlos auf confirm.
        function test_abgelehntesToolEskaliertKeinenKategorieWechsel() {
            registryMock.perm = { "web_search": "confirm", "read_file": "auto" }
            registryMock.cat = { "web_search": "network", "read_file": "local" }
            ctl.send("erst web (abgelehnt), dann datei", null)
            lastJob.done({ content:"", thinking:"", toolCalls:[ call("web_search", { query:"x" }) ] })
            compare(ctl.state, "toolPending")
            ctl.reject()
            compare(registryMock.execLog.length, 0)         // web_search lief NIE
            // read_file (auto, local) muss jetzt DIREKT laufen — kein
            // Kategorie-Wechsel-Confirm durch das verworfene network-Tool.
            lastJob.done({ content:"", thinking:"", toolCalls:[ call("read_file", { path:"/x" }) ] })
            compare(ctl.state !== "toolPending", true)
            compare(registryMock.execLog.length, 1)
            compare(registryMock.execLog[0], "read_file")
            lastJob.done({ content:"ok", thinking:"", toolCalls:[] })
            compare(ctl.state, "idle")
        }

        // Audit-Fix (Klein/null-safety): _decide ohne injizierten Resolver darf
        // nicht werfen (Throw im Handler -> State klemmt in toolRunning).
        // Definiertes Verhalten: konservativ "confirm" — ohne Resolver laeuft
        // kein Tool (auch kein auto-Tool) still durch.
        function test_decideOhneResolverFragtKonservativNach() {
            registryMock.perm = { "read_file": "auto" }
            ctlOhneResolver.send("lies", null)
            lastJob2.done({ content:"", thinking:"", toolCalls:[ call("read_file", { path:"/x" }) ] })
            compare(ctlOhneResolver.state, "toolPending")   // kein Throw, kein Klemmen
            compare(registryMock.execLog.length, 0)
            ctlOhneResolver.confirmOnce()                   // Nutzer bestaetigt -> normal weiter
            compare(registryMock.execLog.length, 1)
            lastJob2.done({ content:"ok", thinking:"", toolCalls:[] })
            compare(ctlOhneResolver.state, "idle")
        }
    }
}
