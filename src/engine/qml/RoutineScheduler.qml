import QtQuick
import net.niuton.aurora.engine

// Routinen-Scheduler: hält Routineeinträge aus dem Store, prüft periodisch
// (30-s-Takt) auf fällige/überfällige Einträge und führt sie AUTONOM aus —
// auch, während das Widget im Hintergrund läuft (der Scheduler hängt am
// Widget-Root und ist nicht an `active` gekoppelt; das Modell lädt
// modelManager.chat() bei Bedarf nach).
//
// Ausführung in einer EIGENEN AuroraEngine-Instanz: eigener chatModel/busy-
// State, ein Nutzer-Chat blockiert keinen Routine-Lauf und umgekehrt. Jeder
// Lauf landet in seiner eigenen Konversation (frischer Kontext, kein
// Zuwachsen über mehrere Läufe); die Routine merkt sich
// last_conversation — die Ergebnisse erscheinen wie normale Chats in der
// Sidebar und sind dort nachlesbar.
//
// Fälligkeit wird atomar über store.claimRoutines() gefordert (UPDATE setzt
// claim_token + last_status 'running' in derselben Transaktion, in der
// gelesen wird): Widget und App können parallel laufen, ohne denselben Lauf
// doppelt zu starten. Ein bei Prozessende stecken gebliebener Lauf ('running')
// wird beim nächsten Store-open() freigegeben und — next_run in der
// Vergangenheit — beim nächsten Takt genau einmal nachgeholt.
QtObject {
    id: sched

    // ==================== Injektion ====================
    property var store: null                 // ConversationStore (oder Mock)
    property var modelManager: null
    property var registry: null
    property var settings: null
    property var comfy: null
    property string homeDir: ""
    property var chatFn: null                // function(request) -> ChatJob
    property var embedFn: null
    // Cloud-Bild/Audio-Wege (vom AuroraController mit origin-Guard auf DIESE
    // Engine gesetzt). videoGenFn bewusst NICHT am Routine-Engine: der
    // asynchrone Polling-Pfad hängt am UI-Controller; das Tool blendet sich
    // ohne ctx.videoGenFn einfach aus.
    property var imageGenFn: null
    property var audioGenFn: null

    // ==================== Beobachtbarer Zustand (UI) ====================
    property var routineList: []             // gemappte Zeilen für die Sidebar
    // Der laufende Lauf (Badge in der Sidebar, solange die Engine busy ist).
    readonly property string activeRunId: sched._activeRun ? sched._activeRun.id : ""

    // ==================== Zeitplan-Mathematik (Lokalzeit, ms-Epoch) ====================
    readonly property var _weekdayNames: ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"]
    readonly property var _timeRe: /^([01]?\d|2[0-3]):([0-5]\d)$/

    function computeNextRun(kind, timeOfDay, weekday, intervalMinutes, fromMs) {
        var from = new Date(fromMs)
        if (kind === "interval") {
            var n = Math.max(1, parseInt(intervalMinutes, 10) || 60)
            // Anker "jetzt": kein Catch-up-Rückstand nach langen Ausfallzeiten.
            return from.getTime() + n * 60000
        }
        var m = sched._timeRe.exec(timeOfDay || "")
        var hh = m ? parseInt(m[1], 10) : 12
        var mm = m ? parseInt(m[2], 10) : 0
        var d = new Date(from.getFullYear(), from.getMonth(), from.getDate(), hh, mm, 0, 0)
        if (kind === "weekly") {
            var wd = Math.min(6, Math.max(0, parseInt(weekday, 10) || 0))   // 0 = Montag
            var cur = (d.getDay() + 6) % 7                                  // JS: 0 = Sonntag
            d.setDate(d.getDate() + ((wd - cur + 7) % 7))
            if (d.getTime() <= fromMs) d.setDate(d.getDate() + 7)
            return d.getTime()
        }
        // daily und once: heutige Uhrzeit, sonst die gleiche Zeit am Folgetag.
        if (d.getTime() <= fromMs) d.setDate(d.getDate() + 1)
        return d.getTime()
    }

    function scheduleText(r) {
        var k = (r && r.kind) ? r.kind : "daily"
        if (k === "interval") {
            var mins = Math.max(1, parseInt((r && r.intervalMinutes), 10) || 60)
            if (mins % 1440 === 0) return "alle " + (mins / 1440) + " d"
            if (mins % 60 === 0) return "alle " + (mins / 60) + " h"
            return "alle " + mins + " min"
        }
        var t = sched._timeRe.test((r && r.timeOfDay) || "") ? r.timeOfDay : "12:00"
        if (k === "weekly") {
            var wd = Math.min(6, Math.max(0, parseInt((r && r.weekday), 10) || 0))
            return sched._weekdayNames[wd] + " " + t
        }
        if (k === "once") return "einmalig " + t
        return "täglich " + t
    }

    // ==================== CRUD (UI-Dialog + manage_routines-Tool) ====================
    // Normalisiert Felder: Teil-Updates nur mit gelieferten Keys; bei create
    // Pflichtfeld prompt, Fallbacks für alles andere. Liefert null bei
    // unbrauchbarem Input (dem Tool als Fehler gemeldet).
    function _normalizeFields(fields, forCreate) {
        var f = (fields && typeof fields === "object") ? fields : {}
        var out = {}
        if ("title" in f || forCreate) {
            var t = String(f.title || "").trim()
            if (t === "" && forCreate) {
                var p0 = String(f.prompt || "").trim()
                t = p0 !== "" ? (p0.length > 40 ? p0.substring(0, 40) + "…" : p0) : "Routine"
            }
            out.title = t
        }
        if ("prompt" in f || forCreate) {
            var p = String(f.prompt || "").trim()
            if (p === "" && forCreate) return null
            out.prompt = p
        }
        if ("kind" in f || forCreate) {
            var k = String(f.kind || "daily")
            out.kind = (k === "weekly" || k === "interval" || k === "once") ? k : "daily"
        }
        if ("timeOfDay" in f || forCreate) {
            var tm = String(f.timeOfDay || "")
            var m = sched._timeRe.exec(tm)
            // Unbrauchbare Zeit -> Feld weglassen (Update behält Altstand) bzw.
            // Default bei create. computeNextRun fängt Reste ab.
            if (m) out.timeOfDay = ("0" + m[1]).slice(-2) + ":" + m[2]
            else if (forCreate) out.timeOfDay = "12:00"
        }
        if ("weekday" in f || forCreate)
            out.weekday = Math.min(6, Math.max(0, parseInt(f.weekday, 10) || 0))
        if ("intervalMinutes" in f || forCreate)
            out.intervalMinutes = Math.max(1, parseInt(f.intervalMinutes, 10) || 60)
        if ("enabled" in f || forCreate) {
            if (f.enabled !== undefined && f.enabled !== null) out.enabled = f.enabled === true
            else if (forCreate) out.enabled = true
        }
        return out
    }

    function _byId(id) {
        for (var i = 0; i < sched.routineList.length; i++)
            if (sched.routineList[i].id === id) return sched.routineList[i]
        return null
    }

    function createRoutine(fields) {
        if (!sched.store || typeof sched.store.addRoutine !== "function")
            return { "ok": false, "error": "Store nicht verfügbar" }
        var f = _normalizeFields(fields, true)
        if (f === null) return { "ok": false, "error": "Prompt fehlt" }
        f.id = sched.store.newUuid()
        f.nextRun = f.enabled === false ? 0
            : computeNextRun(f.kind, f.timeOfDay, f.weekday, f.intervalMinutes, Date.now())
        sched.store.addRoutine(f)
        // Liste auffrischt die Store-Connection nach dem asynchronen Write.
        return { "ok": true, "id": f.id }
    }

    // Öffentliches Update (UI/Tool): Zeitplan-relevante Änderungen setzen den
    // nächsten Lauf neu an (Mischung mit dem Altstand, damit Teil-Updates
    // korrekt rechnen). Scheduler-Buchhaltung geht direkt über _writeRoutine.
    function updateRoutine(id, fields) {
        if (!sched.store || typeof sched.store.updateRoutine !== "function")
            return { "ok": false, "error": "Store nicht verfügbar" }
        var f = _normalizeFields(fields, false)
        if (f === null) return { "ok": false, "error": "Ungültige Felder" }
        var reschedules = ("kind" in f) || ("timeOfDay" in f) || ("weekday" in f)
            || ("intervalMinutes" in f) || ("enabled" in f)
        if (reschedules) {
            var cur = sched._byId(id) || {}
            var merged = {
                "kind": ("kind" in f) ? f.kind : cur.kind,
                "timeOfDay": ("timeOfDay" in f) ? f.timeOfDay : cur.timeOfDay,
                "weekday": ("weekday" in f) ? f.weekday : cur.weekday,
                "intervalMinutes": ("intervalMinutes" in f) ? f.intervalMinutes : cur.intervalMinutes,
                "enabled": ("enabled" in f) ? f.enabled : cur.enabled
            }
            f.nextRun = (merged.enabled === false) ? 0
                : computeNextRun(merged.kind, merged.timeOfDay, merged.weekday,
                                 merged.intervalMinutes, Date.now())
        }
        sched.store.updateRoutine(id, f)
        return { "ok": true }
    }

    function deleteRoutine(id) {
        if (!sched.store || typeof sched.store.deleteRoutine !== "function")
            return { "ok": false, "error": "Store nicht verfügbar" }
        // Laufender Eintrag wird nach dem Write still verworfen (_writeResult
        // guardt auf Existenz via _byId).
        sched.store.deleteRoutine(id)
        return { "ok": true }
    }

    // Manueller Sofortlauf (Sidebar-Play-Knopf, Tool run_now): außer der Reihe,
    // ohne Claim — danach läuft der normale Takt wie nach jedem Lauf weiter.
    function runNow(id) {
        var r = sched._byId(id)
        if (!r) return { "ok": false, "error": "Routine nicht gefunden" }
        sched._queue.push({
            "id": r.id, "title": r.title, "prompt": r.prompt, "kind": r.kind,
            "timeOfDay": r.timeOfDay, "weekday": r.weekday,
            "intervalMinutes": r.intervalMinutes
        })
        sched._runNext()
        return { "ok": true }
    }

    // ==================== Store-Anbindung ====================
    function _mapRow(r) {
        return {
            "id": r.id, "title": r.title, "prompt": r.prompt,
            "kind": r.kind, "timeOfDay": r.timeOfDay || "",
            "weekday": r.weekday || 0, "intervalMinutes": r.intervalMinutes || 60,
            "enabled": r.enabled === true || r.enabled === 1,
            "nextRun": r.nextRun || 0, "lastRun": r.lastRun || 0,
            "lastStatus": r.lastStatus || "",
            "lastConversation": r.lastConversation || "",
            "scheduleText": scheduleText(r)
        }
    }

    function refresh() {
        if (!sched.store || typeof sched.store.routines !== "function") {
            sched.routineList = []
            return
        }
        sched.routineList = sched.store.routines().map(sched._mapRow)
    }

    function _relativeText(ms) {
        if (!ms) return "pausiert"
        var d = ms - Date.now()
        if (d <= 0) return "fällig"
        var min = Math.round(d / 60000)
        if (min < 1) return "in <1 min"
        if (min < 60) return "in " + min + " min"
        var h = Math.floor(min / 60), rest = min % 60
        if (h < 24) return "in " + h + " h" + (rest ? " " + rest + " min" : "")
        return "in " + Math.round(h / 24) + " d"
    }

    // ==================== Takt ====================
    property Timer _tick: Timer {
        interval: 30000
        repeat: true
        running: true
        onTriggered: sched.poll()
    }

    function poll() {
        if (!sched.store || sched.store.ready !== true) return
        sched.refresh()
        if (typeof sched.store.claimRoutines !== "function") return
        sched.store.claimRoutines(Date.now())
    }

    property Connections _storeConn: Connections {
        target: sched.store
        function onRoutinesClaimed(rows) {
            for (var i = 0; i < (rows || []).length; i++)
                sched._queue.push(rows[i])
            sched._runNext()
        }
        function onWriteCompleted(op) {
            if (op === "addRoutine" || op === "updateRoutine" || op === "deleteRoutine"
                    || op === "claimRoutines")
                sched.refresh()
        }
    }

    // ==================== Ausführung ====================
    property var _queue: []                  // geforderte/manuelle Läufe (FIFO)
    property var _activeRun: null

    function _runNext() {
        if (sched._activeRun !== null) return
        if (sched._queue.length === 0) return
        var row = sched._queue.shift()
        if (!row || !row.prompt) { _writeResult(row, "error", ""); _runNext(); return }
        var eng = sched._engine
        if (eng.busy) {                       // Staubfang: läuft noch etwas, wieder einreihen
            sched._queue.unshift(row)
            return
        }
        sched._activeRun = row
        // Frischer Kontext pro Lauf: keine wachsende History über mehrere Läufe.
        eng.newConversation()
        var convId = eng.conversationId
        var prompt = "[Automatische Routineausführung — "
            + Qt.formatDateTime(new Date(), "dddd, d. MMMM yyyy, HH:mm") + "]\n\n" + row.prompt
        eng.send(prompt, { "displayText": "⟳ " + (row.title || "Routine") })
        // Konversation benennen — NACH send() enqueue: _maybeSetTitle setzt den
        // Titel aus dem Prompt; dieser Touch läuft in der Worker-Queue danach
        // und gewinnt.
        if (sched.store && typeof sched.store.touchConversation === "function" && convId !== "")
            sched.store.touchConversation(convId, "⟳ " + (row.title || "Routine"))
        // send() endet in allen Pfaden mit busy=true; dieser Guard ist reiner
        // Selbsttest für unvorhergesehene Fälle (sonst bliebe der Lauf hängen).
        if (!eng.busy) Qt.callLater(sched._finishActiveRun)
    }

    property Connections _engineConn: Connections {
        target: sched._engine
        function onBusyChanged() {
            if (sched._engine.busy) return
            if (sched._activeRun === null) return
            // callLater, NICHT direkt: busyChanged feuert MITTEN in der
            // Zuweisung state = "idle" von _finalizeAssistant — ein direkter
            // Finish (und damit der Start des nächsten Laufs) würde von den
            // verbleibenden Zuweisungen von _finalizeAssistant überbaut
            // (state landete wieder auf "idle" und der Lauf "verschwand").
            Qt.callLater(sched._finishActiveRun)
        }
    }

    function _finishActiveRun() {
        var row = sched._activeRun
        sched._activeRun = null
        if (!row) return
        var status = "error"
        var resultText = ""
        var cm = sched._engine.chatModel
        for (var i = cm.count - 1; i >= 0; i--) {
            var r = cm.get(i)
            if (r.isUser) continue
            if (r.status === "final" || r.status === "error" || r.status === "aborted") {
                status = (r.status === "final") ? "ok" : "error"
                resultText = r.text || ""
                break
            }
        }
        sched._writeResult(row, status, resultText)
        sched._runNext()
    }

    // Buchhaltung nach jedem Lauf: Claim freigeben, Ergebnis vermerken, nächsten
    // Lauf ansetzen. "once" deaktiviert sich selbst; sonst schnappt next_run auf
    // den nächsten zukünftigen Termin (überfällige Läufe werden NICHT nachgeholt —
    // ein Ausfall von Tagen führt zu genau einem Lauf).
    function _writeResult(row, status, resultText) {
        if (!sched.store || typeof sched.store.updateRoutine !== "function" || !row || !row.id) return
        if (!sched._byId(row.id)) return        // inzwischen gelöscht -> keine Wiederauferstehung
        var now = Date.now()
        var f = {
            "lastRun": now,
            "lastStatus": status,
            "lastConversation": sched._engine.conversationId || "",
            "claimToken": ""
        }
        if ((row.kind || "daily") === "once") {
            f.enabled = false
            f.nextRun = 0
        } else {
            f.nextRun = computeNextRun(row.kind, row.timeOfDay, row.weekday,
                                       row.intervalMinutes, now)
        }
        sched.store.updateRoutine(row.id, f)
    }

    // ==================== Eigene Engine (getrennt vom UI-Chat) ====================
    readonly property AuroraEngine _engine: AuroraEngine {
        modelManager: sched.modelManager
        store: sched.store
        settings: sched.settings
        registry: sched.registry
        comfy: sched.comfy
        homeDir: sched.homeDir
        chatFn: sched.chatFn
        embedFn: sched.embedFn
        imageGenFn: sched.imageGenFn
        audioGenFn: sched.audioGenFn
        routines: sched                          // manage_routines auch aus Routinen heraus
    }
}
