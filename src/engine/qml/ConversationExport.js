.pragma library

// Titel -> Dateinamen-Slug (klein, Nicht-Wort -> "-", getrimmt, max. 40 Zeichen).
function _slug(title) {
    var s = (title ? String(title) : "").toLowerCase().replace(/[^a-z0-9äöüß]+/g, "-").replace(/^-+|-+$/g, "")
    if (s.length > 40) s = s.substring(0, 40).replace(/-+$/, "")
    return s
}

function filename(title, timestamp) {
    var slug = _slug(title)
    return (slug === "" ? "aurora" : slug) + "-" + timestamp + ".md"
}

// rows = store.messages()-Ausgabe; meta = {title, model, exportedAt}.
// Sauberes Transkript: nur user/assistant; ohne Thinking/Tool; Bild als Pfad-Notiz.
function toMarkdown(rows, meta) {
    var m = meta || {}
    var out = "# " + (m.title ? m.title : "Aurora-Konversation") + "\n\n"
    out += "*Modell: " + (m.model ? m.model : "?") + " · Exportiert: " + (m.exportedAt ? m.exportedAt : "") + "*\n\n---\n\n"
    var list = rows || []
    for (var i = 0; i < list.length; i++) {
        var r = list[i]
        if (r.role !== "user" && r.role !== "assistant") continue
        var c = (r.content !== undefined && r.content !== null) ? String(r.content).trim() : ""
        var img = (r.mediaPath && String(r.mediaPath) !== "") ? "[Bild: " + r.mediaPath + "]" : ""
        if (c === "" && img === "") continue   // leere Zeile (z. B. reiner Tool-Call-Zug) überspringen
        out += (r.role === "user" ? "**Du:**" : "**Aurora:**") + "\n\n"
        if (c !== "") out += c + "\n\n"
        if (img !== "") out += img + "\n\n"
    }
    return out
}
