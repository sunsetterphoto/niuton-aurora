import QtQuick
import QtTest
import net.niuton.aurora.engine

Item {
    // Mock-ProcessRunner: start() merkt sich Argumente; Test triggert finished/failed
    Component {
        id: procComp
        QtObject {
            property int timeoutMs: 0
            property bool mergeStderr: false      // Tools setzen dies auf true
            property bool started: false
            property bool terminated: false
            property string prog: ""
            property var args: []
            signal finished(int code, string out, string err, bool trunc, bool timedOut)
            signal failed(string message)
            function start(p, a) { started = true; prog = p; args = a }
            function terminate() { terminated = true }
            function kill() { terminated = true }
        }
    }

    function makeCtx(cfg) {
        var lastProc = null
        var ctx = {
            lastProc: null,
            settings: { searchEndpoint: (cfg && cfg.endpoint !== undefined) ? cfg.endpoint : "http://127.0.0.1:8888" },
            http: {
                lastUrl: "",
                getJson: function(url, cb) {
                    ctx.http.lastUrl = url
                    if (cfg && cfg.httpResult) cb(cfg.httpResult)
                    else cb({ ok: true, data: { results: [] } })
                }
            },
            newProcess: function() {
                ctx.lastProc = procComp.createObject(null)
                return ctx.lastProc
            }
        }
        return ctx
    }

    WebSearchTool { id: searchTool }
    WebFetchTool { id: fetchTool }
    RunCommandTool { id: runTool }

    TestCase {
        name: "NetProcTools"

        function test_metadata() {
            compare(searchTool.name, "web_search")
            compare(searchTool.category, "network")
            compare(fetchTool.name, "web_fetch")
            compare(fetchTool.category, "network")
            compare(runTool.name, "run_command")
            compare(runTool.category, "local")
            compare(runTool.minPermission, "confirm")
        }

        function test_searchUsesConfiguredEndpoint() {
            var ctx = makeCtx({ endpoint: "http://10.0.0.2:9999",
                                httpResult: { ok: true, data: { results: [
                                    { title: "T1", body: "B1", href: "http://x/1" } ] } } })
            var out = null
            searchTool.execute({ query: "wetter berlin" }, ctx, function(t) { out = t })
            verify(ctx.http.lastUrl.indexOf("http://10.0.0.2:9999/search/text") === 0)
            verify(ctx.http.lastUrl.indexOf("query=wetter%20berlin") >= 0)
            verify(out.indexOf("T1") >= 0)
            verify(out.indexOf("http://x/1") >= 0)
        }

        function test_searchEmptyEndpointFallsBack() {
            var ctx = makeCtx({ endpoint: "" })
            searchTool.execute({ query: "x" }, ctx, function(t) {})
            verify(ctx.http.lastUrl.indexOf("http://127.0.0.1:8888") === 0)
        }

        function test_searchUnavailable() {
            var ctx = makeCtx({ httpResult: { ok: false, error: "conn refused" } })
            var out = null
            searchTool.execute({ query: "x" }, ctx, function(t) { out = t })
            verify(out.indexOf("nicht verfügbar") >= 0)
        }

        function test_fetchRunsCurlAndReturnsOutput() {
            var ctx = makeCtx()
            var out = null
            fetchTool.execute({ url: "http://example.com" }, ctx, function(t) { out = t })
            compare(ctx.lastProc.prog, "curl")
            verify(ctx.lastProc.args.indexOf("http://example.com") >= 0)
            compare(ctx.lastProc.started, true)
            // Prozess liefert Ergebnis
            ctx.lastProc.finished(0, "<html>hi</html>", "", false, false)
            verify(out.indexOf("<html>hi</html>") >= 0)
        }

        function test_runCommandExecutesBash() {
            var ctx = makeCtx()
            var out = null
            runTool.execute({ command: "echo hallo" }, ctx, function(t) { out = t })
            compare(ctx.lastProc.prog, "bash")
            compare(ctx.lastProc.args[0], "-c")
            compare(ctx.lastProc.args[1], "echo hallo")
            ctx.lastProc.finished(0, "hallo\n", "", false, false)
            verify(out.indexOf("hallo") >= 0)
        }

        function test_processFailure() {
            var ctx = makeCtx()
            var out = null, ex = null
            runTool.execute({ command: "nope" }, ctx, function(t, extra) { out = t; ex = extra })
            ctx.lastProc.failed("FailedToStart")
            verify(out.indexOf("Fehler") >= 0)
            compare(ex.status, "error")
        }

        function test_runCommandEmptyOutput() {          // Parität: "(Keine Ausgabe)"
            var ctx = makeCtx()
            var out = null
            runTool.execute({ command: "mkdir /tmp/x" }, ctx, function(t) { out = t })
            compare(ctx.lastProc.mergeStderr, true)
            ctx.lastProc.finished(0, "", "", false, false)
            compare(out, "(Keine Ausgabe)")
        }

        function test_runCommandTimeoutMarker() {         // Parität: Timeout-Marker
            var ctx = makeCtx()
            var out = null, ex = null
            runTool.execute({ command: "sleep 99" }, ctx, function(t, extra) { out = t; ex = extra })
            ctx.lastProc.finished(-1, "partial", "", false, true)
            verify(out.indexOf("partial") >= 0)
            verify(out.indexOf("abgebrochen: Zeitüberschreitung") >= 0)
            compare(ex.status, "error")
        }

        function test_fetchEmptyOutput() {
            var ctx = makeCtx()
            var out = null
            fetchTool.execute({ url: "http://x" }, ctx, function(t) { out = t })
            compare(ctx.lastProc.mergeStderr, true)
            ctx.lastProc.finished(0, "", "", false, false)
            compare(out, "(Keine Ausgabe)")
        }

        function test_fetchCurlErrorIsErrorStatus() {     // curl-Exit != 0 -> status "error"
            var ctx = makeCtx()
            var out = null, ex = null
            fetchTool.execute({ url: "http://nope.invalid" }, ctx, function(t, extra) { out = t; ex = extra })
            ctx.lastProc.finished(6, "", "", false, false)   // DNS-Fehler
            compare(ex.status, "error")
        }

        function test_abortTerminatesProcess() {
            var ctx = makeCtx()
            runTool.execute({ command: "sleep 100" }, ctx, function(t) {})
            runTool.abort()
            compare(ctx.lastProc.terminated, true)
        }

        function test_describe() {
            compare(searchTool.describe({ query: "q" }), "Web-Suche: q")
            compare(fetchTool.describe({ url: "http://u" }), "URL abrufen: http://u")
            compare(runTool.describe({ command: "ls" }).indexOf("Befehl ausführen"), 0)
        }
    }
}
