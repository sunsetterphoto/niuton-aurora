import QtQuick
import QtTest
import net.niuton.aurora.engine

// ServiceManager ohne echtes systemctl/Netz: Mock-ProcessRunner (zeichnet
// argv auf, finished/failed von Hand auslösbar) + Mock-Http für die
// Health-Probes.
TestCase {
    name: "ServiceManager"

    // Zuletzt angelegter Mock-Runner (ServiceManager erzeugt pro Aktion einen)
    property var runners: []

    component MockRunner: QtObject {
        property int timeoutMs: 0
        property var started: null   // {program, args}
        signal finished(int exitCode, string stdoutText, string stderrText,
                        bool truncated, bool timedOut)
        signal failed(string message)
        function start(program, args) { started = { "program": program, "args": args } }
        function destroy() {}
    }

    property QtObject mockHttp: QtObject {
        property var calls: []
        property var nextResult: ({ "ok": true })
        function getJson(url, cb, t) { calls.push({ "url": url, "cb": cb }) }
        function answer(i, res) { calls[i].cb(res) }
        function find(urlPart) {
            for (var i = 0; i < calls.length; i++)
                if (calls[i].url.indexOf(urlPart) !== -1) return i
            return -1
        }
    }

    ServiceManager {
        id: svc
        http: mockHttp
        runnerFactory: Component { MockRunner {} }
        pollIntervalMs: 1
        startTimeoutS: 1   // 1s / 1ms → 1000 Poll-Ticks in Tests
    }

    property var actions: []
    function _onAction(id, ok, msg) { actions.push({ "id": id, "ok": ok, "msg": msg }) }

    function init() {
        runners = []
        actions = []
        mockHttp.calls = []
        mockHttp.nextResult = { "ok": true }
        svc.actionFinished.connect(_onAction)
    }

    function cleanup() {
        svc.actionFinished.disconnect(_onAction)
    }

    // Laufende Mock-Runner einsammeln: _runners-Map des ServiceManager
    function _runner(id) { return svc._runners[id] }

    function test_refreshFragtIsActiveUndHealthAb() {
        svc.refresh()
        var r1 = _runner("comfyui")
        var r2 = _runner("speaches")
        verify(r1 && r2)
        compare(r1.started.program, "systemctl")
        compare(r1.started.args.join(" "), "--user is-active comfyui")
        compare(r2.started.args.join(" "), "--user is-active speaches")
        r1.finished(3, "inactive\n", "", false, false)
        r2.finished(0, "active\n", "", false, false)
        compare(svc.stateOf("comfyui"), "inactive")
        compare(svc.stateOf("speaches"), "active")
        compare(mockHttp.find("8188/queue") !== -1 || mockHttp.find("/queue") !== -1, true)
        compare(mockHttp.find("/health") !== -1, true)
        // Health-Antworten → healthy-Flags
        mockHttp.answer(mockHttp.find("/queue"), { "ok": true })
        mockHttp.answer(mockHttp.find("/health"), { "ok": true })
        compare(svc.healthyOf("comfyui"), true)
        compare(svc.healthyOf("speaches"), true)
    }

    function test_startSetztStartingUndMeldetErfolgBeiHealth() {
        compare(svc.start("speaches"), true)
        compare(svc.stateOf("speaches"), "starting")
        var r = _runner("speaches")
        compare(r.started.args.join(" "), "--user start speaches")
        r.finished(0, "", "", false, false)
        // Poll-Timer (1 ms) stößt /health an; sobald ok → active + actionFinished
        tryVerify(function() { return mockHttp.find("/health") !== -1 }, 2000)
        mockHttp.answer(mockHttp.find("/health"), { "ok": true })
        tryVerify(function() { return svc.stateOf("speaches") === "active" }, 2000)
        tryVerify(function() {
            for (var k = 0; k < actions.length; k++)
                if (actions[k].id === "speaches" && actions[k].ok) return true
            return false
        }, 2000)
    }

    function test_startFehlschlagMeldetFehler() {
        svc.start("comfyui")
        var r = _runner("comfyui")
        r.finished(1, "", "Failed to start comfyui.service", false, false)
        compare(svc.stateOf("comfyui"), "failed")
        compare(actions.length, 1)
        compare(actions[0].ok, false)
        verify(actions[0].msg.indexOf("Start fehlgeschlagen") !== -1)
    }

    function test_startBusyWirdAbgewiesen() {
        compare(svc.start("speaches"), true)
        compare(svc.start("speaches"), false)   // Aktion läuft schon
        _runner("speaches").finished(0, "", "", false, false)
    }

    function test_stopSetztInactiveUndLeertHealthy() {
        svc._setState("comfyui", "active")
        svc._setHealthy("comfyui", true)
        compare(svc.stop("comfyui"), true)
        compare(svc.stateOf("comfyui"), "stopping")
        var r = _runner("comfyui")
        compare(r.started.args.join(" "), "--user stop comfyui")
        r.finished(0, "", "", false, false)
        compare(svc.stateOf("comfyui"), "inactive")
        compare(svc.healthyOf("comfyui"), false)
        compare(actions[0].ok, true)
    }

    function test_probeUnitBehältÜbergangszustandBeiActiveMeldung() {
        // Während "starting": ein verspätetes is-active "active" darf den
        // Übergang nicht kapern — erst Health entscheidet.
        svc.start("speaches")
        _runner("speaches").finished(0, "", "", false, false)
        svc._probeUnit("speaches")
        var r = _runner("speaches")
        r.finished(0, "active\n", "", false, false)
        compare(svc.stateOf("speaches"), "starting")
        // inactive/failed hingegen bricht den Übergang ehrlich ab
        svc._probeUnit("speaches")
        _runner("speaches").finished(3, "failed\n", "", false, false)
        compare(svc.stateOf("speaches"), "failed")
    }
}
