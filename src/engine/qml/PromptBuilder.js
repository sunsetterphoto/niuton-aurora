.pragma library

// Kürzt auf max Zeichen (mit Ellipse), robust gegen null/undefined. Zeilenumbrüche
// werden zu " / " geglättet — rohe Umbrüche aus KB-Inhalten würden sonst die
// Sektions-Struktur des Prompts verwässern (eigene Zeilen ohne "- "-Präfix).
function _trunc(s, max) {
    s = String(s || "").replace(/\s*\n+\s*/g, " / ")
    return s.length > max ? s.substring(0, max - 1) + "…" : s
}

// Baut den Systemprompt frisch pro Request. toolSection kommt vom Aufrufer
// (ToolRegistry.promptSection); die dynamischen Kontext-Werte (now/timezone/
// locale/userName/activeModel/isRemote) sammelt der Aufrufer (ChatController) —
// so bleibt diese Library rein (kein new Date()/Qt) und deterministisch testbar.
function build(opts) {
    var homeDir = opts.homeDir || ""
    var ctx = "You are Aurora, a local AI assistant on the user's KDE Plasma 6 Linux desktop"
    ctx += " — available both as a panel widget and a standalone app, sharing one engine."
    ctx += " Your purpose: help with questions, tasks, local reasoning, image generation and"
    ctx += " voice, favouring local and private processing.\n"
    ctx += "Respond in the same language the user writes in. Be concise. Use markdown.\n\n"

    ctx += (opts.toolSection || "")
    if (ctx.charAt(ctx.length - 1) !== "\n") ctx += "\n"
    ctx += "\n"

    ctx += "## Rules\n"
    ctx += "- When the user asks about files or directories, use list_directory or read_file.\n"
    ctx += "- When the user asks about current information, use web_search.\n"
    ctx += "- When unsure about a fact, use web_search to verify.\n"
    ctx += "- Respond from your own knowledge only for general explanations and well-established facts.\n"
    ctx += "- After receiving tool results, summarize the relevant information for the user.\n"
    ctx += "- Use the user's home directory " + homeDir + " as the base for relative paths.\n"
    ctx += "- Treat the date/time under Context as the current moment. When the user uses relative"
    ctx += " dates (\"today\", \"tomorrow\", \"next week\"), resolve them to concrete dates against it"
    ctx += " — especially in web_search queries.\n"

    // ## Context (dynamisch): nur ausgeben, wenn mindestens ein Feld gesetzt ist.
    var cl = []
    if (opts.now) cl.push("- Now: " + opts.now + (opts.timezone ? " (" + opts.timezone + ")" : ""))
    if (opts.locale) cl.push("- Locale: " + opts.locale)
    if (opts.userName) cl.push("- User: " + opts.userName)
    if (opts.activeModel) cl.push("- Active model: " + opts.activeModel + (opts.isRemote ? " (remote)" : " (local)"))
    var hostBits = []
    if (opts.hostname) hostBits.push(opts.hostname)
    if (opts.osName) hostBits.push(opts.osName)
    if (opts.ramGB) hostBits.push(opts.ramGB)
    if (hostBits.length) cl.push("- Host: " + hostBits.join(" · "))
    if (cl.length) {
        ctx += "\n## Context\n"
        ctx += "- Environment: KDE Plasma 6; local Ollama + remote Ollama server; ComfyUI (images); voice (STT/TTS)\n"
        for (var i = 0; i < cl.length; i++)
            ctx += cl[i] + "\n"
    }

    if (opts.memory) {
        ctx += "\n## Memory\n" + opts.memory + "\n"
    }

    // Wissensbasis (Scheibe C): vom Retrieval gelieferte Treffer (bewertete Antworten
    // + manuelle Einträge) als konservativ gekürzter Block hinter ## Memory.
    if (opts.knowledge && opts.knowledge.length) {
        ctx += "\n## Knowledge base\n"
        ctx += "Entries from the user's personal knowledge base that may be relevant to the"
        ctx += " current question. Use them when they fit; ignore them otherwise.\n"
        for (var i = 0; i < opts.knowledge.length; i++) {
            var k = opts.knowledge[i] || {}
            if (k.source === "rated") {
                ctx += "- Q: " + _trunc(k.question, 200) + "\n"
                ctx += "  A: " + _trunc(k.answer, 800) + "\n"
            } else {
                var head = _trunc(k.title, 100)
                if (k.kind === "link" && k.url) head += (head !== "" ? " " : "") + "(" + _trunc(k.url, 120) + ")"
                ctx += "- " + (head !== "" ? head + ": " : "") + _trunc(k.content, 500) + "\n"
            }
        }
    }

    return ctx
}
