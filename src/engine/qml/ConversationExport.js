.pragma library

// Titel -> Dateinamen-Slug (klein, Nicht-Wort -> "-", getrimmt, max. 40 Zeichen).
function _slug(title) {
    var s = (title ? String(title) : "").toLowerCase().replace(/[^a-z0-9äöüß]+/g, "-").replace(/^-+|-+$/g, "")
    if (s.length > 40) s = s.substring(0, 40).replace(/-+$/, "")
    return s
}

// djb2 über den UTF-16-Code-Einheiten, 6 hex Stellen: billiger, stabiler
// Titel-Fingerabdruck für Dateinamen (kein Krypto-Anspruch, nur Kollisions-
// Vermeidung, wenn der Slug leer ausgeht).
function _hash(s) {
    var h = 5381
    for (var i = 0; i < s.length; i++) h = ((h << 5) + h + s.charCodeAt(i)) >>> 0
    return ("000000" + h.toString(16)).slice(-6)
}

function filename(title, timestamp) {
    var slug = _slug(title)
    // Nicht-lateinische Titel (kyrillisch, CJK, ...) sluggen zu "" — statt der
    // Kollision auf "aurora-<ts>.md" bei zwei Exporten im selben Sekundentakt
    // den stabilen Titel-Hash anhängen. Leerer Titel bleibt bewusst generisch.
    if (slug === "" && title && String(title) !== "") slug = "aurora-" + _hash(String(title))
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
