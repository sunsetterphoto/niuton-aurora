import QtQuick
import net.niuton.aurora.engine

// Verwaltet Routinen (geplante Selbstläufe): Der Aufruf "Prüfe den Preis von
// Brent crude oil jeden Tag um 12 Uhr" führt über create zu einem Eintrag mit
// Zeitplan + Prompt; der RoutineScheduler führt ihn autonom aus. Liste/Ändern/
// Löschen/Jetzt-ausführen runden die Verwaltung ab. ctx.routines ist der
// geteilte RoutineScheduler (AuroraController).
Tool {
    name: "manage_routines"
    category: "local"          // kein sofortiger Netz-/Systemeingriff; Folgeläufe sind sichtbar + löschbar
    permissionKey: "toolManageRoutines"
    definition: ({
        "type": "function",
        "function": {
            "name": "manage_routines",
            "description": "Manage recurring routines: scheduled tasks that Aurora runs autonomously (also in the background). Use whenever the user wants something done regularly or at a fixed time (e.g. 'check the Brent oil price every day at 12:00', 'remind me every Monday at 9:00 to ...'). Kinds: daily (time HH:MM), weekly (weekday 0=Monday..6=Sunday plus time), interval (every N minutes), once (next occurrence of time).",
            "parameters": {
                "type": "object",
                "properties": {
                    "action": { "type": "string", "enum": ["create", "list", "update", "delete", "run_now"],
                                "description": "create a new routine, list existing ones, update/delete by id, or run_now to execute immediately" },
                    "id": { "type": "string", "description": "Routine id (required for update/delete/run_now; from list)" },
                    "title": { "type": "string", "description": "Short label, e.g. 'Brent-Preis prüfen'" },
                    "prompt": { "type": "string", "description": "The instruction Aurora executes on every run (create/update)" },
                    "kind": { "type": "string", "enum": ["daily", "weekly", "interval", "once"],
                              "description": "Schedule type (create/update)" },
                    "time": { "type": "string", "description": "Time of day HH:MM, 24-hour (daily/weekly/once)" },
                    "weekday": { "type": "integer", "description": "0=Monday .. 6=Sunday (weekly)" },
                    "intervalMinutes": { "type": "integer", "description": "Minutes between runs (interval)" },
                    "enabled": { "type": "boolean", "description": "Active or paused (default true)" }
                },
                "required": ["action"]
            }
        }
    })
    function describe(args) {
        var a = args || {}
        if (a.action === "create")
            return "Routine anlegen: " + (a.title || a.prompt || "").substring(0, 60)
        if (a.action === "delete") return "Routine löschen: " + (a.id || "")
        if (a.action === "update") return "Routine ändern: " + (a.id || "")
        if (a.action === "run_now") return "Routine jetzt ausführen: " + (a.id || "")
        return "Routinen anzeigen"
    }
    function _listing(r) {
        var rows = r.routineList || []
        if (rows.length === 0) return "(Keine Routinen angelegt)"
        var out = []
        for (var i = 0; i < rows.length; i++) {
            var e = rows[i]
            out.push("- id=" + e.id
                     + " | " + e.title
                     + " | " + e.scheduleText
                     + " | " + (e.enabled ? "aktiv" : "pausiert")
                     + " | nächster Lauf: " + (e.nextRun ? new Date(e.nextRun).toLocaleString(Qt.locale(), "dd.MM. hh:mm") : "—"))
        }
        return out.join("\n")
    }
    function execute(args, ctx, done) {
        var r = ctx.routines
        if (!r || typeof r.createRoutine !== "function") {
            done("(Routinen sind nicht verfügbar)", { status: "error" })
            return
        }
        var a = args || {}
        var res
        switch (a.action) {
        case "create":
            res = r.createRoutine({ "title": a.title, "prompt": a.prompt, "kind": a.kind,
                                    "timeOfDay": a.time, "weekday": a.weekday,
                                    "intervalMinutes": a.intervalMinutes,
                                    "enabled": a.enabled !== false })
            done(res.ok ? "Routine erstellt (id=" + res.id + "). Sie läuft ab jetzt automatisch nach Zeitplan; der Nutzer sieht sie in der Seitenleiste."
                        : "Routine konnte nicht erstellt werden: " + (res.error || ""),
                 { status: res.ok ? "ok" : "error" })
            return
        case "list":
            done(_listing(r), { status: "ok" })
            return
        case "update":
            res = r.updateRoutine(a.id || "", { "title": a.title, "prompt": a.prompt,
                "kind": a.kind, "timeOfDay": a.time, "weekday": a.weekday,
                "intervalMinutes": a.intervalMinutes, "enabled": a.enabled })
            done(res.ok ? "Routine aktualisiert (id=" + (a.id || "") + ")."
                        : "Update fehlgeschlagen: " + (res.error || ""),
                 { status: res.ok ? "ok" : "error" })
            return
        case "delete":
            res = r.deleteRoutine(a.id || "")
            done(res.ok ? "Routine gelöscht (id=" + (a.id || "") + ")."
                        : "Löschen fehlgeschlagen: " + (res.error || ""),
                 { status: res.ok ? "ok" : "error" })
            return
        case "run_now":
            res = r.runNow(a.id || "")
            done(res.ok ? "Routine wird jetzt ausgeführt."
                        : "Sofortlauf nicht möglich: " + (res.error || ""),
                 { status: res.ok ? "ok" : "error" })
            return
        default:
            done("Unbekannte action: " + a.action, { status: "error" })
        }
    }
}
