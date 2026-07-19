import QtQuick
import net.niuton.aurora.core
import net.niuton.aurora.engine
import "PromptBuilder.js" as PromptBuilder
import "ContextCompactor.js" as ContextCompactor
import "ConversationExport.js" as ConversationExport

QtObject {
    id: ctl

    // --- Injizierte Abhängigkeiten ---
    property var settings: null
    property var registry: null
    property var resolver: null
    property var grants: null
    property var store: null
    property var comfy: null
    property var fileio: (typeof FileIO !== "undefined") ? FileIO : null
    property var http: (typeof Http !== "undefined") ? Http : null
    property var chatFn: null                 // function(request) -> ChatJob
    property var embedFn: null                // function(input, cb) -> cb({vec, model} | null)

    // --- Kontext (Betrieb: an ModelManager gebunden; Test: gesetzt) ---
    property string activeModel: ""
    property var activeCaps: []
    property bool isRemote: false
    property bool comfyAvailable: false
    property string homeDir: ""
    property bool thinkingEnabled: false

    // --- Beobachtbarer Zustand ---
    property ListModel chatModel: ListModel {}
    property string state: "idle"             // idle | streaming | toolRunning | toolPending
    property bool busy: state !== "idle"
    property string conversationId: ""
    readonly property var pendingTool: _pending ? { "name": _pending.name, "description": _pending.description } : null
    property string statusText: ""

    // --- Interna ---
    property int _generation: 0
    property var _activeJob: null
    property int _streamIndex: -1
    property string _thinking: ""
    property string _content: ""
    property var _messages: []                // API-Nachrichtenverlauf des aktuellen Zuges
    property string _contextSummary: ""        // laufende Synopse des kompaktierten Verlaufs
    property int _summarizedCount: 0           // Anzahl der ältesten _messages, die die Synopse abdeckt
    readonly property int _keepRecent: 6
    readonly property real _compactThreshold: 0.75
    readonly property int _assumedCtx: 8192
    readonly property int _responseReserve: 1024
    property string _turnId: ""                // gemeinsame turn_id aller Rows EINES Zuges
    property int _toolBubbleIndex: -1
    property var _activity: []                // aktueller toolActivity-Array der Runde
    property var _callStart: ({})              // name|args -> Date.now()

    // --- Wissensbasis Scheibe C (Retrieval) ---
    property var _ragSources: []               // volle Treffer des aktuellen Zuges (Prompt + slim)
    property var _ragByMsgId: ({})             // slim-Attribution je persistierter assistant-msgId
    property var _ragFinish: null              // Abschluss-Closure des laufenden Retrievals
    // Eigener 8-s-Guard: der 20-s-HTTP-Timeout des Embed-Calls wäre für einen
    // blockierenden Zug zu lang; späte Callbacks werden via done/_generation verworfen.
    property Timer _ragTimer: Timer { interval: 8000; repeat: false; onTriggered: ctl._onRagTimeout() }

    signal messageAppended()
    signal assistantFinal(string text)   // feuert bei _finalizeAssistant("final") — Auto-Vorlesen-Trigger

    // ---- ListModel-Helfer: setzt IMMER alle 12 Rollen ----
    function _appendRow(f) {
        chatModel.append({
            "msgId": f.msgId || "", "text": f.text || "", "isUser": f.isUser === true,
            "thinking": f.thinking || "", "streaming": f.streaming === true,
            "ts": f.ts || "", "mediaPath": f.mediaPath || "", "mediaType": f.mediaType || "",
            "status": f.status || "", "toolActivity": f.toolActivity || "[]",
            "rating": f.rating || 0, "ragSources": f.ragSources || "[]"
        })
        messageAppended()
    }
    function _nowTs() { return Qt.formatTime(new Date(), "hh:mm") }

    // Bewertung einer (persistierten) Assistant-Antwort: DB schreiben + Modell-Zeile
    // aktualisieren. Leere msgId (noch nicht persistiert) -> No-op.
    function rateMessage(msgId, rating) {
        if (!msgId) return
        store.updateMessage(msgId, { "rating": rating })
        for (var i = 0; i < chatModel.count; i++) {
            if (chatModel.get(i).msgId === msgId) {
                chatModel.setProperty(i, "rating", rating)
                break
            }
        }
        _syncEmbedding(msgId, rating)
    }

    // Wissensbasis Scheibe B: beim 👍 die zugehörige Frage einbetten und den
    // Vektor auf DIESER (Assistant-)Zeile ablegen; bei jedem anderen Rating den
    // Vektor löschen. Best-effort + feature-detektiert (fehlt embedFn/setEmbedding,
    // z. B. in schlanken Test-Mocks, passiert nichts).
    //
    // Request-Token je msgId: schneller Rating-Wechsel (👍 → zurück, während der
    // Embed noch läuft) darf keinen Orphan-Vektor hinterlassen. Jede Rate-Aktion
    // (auch die synchrone Clear-Variante) bumpt den Token; ein verspäteter
    // Callback mit veraltetem Token wird verworfen.
    property var _embedTokens: ({})   // msgId -> monotone Nummer

    function _syncEmbedding(msgId, rating) {
        if (!ctl.store || typeof ctl.store.setEmbedding !== "function") return
        var tok = (ctl._embedTokens[msgId] || 0) + 1      // jede Rate-Aktion invalidiert frühere Callbacks
        ctl._embedTokens[msgId] = tok
        if (rating === 1) {
            if (!ctl.embedFn || typeof ctl.store.questionForAnswer !== "function") return
            var q = ctl.store.questionForAnswer(msgId)
            if (!q) return
            ctl.embedFn(q, function(r) {
                if (ctl._embedTokens[msgId] !== tok) return   // Zustand hat sich geändert -> verwerfen
                if (r && r.vec && r.vec.length > 0) ctl.store.setEmbedding(msgId, r.vec, r.model)
            })
        } else {
            ctl.store.setEmbedding(msgId, [], "")
        }
    }

    function _ensureConversation() {
        if (conversationId === "") conversationId = store.newUuid()
        return conversationId
    }
    function _persist(msg) {
        msg.conversationId = _ensureConversation()
        msg.id = store.newUuid()
        msg.turnId = _turnId
        store.appendMessage(msg)
        return msg.id
    }

    function _buildCtx() {
        return {
            "fileio": ctl.fileio, "http": ctl.http, "settings": ctl.settings, "comfy": ctl.comfy,
            // Ursprungs-Konversation für Tools, die eine spätere Zuordnung brauchen
            // (generate_image reicht sie als originConvId an ComfyClient weiter, damit
            // der onFinished-Guard tool-Bilder ebenfalls der richtigen Konversation
            // zuordnet — Fix 2 nach Re-Review).
            "conversationId": ctl.conversationId,
            "newProcess": function() {
                var p = Qt.createQmlObject('import net.niuton.aurora.core; ProcessRunner {}', ctl)
                p.maxOutputBytes = 100000     // Parität zur alten main.qml-Fabrik (5b-Handoff)
                return p
            }
        }
    }

    // Audit-Fix (Klein/perf): _systemPrompt() laeuft pro _buildMessages() — bei
    // einem 5-Runden-Tool-Zug waren das ~24 synchrone Disk-Reads auf dem
    // GUI-Thread. hostname/osName/ramGB aendern sich zur Laufzeit nicht ->
    // einmalig gelesen und in _sysStatic gehalten. memory.md ist dagegen
    // nutzer-editierbar -> pro ZUG einmal frisch (Cache _memoryCache, am
    // send()-Einstieg invalidiert), nicht pro Runde.
    property var _sysStatic: null
    property var _memoryCache: null          // null = veraltet/noch nicht gelesen

    function _sysStaticRead() {
        if (ctl._sysStatic !== null) return ctl._sysStatic
        var host = ctl.fileio ? ctl.fileio.readText("/etc/hostname", 256) : { ok: false }
        var osRel = ctl.fileio ? ctl.fileio.readText("/etc/os-release", 4096) : { ok: false }
        var meminfo = ctl.fileio ? ctl.fileio.readText("/proc/meminfo", 4096) : { ok: false }
        var osName = ""
        if (osRel.ok) { var m1 = osRel.text.match(/PRETTY_NAME="([^"]+)"/); osName = m1 ? m1[1] : "Linux" }
        var ramGB = ""
        if (meminfo.ok) { var m2 = meminfo.text.match(/MemTotal:\s+(\d+)/); if (m2) ramGB = Math.round(parseInt(m2[1]) / 1024 / 1024) + " GB" }
        ctl._sysStatic = { "hostname": host.ok ? host.text.trim() : "", "osName": osName, "ramGB": ramGB }
        return ctl._sysStatic
    }

    function _memoryRead() {
        if (ctl._memoryCache === null)
            ctl._memoryCache = ctl.fileio ? ctl.fileio.readText((ctl.fileio.standardPath("appData")) + "/memory.md", 65536) : { ok: false }
        return ctl._memoryCache
    }

    function _systemPrompt() {
        var st = _sysStaticRead()
        var mem = _memoryRead()

        // Dynamischer Kontext (frisch pro Request): Datum/Uhrzeit lokalisiert,
        // Zeitzone (Intl, Fallback UTC-Offset), Locale, System-Benutzername.
        var d = new Date()
        var now = d.toLocaleString(Qt.locale(), "dddd, d. MMMM yyyy, HH:mm")
        var tz = ""
        try { tz = Intl.DateTimeFormat().resolvedOptions().timeZone } catch (e) { tz = "" }
        if (!tz) {
            var off = -d.getTimezoneOffset()                 // Minuten oestlich von UTC
            var sign = off >= 0 ? "+" : "-"
            off = Math.abs(off)
            tz = "UTC" + sign + ("0" + Math.floor(off / 60)).slice(-2) + ":" + ("0" + (off % 60)).slice(-2)
        }
        var userName = (ctl.homeDir || "").replace(/\/+$/, "").split("/").pop()

        return PromptBuilder.build({
            homeDir: ctl.homeDir,
            hostname: st.hostname,
            osName: st.osName, ramGB: st.ramGB,
            memory: mem.ok ? mem.text.trim() : "",
            now: now, timezone: tz, locale: Qt.locale().name,
            userName: userName,
            activeModel: ctl.activeModel, isRemote: ctl.isRemote,
            knowledge: ctl._ragSources,
            toolSection: (ctl.registry && (ctl.activeCaps || []).indexOf("tools") !== -1)
                         ? ctl.registry.promptSection(_buildCtx()) : ""
        })
    }

    function _buildMessages() {
        var msgs = [{ "role": "system", "content": _systemPrompt() }]
        // Kompaktierter Verlauf: (optionale) Synopse der ältesten Nachrichten + die
        // wörtlichen ab _summarizedCount. Die Kompaktierung (_maybeCompact) begrenzt
        // die Länge — daher kein fixer Zähl-Cap mehr.
        if (ctl._contextSummary !== "")
            msgs.push({ "role": "system", "content": "Zusammenfassung des bisherigen Verlaufs:\n" + ctl._contextSummary })
        for (var i = ctl._summarizedCount; i < _messages.length; i++) msgs.push(_messages[i])
        return msgs
    }

    function _paramNum(key) {
        if (!ctl.settings) return 0
        var p = ctl.settings.paramsFor(ctl.activeModel)
        return (p && p[key]) ? p[key] : 0
    }

    // Vor dem Zug: bei knappem Budget den älteren Verlauf zusammenfassen.
    // cb() wird IMMER aufgerufen (auch bei Fehler/keine Kompaktierung) — best-effort.
    function _maybeCompact(cb) {
        var verbatim = _messages.slice(ctl._summarizedCount)
        var p = ContextCompactor.plan({
            verbatim: verbatim, summary: ctl._contextSummary, systemPromptText: _systemPrompt(),
            numCtx: _paramNum("num_ctx"), numPredict: _paramNum("num_predict"),
            keepRecent: ctl._keepRecent, thresholdFraction: ctl._compactThreshold,
            assumedCtx: ctl._assumedCtx, responseReserve: ctl._responseReserve
        })
        if (p.needsCompaction) _summarize(p.foldCount, cb)
        else if (p.trimCount > 0) {
            // Audit-Fix (Klein/logic): <= keepRecent Nachrichten, aber über Budget
            // — zu wenig Material für eine LLM-Synopse. Die ältesten trimCount
            // Nachrichten fallen aus dem API-Kontext (gleicher Mechanismus wie die
            // Synopse: _summarizedCount rückt vor, nur ohne Zusammenfassung).
            // Bewusst NICHT persistiert: nach einem Reload sind sie wieder da und
            // der nächste Zug trimmt erneut.
            ctl._summarizedCount += p.trimCount
            cb()
        }
        else cb()
    }

    // Faltet die ältesten foldCount wörtlichen Nachrichten (+ bisherige Synopse)
    // via aktivem Modell in eine neue Synopse. Best-effort: bei Fehler/leer bleibt alles.
    function _summarize(foldCount, cb) {
        var slice = _messages.slice(ctl._summarizedCount, ctl._summarizedCount + foldCount)
        if (slice.length === 0) { cb(); return }
        var parts = []
        if (ctl._contextSummary !== "") parts.push("Bisherige Zusammenfassung:\n" + ctl._contextSummary)
        for (var i = 0; i < slice.length; i++)
            parts.push((slice[i].role === "user" ? "Nutzer: " : "Aurora: ") + (slice[i].content || ""))
        // Anker = letzte user/assistant-Nachricht MIT _msgId im gefalteten Slice.
        // loadConversation baut _messages nur aus user/assistant-Zeilen; ein tool-Anker
        // (oder die synthetische Rundenlimit-Zeile ohne _msgId) würde den Reload-Filter
        // nicht überleben (idx=-1 -> Synopse verworfen). Degenerierter Slice ohne jede
        // user/assistant-Zeile -> "" -> Reset beim Reload (unschädlich).
        var boundaryMsgId = ""
        for (var b = slice.length - 1; b >= 0; b--) {
            if ((slice[b].role === "user" || slice[b].role === "assistant") && slice[b]._msgId) {
                boundaryMsgId = slice[b]._msgId; break
            }
        }
        var prevStatus = ctl.statusText
        ctl.statusText = "Kontext wird kompaktiert …"
        // Die Kompaktierung nimmt an der bestehenden busy-/Generation-Maschinerie
        // teil: state busy setzen (blockt Doppel-send via `if (busy) return`, macht
        // stop() erreichbar) und _activeJob registrieren (stop() kann abbrechen).
        // Ein Konversationswechsel läuft über state != "idle" in stop() ->
        // _generation++ -> der stale Job wird unten per Generation-Guard verworfen
        // (kein Persist, kein cb) und kann so den neuen Zustand nicht korrumpieren.
        var gen = ctl._generation
        ctl.state = "streaming"
        var req = {
            "model": ctl.activeModel, "keepAlive": "10m", "think": false,
            "options": { "num_predict": 512 },
            "messages": [
                { "role": "system", "content": "Verdichte den folgenden Gesprächsverlauf zu einer knappen Synopse. Bewahre Fakten, Entscheidungen, Nutzer-Präferenzen und offene Fäden; keine Anrede, keine Meta-Kommentare, nur die Synopse." },
                { "role": "user", "content": parts.join("\n\n") }
            ]
        }
        var acc = ""
        var job = ctl.chatFn(req)
        ctl._activeJob = job
        job.token.connect(function(t) { acc += t })
        // Vertrag (ChatJob.qml): "Der Aufrufer zerstört den Job nach Gebrauch" —
        // analog zu _stream() wird der Job in done/error explizit destroyed und die
        // Epoche geprüft (bei Wechsel: kein Zustand schreiben, kein cb).
        job.done.connect(function(r) {
            if (ctl._activeJob === job) ctl._activeJob = null
            job.destroy()
            if (gen !== ctl._generation) return
            var text = ((r && r.content) ? r.content : acc).trim()
            if (text !== "") {
                ctl._contextSummary = text
                ctl._summarizedCount += foldCount
                _persistCompaction(boundaryMsgId)
            }
            ctl.statusText = prevStatus
            cb()
        })
        job.error.connect(function(m) {
            if (ctl._activeJob === job) ctl._activeJob = null
            job.destroy()
            if (gen !== ctl._generation) return
            ctl.statusText = prevStatus
            cb()
        })
    }

    function _persistCompaction(boundaryMsgId) {
        if (!ctl.conversationId) return
        var conv = store.conversation(ctl.conversationId)
        var extra = (conv && conv.extra) ? conv.extra : ({})
        extra.contextSummary = ctl._contextSummary
        extra.contextSummaryThroughMsgId = boundaryMsgId
        store.updateConversation(ctl.conversationId, { "extra": extra })
    }

    // Manuell (/compact): erzwingt Kompaktierung, sofern mehr als keepRecent wörtlich.
    function compact() {
        if (state !== "idle") return
        var verbatim = _messages.slice(ctl._summarizedCount)
        if (verbatim.length <= ctl._keepRecent) { ctl.statusText = "Nichts zu kompaktieren."; return }
        // Nach der manuellen Kompaktierung folgt KEIN Turn — daher setzt der cb den
        // (in _summarize auf busy gesetzten) state selbst wieder auf "idle" zurück.
        _summarize(verbatim.length - ctl._keepRecent, function() { ctl.statusText = ""; ctl.state = "idle" })
    }

    function _cleanResponse(text) {
        text = text.replace(/<think>[\s\S]*?<\/think>\s*/g, "")
        text = text.replace(/^<think>[\s\S]*$/, "")
        text = text.replace(/<tool_call>[\s\S]*?<\/tool_call>\s*/g, "")
        text = text.replace(/<function=[\s\S]*?<\/function>\s*/g, "")
        return text.trim()
    }

    // ---- Öffentlicher Einstieg ----
    function send(text, extra) {
        if (busy) return
        _generation++
        _turnId = store.newUuid()
        // WICHTIG: _messages ist KONVERSATIONSWEIT (Kontext über alle Züge) und wird
        // hier NICHT geleert — nur der Pro-Zug-Zustand (Task 3: _loopCache/_catPolicy/
        // _queue) wird zurückgesetzt. Zurückgesetzt wird _messages nur in
        // newConversation()/loadConversation() (Task 5).
        // User-Nachricht: ListModel + Verlauf + DB
        var imgPath = (extra && extra.imagePath) ? extra.imagePath : ""
        _appendRow({ text: (extra && extra.displayText) ? extra.displayText : text,
                     isUser: true, ts: _nowTs(), mediaPath: imgPath,
                     mediaType: imgPath ? "image" : "" })
        var userIdx = chatModel.count - 1
        var userHist = { "role": "user", "content": text }
        if (extra && extra.images) userHist.images = extra.images
        _messages.push(userHist)
        var userMsg = { "role": "user", "content": text }
        if (imgPath) userMsg.extra = { "attachments": [ { "path": imgPath, "mime": "" } ] }
        var uid = _persist(userMsg)
        chatModel.setProperty(userIdx, "msgId", uid)      // regenerate braucht die msgId
        userHist._msgId = uid                             // dito am _messages-Eintrag
        _maybeSetTitle(text)
        // Pro-Zug-Zustand der Tool-Schleife zurücksetzen (Task 3) — _messages bleibt unberührt.
        // _memoryCache: memory.md wird pro ZUG einmal frisch gelesen (Audit-Fix perf,
        // s. _systemPrompt) — die Invalidierung hier ist der Zug-Einstieg.
        _loopCache = ({}); _catPolicy.reset(); _queue = []; _queuePos = 0
        _memoryCache = null
        _ragSources = []
        // Vor dem Zug ggf. den Kontext kompaktieren, dann Wissensbasis-Retrieval
        // (beides best-effort, ruft cb immer). Embed-Text = die getippte Frage
        // (displayText), nicht der API-Inhalt mit Anhang-Dump/Such-Hinweis.
        _maybeCompact(function() {
            _retrieve((extra && extra.displayText) ? extra.displayText : text,
                      function() { _startTurn() })
        })
    }

    function _maybeSetTitle(content) {
        // Titel = erste User-Nachricht der Konversation. _messages ist gerade um die
        // neue User-Nachricht gewachsen; ist sie das einzige Element, ist die
        // Konversation neu (in-memory geprüft — kein async DB-Read-Race).
        if (_messages.length !== 1) return
        var title = content.substring(0, 50)
        if (content.length > 50) title += "..."
        store.touchConversation(_ensureConversation(), title)
    }

    // Startet eine Streaming-Runde (mit Tools, wenn Capability). round=0 initial.
    property int _round: 0
    function _startTurn() {
        _round = 0
        _stream(true)
    }

    // Wissensbasis Scheibe C: Frage einbetten, ähnliche Einträge suchen und für den
    // System-Prompt bereithalten. Best-effort: jeder Guard/Fehler/Timeout endet in
    // cb() ohne Treffer — der Chat läuft immer weiter. Feature-detektiert (schlanke
    // Test-Mocks ohne searchSimilar/embedFn überspringen still).
    function _retrieve(text, cb) {
        _ragSources = []
        if (ctl.settings && ctl.settings.ragEnabled === false) { cb(); return }
        if (!ctl.embedFn || !ctl.store || typeof ctl.store.searchSimilar !== "function") { cb(); return }
        var q = (text || "").trim()
        if (q.length < 3) { cb(); return }
        if (q.length > 2000) q = q.substring(0, 2000)
        var gen = _generation
        var done = false
        // LOKALE Closure (nicht über die Property aufrufen): ein verspäteter
        // Embed-Callback eines ÄLTEREN Zuges darf das Finish eines neueren
        // Retrievals nie kapern (Szenario send → stop → send: A's Callback träfe
        // sonst B's Closure über ctl._ragFinish und injizierte A's Treffer).
        var finish = function(hits) {
            if (done) return
            done = true
            ctl._ragTimer.stop()
            // stop()/Konversationswechsel hat die Epoche gekippt und state bereits
            // zurückgesetzt — cb NICHT mehr rufen (kein _startTurn hinterher).
            if (gen !== _generation) return
            ctl._ragSources = hits || []
            cb()
        }
        ctl._ragFinish = finish          // nur für den Timeout-Pfad (_onRagTimeout)
        // busy-Gate gegen Doppel-Send und stop()-Erreichbarkeit während der Suche.
        state = "streaming"
        statusText = "Wissensbasis wird durchsucht …"
        ctl._ragTimer.start()
        try {
            ctl.embedFn(q, function(r) {
                // verworfener Zug (gen gekippt) ODER Timeout längst gefinished:
                // gar nicht erst arbeiten (kein searchSimilar, kein Finish).
                if (done || gen !== _generation) return
                if (!r || !r.vec || r.vec.length === 0) { finish([]); return }
                var hits = []
                try {
                    var topK = (ctl.settings && ctl.settings.ragTopK > 0) ? ctl.settings.ragTopK : 3
                    // 0.0 ist ein legaler Schwellwert („alles akzeptieren") — nur
                    // NaN/außerhalb 0..1 fällt auf den Default zurück.
                    var t = ctl.settings ? ctl.settings.ragThreshold : 0.75
                    var threshold = (t >= 0 && t <= 1) ? t : 0.75
                    // Brute-Force-Cosinus synchron auf dem GUI-Thread: bei der
                    // Größenordnung einer persönlichen Wissensbasis (hunderte
                    // Vektoren) vernachlässigbar — skaliert linear mit der KB.
                    hits = ctl.store.searchSimilar(r.vec, r.model, topK, threshold) || []
                } catch (e) { hits = [] }
                finish(hits)
            })
        } catch (e) { finish([]) }
    }

    function _onRagTimeout() {
        if (ctl._ragFinish) ctl._ragFinish([])
    }

    // Attribution: schlanke Quellen-Liste {source,id,label,score} für Rolle/Persistenz.
    function _slimRagSources() {
        var slim = []
        for (var i = 0; i < ctl._ragSources.length; i++) {
            var k = ctl._ragSources[i]
            // Fallbacks: bewertete Zeile ohne vorherige User-Nachricht hat keine
            // Frage (leeres Label würde einen leeren Chip erzeugen).
            var label = (k.source === "rated") ? (k.question || k.answer || "Quelle")
                                               : (k.title || k.url || k.content || "Eintrag")
            if (label.length > 60) label = label.substring(0, 59) + "…"
            slim.push({ "source": k.source, "id": k.id, "label": label, "score": k.score })
        }
        return slim
    }

    // Entfernt eine Quelle aus der sichtbaren Attribution einer Bubble UND aus dem
    // persistierten extra.ragSources der Zeile (sofortiges UI-Feedback, nachdem die
    // Quelle aus der Wissensbasis gelöscht wurde). Achtung: updateMessage ersetzt
    // extra atomar — Assistant-Zeilen tragen heute keine anderen extra-Keys.
    function stripRagSource(rowMsgId, sourceId) {
        var slim = ctl._ragByMsgId[rowMsgId]
        if (!slim) return
        var filtered = []
        for (var i = 0; i < slim.length; i++) {
            if (slim[i].id !== sourceId) filtered.push(slim[i])
        }
        if (filtered.length === slim.length) return
        if (filtered.length > 0) ctl._ragByMsgId[rowMsgId] = filtered
        else delete ctl._ragByMsgId[rowMsgId]
        for (var r = 0; r < chatModel.count; r++) {
            if (chatModel.get(r).msgId === rowMsgId) {
                chatModel.setProperty(r, "ragSources", JSON.stringify(filtered))
                break
            }
        }
        store.updateMessage(rowMsgId, { "extra": filtered.length > 0 ? { "ragSources": filtered } : ({}) })
    }

    function _stream(withTools) {
        _content = ""; _thinking = ""
        state = "streaming"
        statusText = ctl.thinkingEnabled ? "Aurora denkt nach…" : "Aurora antwortet…"
        // Assistant-Platzhalter
        _appendRow({ isUser: false, streaming: true, ts: _nowTs() })
        _streamIndex = chatModel.count - 1

        var gen = _generation
        var caps = ctl.activeCaps || []
        var req = { "model": ctl.activeModel, "messages": _buildMessages(), "keepAlive": "10m" }
        if (withTools && caps.indexOf("tools") !== -1) req.tools = ctl.registry.definitions(_buildCtx())
        if (caps.indexOf("thinking") !== -1) req.think = ctl.thinkingEnabled
        req.options = ctl.settings ? ctl.settings.paramsFor(ctl.activeModel) : ({})

        var job = ctl.chatFn(req)
        _activeJob = job
        job.token.connect(function(t) {
            if (gen !== ctl._generation) return
            ctl._content += t
            if (ctl._streamIndex >= 0 && ctl._streamIndex < ctl.chatModel.count)
                ctl.chatModel.setProperty(ctl._streamIndex, "text", ctl._content)
        })
        job.thinking.connect(function(t) {
            if (gen !== ctl._generation) return
            ctl._thinking += t
            if (ctl._streamIndex >= 0 && ctl._streamIndex < ctl.chatModel.count)
                ctl.chatModel.setProperty(ctl._streamIndex, "thinking", ctl._thinking)
        })
        job.done.connect(function(result) {
            if (ctl._activeJob === job) ctl._activeJob = null
            job.destroy()
            if (gen !== ctl._generation) return
            ctl._onStreamDone(result)
        })
        job.error.connect(function(message) {
            if (ctl._activeJob === job) ctl._activeJob = null
            job.destroy()
            if (gen !== ctl._generation) return
            if (ctl._content === "" && ctl._thinking === "")
                ctl._content = (message === "timeout")
                    ? "(Zeitüberschreitung: keine Antwort vom Server)" : "(Fehler: " + message + ")"
            ctl._finalizeAssistant("error")
        })
    }

    // --- Tool-Schleife (Task 3) ---
    property var _catPolicy: CategoryPolicy {}
    property var _loopCache: ({})      // key -> result (pro Zug)
    property var _queue: []            // offene Calls der aktuellen Runde
    property int _queuePos: 0

    function _onStreamDone(result) {
        // Harte Obergrenze (Audit ChatController.qml:390): toolMaxRounds steuerte
        // bisher nur, ob Tools ANGEBOTEN werden (req.tools in _stream) — nicht, ob
        // die Schleife weiterläuft. Hält sich das Backend nicht daran und liefert
        // tool_calls auch auf die tools-lose Folge-Anfrage (_afterRound-Else-Zweig),
        // würde _round ohne diese Prüfung unbegrenzt weiterklettern (erneute
        // Ausführung, wiederholte „Rundenlimit"-Notiz, State klemmt in toolRunning).
        // Ab _round >= maxR werden etwaige tool_calls ignoriert — weder ausgeführt
        // noch neu angeboten — und der Zug endet deterministisch über den normalen
        // Abschluss-Pfad unten (_finalizeAssistant("final")).
        var maxR = (ctl.settings && ctl.settings.toolMaxRounds) ? ctl.settings.toolMaxRounds : 5
        if (result.toolCalls && result.toolCalls.length > 0 && _round < maxR) {
            // Assistant-Zwischenantwort (mit Calls) in Kontext + DB
            _content = _cleanResponse(_content)
            var aid = _persist({ "role": "assistant", "content": _content, "thinking": _thinking,
                       "model": ctl.activeModel, "backend": ctl.isRemote ? "remote" : "local",
                       "status": "final" })
            if (_streamIndex >= 0 && _streamIndex < chatModel.count) {
                chatModel.setProperty(_streamIndex, "streaming", false)
                chatModel.setProperty(_streamIndex, "text", _content)
                chatModel.setProperty(_streamIndex, "thinking", _thinking)
                chatModel.setProperty(_streamIndex, "msgId", aid)
            }
            _messages.push({ "role": "assistant", "content": _content, "tool_calls": result.toolCalls, "_msgId": aid })
            _toolBubbleIndex = _streamIndex          // VOR _streamIndex = -1
            _streamIndex = -1
            _round++
            _queue = result.toolCalls.slice()
            _queuePos = 0
            _activity = []
            for (var k = 0; k < _queue.length; k++) {
                var c0 = _queue[k]["function"]
                _activity.push({ "name": c0.name, "describe": ctl.registry.describe(c0.name, c0.arguments || {}),
                                 "status": "pending", "durationMs": 0 })
            }
            _writeActivity()
            state = "toolRunning"
            _runNextCall()
            return
        }
        _finalizeAssistant("final")
    }

    function _normArgs(args) { try { return JSON.stringify(args || {}) } catch (e) { return "" } }

    function _writeActivity() {
        if (_toolBubbleIndex >= 0 && _toolBubbleIndex < chatModel.count)
            chatModel.setProperty(_toolBubbleIndex, "toolActivity", JSON.stringify(_activity))
    }
    function _setActivityStatus(status) {
        if (_queuePos < _activity.length) {
            _activity[_queuePos].status = status
            _writeActivity()
        }
    }

    property var _pending: null       // { name, args, key, description }

    function _decide(name) {
        var perm = ctl.registry.permissionFor(name)
        if (perm === "off") return "disabled"
        var cat = ctl.registry.categoryOf ? ctl.registry.categoryOf(name) : "local"
        var escalate = ctl._catPolicy.needsEscalation(cat)
        var granted = ctl.grants ? ctl.grants.hasGrant(ctl.conversationId, name) : false
        // Audit-Fix (Klein/null-safety): resolver wie grants guarden — ohne
        // injizierten Resolver warf dieser Handler einen TypeError und der State
        // klemmte in toolRunning. Definiertes Verhalten: konservativ "confirm"
        // (off ist oben bereits abgefangen) — ohne Resolver laeuft KEIN Tool
        // still durch, der Nutzer entscheidet explizit.
        if (!ctl.resolver || typeof ctl.resolver.decide !== "function") return "confirm"
        var d = ctl.resolver.decide(perm, { granted: granted, escalate: escalate })
        return d   // "allow" | "confirm" | "disabled"
    }

    function _runNextCall() {
        if (_queuePos >= _queue.length) { _afterRound(); return }
        var call = _queue[_queuePos]
        var name = call["function"].name
        var args = call["function"].arguments || {}
        var maxR = (ctl.settings && ctl.settings.toolMaxRounds) ? ctl.settings.toolMaxRounds : 5
        statusText = "Runde " + _round + "/" + maxR + " — führe " + name + " aus…"
        if (ctl.registry.permissionFor(name) === "off") {
            _feedResult(name, "Tool '" + name + "' ist deaktiviert.", "denied", null); return
        }
        var key = name + "|" + _normArgs(args)
        if (_loopCache[key] !== undefined) { _feedResult(name, _loopCache[key], "ok", key); return }
        var d = _decide(name)
        if (d === "disabled") { _feedResult(name, "Tool '" + name + "' ist deaktiviert.", "denied", null); return }
        if (d === "confirm") {
            _pending = { "name": name, "args": args, "key": key,
                         "description": ctl.registry.describe(name, args) }
            _setActivityStatus("pending")
            state = "toolPending"
            return
        }
        _setActivityStatus("running")
        _callStart[key] = Date.now()
        _execute(name, args, key)
    }

    function confirmOnce() { _resolvePending(false) }
    function confirmForConversation() { _resolvePending(true) }
    function reject() {
        if (!_pending) return
        var p = _pending; _pending = null
        _setActivityStatus("denied")
        _feedResult(p.name, "Der Nutzer hat die Ausführung von " + p.name + " abgelehnt.", "denied", null)
    }
    function _resolvePending(forConversation) {
        if (!_pending) return
        var p = _pending; _pending = null
        if (forConversation && ctl.grants) ctl.grants.grant(ctl.conversationId, p.name)
        ctl._catPolicy.confirmSwitch()      // jedes Ja bestätigt den Kategorie-Wechsel für den Rest des Zuges
        _setActivityStatus("running")
        _callStart[p.key] = Date.now()
        _execute(p.name, p.args, p.key)
    }

    function _execute(name, args, key) {
        state = "toolRunning"
        var gen = _generation
        ctl.registry.execute(name, args, _buildCtx(), function(text, extra) {
            if (gen !== ctl._generation) return
            var st = (extra && extra.status) ? extra.status : "ok"
            if (_queuePos < _activity.length) {
                _activity[_queuePos].status = (st === "ok") ? "done" : "error"
                _activity[_queuePos].durationMs = Date.now() - (_callStart[key] || Date.now())
            }
            _writeActivity()
            if (st === "ok" && key) _loopCache[key] = text
            // zustandsverändernde Tools: Loop-Cache leeren (verifizierende reads sollen frisch lesen)
            if (name === "write_file" || name === "run_command") _loopCache = ({})
            // noteResult NUR hier (Audit-Fix Klein/ux): das Tool lief tatsaechlich —
            // bei Erfolg UND error. Nicht-ausgefuehrte Tools (denied/off, s.
            // _feedResult) duerfen die Kategorie-Policy nicht fuettern, sonst
            // eskaliert das naechste Tool der anderen Kategorie grundlos.
            var cat = ctl.registry.categoryOf ? ctl.registry.categoryOf(name) : "local"
            ctl._catPolicy.noteResult(cat)
            ctl._pushToolMessage(name, text)
            ctl._queuePos++
            ctl._runNextCall()
        })
    }

    function _feedResult(name, text, status, key) {
        if (status === "ok" && key) _loopCache[key] = text
        if (_queuePos < _activity.length) {
            _activity[_queuePos].status = (status === "ok") ? "done" : status
            _writeActivity()
        }
        // Audit-Fix (Klein/ux): hier KEIN _catPolicy.noteResult — _feedResult
        // laeuft nur fuer NICHT ausgefuehrte Tools (off/disabled/denied) und
        // Loop-Cache-Treffer (deren erster Lauf bereits in _execute notiert hat).
        _pushToolMessage(name, text)
        _queuePos++
        _runNextCall()
    }

    function _pushToolMessage(name, text) {
        // toolName als Top-Level-Feld -> ConversationStore füllt die dedizierte
        // messages.tool_name-Spalte (bindet ausschließlich aus a.value("toolName")).
        // _msgId am _messages-Eintrag mitführen, damit regenerate die DB-Row löschen kann.
        var tid = _persist({ "role": "tool", "content": text, "toolName": name,
                             "status": "final", "model": ctl.activeModel,
                             "backend": ctl.isRemote ? "remote" : "local" })
        _messages.push({ "role": "tool", "tool_name": name, "content": text, "_msgId": tid })
    }

    function _afterRound() {
        var maxR = (ctl.settings && ctl.settings.toolMaxRounds) ? ctl.settings.toolMaxRounds : 5
        if (_round < maxR) {
            _stream(true)
        } else {
            // Limit erreicht: Hinweis ans letzte Tool-Result, Folge-Request OHNE tools
            _messages.push({ "role": "tool", "tool_name": "system",
                             "content": "Rundenlimit erreicht — antworte jetzt mit dem Gesammelten." })
            _stream(false)
        }
    }

    function _finalizeAssistant(status) {
        _content = _cleanResponse(_content)
        // Attribution (Scheibe C): nur an echte Antworten; slim = {source,id,label,score}.
        var ragSlim = (status === "final" && ctl._ragSources.length > 0) ? _slimRagSources() : []
        var msg = { "role": "assistant", "content": _content, "thinking": _thinking,
                    "model": ctl.activeModel, "backend": ctl.isRemote ? "remote" : "local",
                    "status": status }
        if (ragSlim.length > 0) msg.extra = { "ragSources": ragSlim }
        var aid = _persist(msg)
        if (_streamIndex >= 0 && _streamIndex < chatModel.count) {
            chatModel.setProperty(_streamIndex, "streaming", false)
            chatModel.setProperty(_streamIndex, "text", _content)
            chatModel.setProperty(_streamIndex, "thinking", _thinking)
            chatModel.setProperty(_streamIndex, "status", status)
            chatModel.setProperty(_streamIndex, "msgId", aid)   // regenerate braucht die msgId
            if (ragSlim.length > 0) {
                _ragByMsgId[aid] = ragSlim
                chatModel.setProperty(_streamIndex, "ragSources", JSON.stringify(ragSlim))
            }
        }
        _messages.push({ "role": "assistant", "content": _content, "_msgId": aid })
        _streamIndex = -1
        if (status === "final")
            assistantFinal(_content)   // nur echte Antworten vorlesen (nicht error/aborted)
        state = "idle"
        statusText = ""
        _toolBubbleIndex = -1
    }

    function stop() {
        if (state === "idle") return
        _generation++
        _ragTimer.stop()          // ein ausstehender Retrieval-Timeout wird zum No-op
        if (_activeJob) { _activeJob.abort(); _activeJob.destroy(); _activeJob = null }
        if (ctl.registry) ctl.registry.abortRunning()
        _queue = []; _queuePos = 0; _pending = null
        statusText = ""
        _activity = []
        if (_streamIndex >= 0 && _streamIndex < chatModel.count) {
            var partial = _content !== "" ? _cleanResponse(_content) : "(Abgebrochen)"
            var aid = _persist({ "role": "assistant", "content": partial, "thinking": _thinking,
                       "model": ctl.activeModel, "backend": ctl.isRemote ? "remote" : "local",
                       "status": "aborted" })
            chatModel.setProperty(_streamIndex, "streaming", false)
            chatModel.setProperty(_streamIndex, "text", partial)
            chatModel.setProperty(_streamIndex, "thinking", _thinking)
            chatModel.setProperty(_streamIndex, "status", "aborted")
            chatModel.setProperty(_streamIndex, "msgId", aid)
            // Abgebrochene Teilantwort bleibt im API-Kontext (main.qml-Parität, Spec §4) —
            // sonst folgen beim nächsten send() zwei user-Turns aufeinander.
            _messages.push({ "role": "assistant", "content": partial, "_msgId": aid })
        }
        _streamIndex = -1
        state = "idle"
    }

    function newConversation() {
        if (state !== "idle") stop()
        chatModel.clear(); _messages = []
        _contextSummary = ""; _summarizedCount = 0
        _ragSources = []; _ragByMsgId = ({})
        conversationId = store.newUuid()
    }

    function regenerate() {
        if (state !== "idle" || _messages.length === 0) return
        // Den GESAMTEN letzten Zug bis einschließlich der letzten user-Nachricht
        // zurücknehmen. Nach einem Tool-Zug ist _messages = [user, asst(tool_calls),
        // tool, asst(final)] — eine feste "letzte zwei"-Annahme wäre falsch.
        var lastUser = null
        // _messages trägt selbst kein imagePath/displayText (die leben nur kurz im
        // extra-Objekt von send() und landen als mediaPath/text in der ListModel-
        // Zeile) — deshalb VOR dem Entfernen der User-Zeile deren Primitive sichern
        // (kein Objekt-Handle behalten: chatModel.get() ist nach remove() nicht
        // mehr garantiert gültig).
        var lastUserMediaPath = ""
        var lastUserDisplayText = ""
        while (_messages.length > 0) {
            var m = _messages.pop()
            if (m._msgId) {
                store.deleteMessage(m._msgId)     // DB-Row (auch tool-Zeilen)
                delete _ragByMsgId[m._msgId]      // Attribution-Cache nicht verwaist lassen
            }
            if (m.role !== "tool" && chatModel.count > 0) {  // tool-Zeilen haben keine Bubble
                if (m.role === "user") {
                    var row = chatModel.get(chatModel.count - 1)
                    lastUserMediaPath = row.mediaPath || ""
                    lastUserDisplayText = row.text || ""
                }
                chatModel.remove(chatModel.count - 1)
            }
            if (m.role === "user") { lastUser = m; break }
        }
        if (!lastUser) return
        // Bild-Kontext (images/imagePath) des Zuges wiederherstellen, sonst wird aus
        // einer Vision-Antwort beim Regenerieren eine unpassende Text-Antwort
        // (Task 10, Fix B). Ohne Bild bleibt extra null (unverändertes Verhalten).
        var extra = null
        if (lastUser.images) {
            // In-Session: die base64-Bytes liegen noch im _messages-Eintrag.
            extra = { displayText: lastUserDisplayText || lastUser.content, images: lastUser.images }
            if (lastUserMediaPath) extra.imagePath = lastUserMediaPath
        } else if (lastUserMediaPath) {
            // Nach Reload trägt _messages KEINE images (base64 wird nie persistiert,
            // CLAUDE.md), aber der Bildpfad ist aus der DB wiederhergestellt. Die Bytes
            // von der Platte nachladen, damit der Regenerate-Request das Bild wirklich
            // trägt. Sonst zeigte die neue User-Bubble ein Thumbnail (imagePath),
            // während der chatFn-Request bildlos wäre — irreführend und schlechter als
            // vor dem Fix. Ist die Datei weg oder FileIO nicht verfügbar, ehrlich als
            // Text-only OHNE Thumbnail regenerieren (extra bleibt null, kein imagePath).
            var b64 = ctl.fileio ? ctl.fileio.readBase64(lastUserMediaPath) : { "ok": false }
            if (b64 && b64.ok)
                extra = { displayText: lastUserDisplayText || lastUser.content,
                          images: [b64.data], imagePath: lastUserMediaPath }
        }
        send(lastUser.content, extra)
    }

    function loadConversation(convId) {
        if (state !== "idle") stop()
        chatModel.clear(); _messages = []
        _ragSources = []; _ragByMsgId = ({})
        var rows = store.messages(convId)
        conversationId = convId
        var hist = []
        for (var i = 0; i < rows.length; i++) {
            var m = rows[i]
            if (m.role !== "user" && m.role !== "assistant") continue
            var imgPath = m.mediaPath || ""
            if (!imgPath && m.extra && m.extra.attachments && m.extra.attachments.length > 0)
                imgPath = m.extra.attachments[0].path
            // Audit-Fix (Klein/ux, bewusste Ausblend-Variante aus dem Audit —
            // toolActivity-Persistenz bleibt Backlog): persistierte assistant-
            // Zwischenzeilen eines Tool-Zuges (tool_calls, leerer content) nach
            // dem Reload NICHT als leere Ghost-Bubbles zeigen — weder Bubble noch
            // _messages-Eintrag. Der Tool-Zug-Kontext entsteht beim Reload
            // ohnehin nicht (tool-Zeilen werden oben bereits gefiltert).
            // assistant-Zeilen MIT mediaPath (generierte Bilder) bleiben.
            if (m.role === "assistant" && !m.content && imgPath === "") continue
            // Attribution (Scheibe C) aus extra.ragSources restaurieren — mit
            // Shape-Guard (handeditierte/ältere DBs: String/Map statt Liste).
            var _ragRaw = (m.extra && m.extra.ragSources) ? m.extra.ragSources : []
            var rag = (_ragRaw.length > 0 && typeof _ragRaw[0] === "object") ? _ragRaw : []
            if (rag.length > 0) _ragByMsgId[m.id] = rag
            hist.push({ "role": m.role, "content": m.content, "_msgId": m.id })
            _appendRow({ msgId: m.id, text: m.content, isUser: m.role === "user",
                         thinking: m.thinking || "", status: m.status || "",
                         ts: Qt.formatTime(new Date(m.createdAt), "hh:mm"),
                         mediaPath: imgPath, mediaType: imgPath ? "image" : "",
                         rating: m.rating || 0,
                         ragSources: rag.length > 0 ? JSON.stringify(rag) : "[]" })
        }
        _messages = hist
        // Kompaktierungs-Zustand aus conversations.extra wiederherstellen (Anker: msgId).
        _contextSummary = ""; _summarizedCount = 0
        var conv = store.conversation(convId)
        if (conv && conv.extra && conv.extra.contextSummary) {
            var anchor = conv.extra.contextSummaryThroughMsgId || ""
            var idx = -1
            for (var j = 0; j < _messages.length; j++) {
                if (_messages[j]._msgId === anchor) { idx = j; break }
            }
            if (idx >= 0) { _contextSummary = conv.extra.contextSummary; _summarizedCount = idx + 1 }
        }
    }

    // Exportiert die aktuelle Konversation als Markdown nach ~/.local/share/aurora/exports/.
    // Liefert {ok, path} oder {ok:false, error}. Best-effort, blockiert nichts.
    function exportConversation() {
        var rows = store.messages(conversationId)
        var hasContent = false
        for (var i = 0; i < rows.length; i++) {
            if (rows[i].role === "user" || rows[i].role === "assistant") { hasContent = true; break }
        }
        if (!hasContent) return { "ok": false, "error": "leer" }
        if (!ctl.fileio) return { "ok": false, "error": "FileIO nicht verfügbar" }
        var conv = store.conversation(conversationId)
        var title = (conv && conv.title) ? conv.title : ""
        var ts = Qt.formatDateTime(new Date(), "yyyyMMdd-hhmmss")
        var md = ConversationExport.toMarkdown(rows, {
            title: title !== "" ? title : "Aurora-Konversation",
            model: ctl.activeModel,
            exportedAt: Qt.formatDateTime(new Date(), "dddd, d. MMMM yyyy, HH:mm")
        })
        var dir = ctl.fileio.standardPath("appData") + "/exports"
        ctl.fileio.mkpath(dir)
        var path = dir + "/" + ConversationExport.filename(title, ts)
        var r = ctl.fileio.writeText(path, md)
        return (r && r.ok) ? { "ok": true, "path": path }
                           : { "ok": false, "error": (r && r.error) ? r.error : "Schreibfehler" }
    }

    // Rendert ein generiertes Bild als sichtbare Chat-Zeile UND persistiert es —
    // für beide Wege (manueller ImagePanel-Weg und generate_image-Tool). Der
    // toolInitiated-Flag (vom AuroraController-Handler durchgereicht) steuert nur,
    // ob zusätzlich ein assistant-Eintrag in die API-History (_messages) geschoben
    // wird: Beim Tool-Weg wird das UNTERDRÜCKT, weil das Bild MITTEN in einer
    // laufenden Tool-Runde eintrifft — ein assistant-Eintrag zwischen
    // assistant(tool_calls) und dem tool-Ergebnis würde die Reihenfolge zerreißen.
    // Das Tool trägt sein Ergebnis separat über _pushToolMessage in _messages; das
    // Bild bleibt sichtbar (Chat-Zeile) und persistiert (DB-Zeile, erscheint beim
    // Reload). Beim manuellen Weg (kein Tool-Loop) gehört das Bild sehr wohl in die
    // History. Default (Flag undefined, z. B. 2-Argument-Aufrufe) = manuell.
    function appendGeneratedImage(path, prompt, toolInitiated) {
        _appendRow({ isUser: false, ts: _nowTs(), mediaPath: path, mediaType: "image",
                     text: "", status: "final" })
        var idx = chatModel.count - 1
        var aid = _persist({ "role": "assistant", "content": "[Bild generiert: " + prompt + "]",
                             "mediaPath": path, "mediaType": "image/png", "status": "final",
                             "model": ctl.activeModel, "backend": ctl.isRemote ? "remote" : "local" })
        chatModel.setProperty(idx, "msgId", aid)
        if (toolInitiated !== true)
            _messages.push({ "role": "assistant", "content": "[Bild generiert: " + prompt + "]", "_msgId": aid })
    }
}
