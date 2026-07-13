import QtQuick
import net.niuton.aurora.engine

QtObject {
    id: registry

    // Quelle der statischen Freigabestufen (settings[tool.permissionKey]).
    property var settings: null

    // Alle bekannten Tools. Neues Tool = hier eine Zeile ergänzen.
    property list<QtObject> allTools: [
        ReadFileTool {}, ListDirectoryTool {}, WriteFileTool {},
        WebSearchTool {}, WebFetchTool {}, RunCommandTool {},
        GenerateImageTool {}
    ]

    property var _activeTool: null

    function toolByName(name) {
        for (var i = 0; i < allTools.length; i++)
            if (allTools[i].name === name) return allTools[i]
        return null
    }

    function categoryOf(name) {
        var t = toolByName(name)
        return t ? t.category : "local"
    }

    // Legacy "disabled" -> off; leer/unbekannt -> "auto".
    function _normalize(v) {
        if (v === "off" || v === "disabled") return "off"
        if (v === "confirm") return "confirm"
        return "auto"
    }

    // Statische, normalisierte + geklammerte Stufe. Unbekanntes Tool -> "off".
    function permissionFor(name) {
        var t = toolByName(name)
        if (!t) return "off"
        var raw = settings ? settings[t.permissionKey] : undefined
        var lvl = _normalize(raw)
        if (lvl === "auto" && t.minPermission === "confirm") return "confirm"
        return lvl
    }

    // Tools für den Ollama-Payload: verfügbar UND nicht off.
    function definitions(ctx) {
        var out = []
        for (var i = 0; i < allTools.length; i++) {
            var t = allTools[i]
            if (permissionFor(t.name) === "off") continue
            if (!t.isAvailable(ctx)) continue
            out.push(t.definition)
        }
        return out
    }

    function describe(name, args) {
        var t = toolByName(name)
        return t ? t.describe(args) : name
    }

    function execute(name, args, ctx, done) {
        var t = toolByName(name)
        if (!t) {
            done("Unbekanntes Tool: " + name)
            return
        }
        _activeTool = t
        t.execute(args, ctx, function(text, extra) {
            if (registry._activeTool === t) registry._activeTool = null
            done(text, extra)
        })
    }

    function abortRunning() {
        if (_activeTool) { _activeTool.abort(); _activeTool = null }
    }

    // Generierter Tool-Abschnitt für den Systemprompt (nur verfügbare, nicht-off).
    function promptSection(ctx) {
        var lines = ["## Your Tools",
                     "You have tools to interact with the system. Use them proactively:"]
        for (var i = 0; i < allTools.length; i++) {
            var t = allTools[i]
            if (permissionFor(t.name) === "off") continue
            if (!t.isAvailable(ctx)) continue
            var fn = t.definition.function
            var params = Object.keys((fn.parameters && fn.parameters.properties) || {}).join(", ")
            lines.push("- " + fn.name + "(" + params + "): " + fn.description)
        }
        return lines.join("\n") + "\n"
    }
}
