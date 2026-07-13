.pragma library
.import net.niuton.aurora.core as Core

function search(query, maxResults, callback) {
    var url = "http://127.0.0.1:8888/search/text?query=" + encodeURIComponent(query) + "&max_results=" + (maxResults || 5)
    Core.Http.getJson(url, function(res) {
        if (!res.ok) { callback("(Web-Suche nicht verfügbar)"); return }
        callback(formatResults((res.data && res.data.results) || []))
    })
}

function formatResults(results) {
    if (results.length === 0) return "(Keine Suchergebnisse gefunden)"
    var text = ""
    for (var i = 0; i < results.length; i++) {
        text += (i+1) + ". " + results[i].title + "\n"
        if (results[i].body) text += "   " + results[i].body.substring(0, 200) + "\n"
        text += "   URL: " + results[i].href + "\n\n"
    }
    return text
}
