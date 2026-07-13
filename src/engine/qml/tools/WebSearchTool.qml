import QtQuick
import net.niuton.aurora.engine

Tool {
    name: "web_search"
    category: "network"
    permissionKey: "toolWebSearch"
    definition: ({
        "type": "function",
        "function": {
            "name": "web_search",
            "description": "Search the web for current information. Use for current events, weather, news, prices, or anything requiring up-to-date information.",
            "parameters": {
                "type": "object",
                "properties": { "query": { "type": "string", "description": "The search query" } },
                "required": ["query"]
            }
        }
    })
    function describe(args) { return "Web-Suche: " + (args.query || "") }
    function _format(results) {
        if (!results || results.length === 0) return "(Keine Suchergebnisse gefunden)"
        var text = ""
        for (var i = 0; i < results.length; i++) {
            text += (i + 1) + ". " + results[i].title + "\n"
            if (results[i].body) text += "   " + results[i].body.substring(0, 200) + "\n"
            text += "   URL: " + results[i].href + "\n\n"
        }
        return text
    }
    function execute(args, ctx, done) {
        var base = (ctx.settings && ctx.settings.searchEndpoint) ? ctx.settings.searchEndpoint : ""
        if (base === "") base = "http://127.0.0.1:8888"
        var url = base + "/search/text?query=" + encodeURIComponent(args.query || "") + "&max_results=5"
        ctx.http.getJson(url, function(res) {
            if (!res.ok) { done("(Web-Suche nicht verfügbar)", { status: "error" }); return }
            var results = (res.data && res.data.results) || []
            done(_format(results).substring(0, 5000))
        })
    }
}
