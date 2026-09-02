import QtQml
import net.niuton.aurora.core as Core

// Verwaltet die lokalen Dienste (rootless Podman-Quadlets als systemd-User-
// Units): Status abfragen (systemctl --user is-active), starten/stoppen,
// Gesundheit probt (HTTP). Host-neutral; Primitive injizierbar (Tests:
// Mock-Runner/Http, kein echtes systemctl/Netz).
//
// Bewusst KEIN Autostart der Units (dGPU-Power-Policy, siehe Quadlet-
// Kommentare): gestartet wird manuell hierüber oder per servicesAutoStart.
QtObject {
    id: svc

    property var http: Core.Http
    property Component runnerFactory: Component { Core.ProcessRunner {} }

    // Nach-Start-Polling: Intervall und max. Wartezeit (Tests setzen Werte <5)
    property int pollIntervalMs: 2000
    property int startTimeoutS: 300

    // AuroraSettings (Pflicht): die Endpunkte sind KONFIGURIERT, nicht fest
    // verdrahtet. Vorher standen sie hier doppelt — einmal hier, einmal in den
    // Settings, die an die Clients gingen; eine abweichende Einstellung lief
    // an diesem Manager vorbei.
    property var settings: null

    // Abgeleitet: ein Dienst existiert nur mit Endpunkt. "manageable" trennt
    // die lokale Instanz (systemd-Unit, start/stop) von einer entfernten, die
    // auf einem anderen Rechner läuft — dort gibt es keine Unit zu schalten,
    // nur den Gesundheitszustand zu zeigen.
    readonly property var services: {
        var out = []
        if (!settings)
            return out
        // Beide Endpunkte sind eigene Einträge. Der lokale ist ein VOREIN-
        // GESTELLTER Wert — dass er gesetzt ist, heißt nicht, dass dort etwas
        // läuft. Die entfernte Instanz deshalb zu verschweigen (und nie zu
        // proben) würde genau den häufigen Fall verdecken: ComfyUI läuft auf
        // einem anderen Rechner, hier gibt es gar keine.
        var comfyLocal = settings.comfyEndpointLocal || ""
        var comfyRemote = settings.comfyEndpoint || ""
        if (comfyLocal !== "")
            out.push({ "id": "comfyui", "label": "ComfyUI (lokal)",
                       "endpoint": comfyLocal, "healthPath": "/queue",
                       "manageable": _isLocal(comfyLocal) })
        if (comfyRemote !== "" && comfyRemote !== comfyLocal)
            // Nie verwaltbar: die zugehörige Unit läuft auf dem anderen
            // Rechner. Hier zählt nur, ob sie erreichbar ist.
            out.push({ "id": "comfyui-remote", "label": "ComfyUI (anderer Rechner)",
                       "endpoint": comfyRemote, "healthPath": "/queue",
                       "manageable": false })
        var sp = settings.speachesEndpoint || ""
        if (sp !== "")
            out.push({ "id": "speaches", "label": "Speaches (Sprache ein/aus)",
                       "endpoint": sp, "healthPath": "/health",
                       "manageable": _isLocal(sp) })
        return out
    }

    // Verwaltbar ist, was auf dieser Maschine lauscht — nur dort kann eine
    // User-Unit existieren.
    function _isLocal(url) {
        return url.indexOf("//127.0.0.1") !== -1
            || url.indexOf("//localhost") !== -1
            || url.indexOf("//[::1]") !== -1
    }

    // Zustand je Dienst: "unknown" | "inactive" | "failed" | "starting" |
    // "stopping" | "active" (active = Unit aktiv; gesund = healthy[id])
    property var states: ({})
    property var healthy: ({})

    signal actionFinished(string serviceId, bool ok, string message)

    property var _runners: ({})   // id -> laufender ProcessRunner (Aktions-Sperre)
    property var _polls: ({})     // id -> verbleibende Poll-Ticks nach Start

    // Entfernte Dienste haben keinen Unit-Zustand — "remote" statt einer
    // Unit-Aussage, die es hier nicht gibt.
    function stateOf(id) {
        if (!manageableOf(id)) return "remote"
        return states[id] || "unknown"
    }
    function manageableOf(id) {
        var s = serviceById(id)
        return s ? s.manageable === true : false
    }
    function healthyOf(id) { return !!healthy[id] }
    function busyOf(id) { return _runners[id] !== undefined }

    function serviceById(id) {
        for (var i = 0; i < services.length; i++)
            if (services[i].id === id) return services[i]
        return null
    }

    // Status aller Dienste neu abfragen (Unit-Status + Gesundheit)
    function refresh() {
        for (var i = 0; i < services.length; i++) {
            _probeUnit(services[i].id)
            _probeHealth(services[i])
        }
    }

    function start(id) {
        if (busyOf(id) || !manageableOf(id)) return false
        _setState(id, "starting")
        _polls = _bump(_polls, id, Math.max(1, Math.round(startTimeoutS * 1000 / pollIntervalMs)))
        _run(id, ["start", id], function(code, out, err, timedOut) {
            if (code !== 0) {
                svc._polls = _bump(svc._polls, id, 0)
                _setState(id, "failed")
                actionFinished(id, false, _startFehlerText(err || out || "Exit " + code))
                return
            }
            pollTimer.start()
        })
        return true
    }

    function stop(id) {
        if (busyOf(id) || !manageableOf(id)) return false
        _setState(id, "stopping")
        _polls = _bump(_polls, id, 0)
        _run(id, ["stop", id], function(code, out, err, timedOut) {
            _setHealthy(id, false)
            if (code !== 0) {
                _probeUnit(id)   // ehrlicher Ist-Zustand statt Blind-Reset
                actionFinished(id, false, "Stopp fehlgeschlagen: " + (err || out || "Exit " + code))
                return
            }
            _setState(id, "inactive")
            actionFinished(id, true, "")
        })
        return true
    }

    // ---------- intern ----------

    function _setState(id, s) {
        var m = states; m[id] = s; states = m
        if (s !== "active") _setHealthy(id, false)
    }
    function _setHealthy(id, h) {
        var m = healthy; m[id] = h; healthy = m
    }
    function _bump(map, id, val) {
        var m = map; m[id] = val; return m
    }

    function _probeUnit(id) {
        if (busyOf(id) || !manageableOf(id)) return
        _run(id, ["is-active", id], function(code, out, err, timedOut) {
            var s = (out || "").trim()
            // is-active: Exit 0 nur bei "active"; sonst inactive/failed/unknown
            if (svc.stateOf(id) === "starting" || svc.stateOf(id) === "stopping") {
                if (s === "inactive" || s === "failed") _setState(id, s)
                return   // Übergangszustand behalten, bis Health/Stop entscheidet
            }
            _setState(id, (s === "active" || s === "inactive" || s === "failed") ? s : "unknown")
        })
    }

    function _probeHealth(service) {
        svc.http.getJson(service.endpoint + service.healthPath, function(res) {
            if (res.ok) {
                _setHealthy(service.id, true)
                if (svc.stateOf(service.id) !== "stopping") {
                    var wasStarting = svc.stateOf(service.id) === "starting"
                    _setState(service.id, "active")
                    if (wasStarting) {
                        svc._polls = _bump(svc._polls, service.id, 0)
                        actionFinished(service.id, true, "")
                    }
                }
            } else {
                _setHealthy(service.id, false)
            }
        }, 5000)
    }

    // systemctl --user <args[0]> <args[1]>; cb(exitCode, stdout, stderr, timedOut)
    // systemd meldet eine fehlende Unit als "not found" — das ist kein
    // Startfehler des Dienstes, sondern fehlende Einrichtung. Getrennt
    // benannt, sonst sucht man den Fehler an der falschen Stelle.
    function _startFehlerText(meldung) {
        var m = String(meldung)
        if (m.indexOf("not found") !== -1 || m.indexOf("not be found") !== -1)
            return "Dienst nicht eingerichtet (systemd-Unit fehlt): " + m
        return "Start fehlgeschlagen: " + m
    }

    function _run(id, args, cb) {
        svc._runners = _bump(svc._runners, id, runnerFactory.createObject(svc, { "timeoutMs": 30000 }))
        var r = svc._runners[id]
        r.finished.connect(function(exitCode, stdoutText, stderrText, truncated, timedOut) {
            _release(id)
            cb(exitCode, stdoutText, stderrText, timedOut)
        })
        r.failed.connect(function(message) {
            _release(id)
            cb(-1, "", message, false)
        })
        r.start("systemctl", ["--user"].concat(args))
    }

    function _release(id) {
        var r = _runners[id]
        if (r) {
            var m = _runners; delete m[id]; _runners = m
            r.destroy()
        }
    }

    // Nach einem Start: Gesundheit pollen, bis der Dienst da ist (Erststart
    // eines Quadlets kann venv/Modell-Aufbau bedeuten). Ende über _polls[id].
    property Timer pollTimer: Timer {
        interval: svc.pollIntervalMs
        repeat: true
        onTriggered: {
            var any = false
            for (var i = 0; i < svc.services.length; i++) {
                var id = svc.services[i].id
                var left = svc._polls[id] || 0
                if (left <= 0) continue
                any = true
                svc._polls = svc._bump(svc._polls, id, left - 1)
                svc._probeHealth(svc.services[i])
                if (left - 1 === 0 && svc.stateOf(id) === "starting") {
                    svc._setState(id, "failed")
                    svc.actionFinished(id, false, "Zeitüberschreitung beim Start")
                }
            }
            if (!any) stop()
        }
    }
}
