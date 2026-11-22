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
        GenerateImageTool {}, GenerateVideoTool {}, GenerateAudioTool {},
        RoutineTool {},
        CloudRunCommandTool {}, CloudReadFileTool {}, CloudWriteFileTool {},
        CloudListDirTool {}, CloudPreviewTool {}, CloudScreenshotTool {}
    ]

    // „Befehle und Dateien: Cloud-Rechner" gewählt? Dann gibt es die lokalen
    // Prozess-/Datei-Werkzeuge nicht — auch nicht als Rückfall —, sondern die
    // gleichnamigen des Cloud-Rechners. Ohne Einstellung: dieser Rechner.
    function cloudSelected() {
        return !!(settings && settings.sandboxTarget === "cloud")
    }

    function _inMode(t) {
        if (t.target === "cloud") return cloudSelected()
        if (t.target === "device") return !cloudSelected()
        return true
    }

    property var _activeTool: null

    function toolByName(name) {
        for (var i = 0; i < allTools.length; i++)
            if (allTools[i].name === name && _inMode(allTools[i])) return allTools[i]
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
            if (!_inMode(t)) continue
            if (permissionFor(t.name) === "off") continue
            if (!t.isAvailable(ctx)) continue
            out.push(t.definitionFor(ctx))
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
            done(cloudSelected() && _existsLocally(name)
                 ? "Dieses Werkzeug gibt es im Modus „Cloud-Rechner“ nicht; Dateien und Befehle laufen dort im Cloud-Rechner."
                 : "Unbekanntes Tool: " + name, { "status": "error" })
            return
        }
        _activeTool = t
        t.execute(args, ctx, function(text, extra) {
            if (registry._activeTool === t) registry._activeTool = null
            done(text, extra)
        })
    }

    function _existsLocally(name) {
        for (var i = 0; i < allTools.length; i++)
            if (allTools[i].name === name && allTools[i].target === "device") return true
        return false
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
            if (!_inMode(t)) continue
            if (permissionFor(t.name) === "off") continue
            if (!t.isAvailable(ctx)) continue
            var fn = t.definitionFor(ctx).function
            var params = Object.keys((fn.parameters && fn.parameters.properties) || {}).join(", ")
            lines.push("- " + fn.name + "(" + params + "): " + fn.description)
        }
        return lines.join("\n") + "\n"
    }
}
