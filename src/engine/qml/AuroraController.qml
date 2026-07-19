import QtQuick
import QtQuick.Dialogs as Dialogs
import net.niuton.aurora.core
import net.niuton.aurora.engine
import "Commands.js" as Commands

// Geteilter, nicht-visueller Controller — "die App minus Fenster". Kapselt alle
// Logik-Instanzen und die Glue-Logik, die früher in package/contents/ui/main.qml
// lag. Widget UND (ab Stufe 2e) App binden nur noch an controller.*.
QtObject {
    id: controller

    // ==================== Host-gesteuerter Lebenszyklus ====================
    // Der Host bindet `active` an seine Sichtbarkeit (Widget: expanded || isPinned).
    property bool active: false
    // active gated nur Polling (ModelManager.active) + Unload/Aufnahme-Stopp beim Deaktivieren.
    // activate() (Refresh-Kaskade) ruft der Host bei JEDEM expanded->true selbst —
    // so läuft der Refresh auch beim gepinnten Fokus-Bounce (Parität zum alten
    // onExpandedChanged), ohne dass active bei gepinntem Widget je auf false fällt.
    onActiveChanged: {
        if (!active) {
            modelManager.scheduleUnload()
            // Popup geschlossen: laufende Aufnahme/Wiedergabe beenden, sonst
            // nimmt pw-record nach dem Schließen unbegrenzt weiter auf.
            voiceRecorder.stop()
            speaker.stop()
        }
    }

    // ==================== Read-State: Chat ====================
    readonly property var chatModel: engine.chatModel
    readonly property bool busy: engine.busy
    readonly property var pendingTool: engine.pendingTool
    readonly property string conversationId: engine.conversationId

    // Statuszeile: während der Generierung der Chat-Status, sonst der transiente
    // Voice-/Bild-Status. Zeichengenau übernommen aus main.qml (Parität).
    property string _transientStatus: ""
    readonly property string statusText: engine.busy
        ? (engine.statusText || "Aurora antwortet…")
        : _transientStatus

    // ==================== Read-State: Modell ====================
    readonly property string selectedModel: modelManager.selectedModel
    readonly property string activeModel: modelManager.activeModel
    readonly property bool modelLoaded: modelManager.modelLoaded
    readonly property bool modelLoading: modelManager.modelLoading
    readonly property bool isRemoteModel: modelManager.isRemote
    readonly property var modelPickerEntries: modelManager.pickerEntries
    readonly property bool localOk: modelManager.localModels.length > 0
    readonly property bool remoteOk: modelManager.remoteAvailable

    // ==================== Read-State: Slash-Befehle ====================
    readonly property var commandList: Commands.list()
    property string commandNotice: ""      // dezente Ruhezustand-Rückmeldung für /-Befehle

    // ==================== Read-State: Fähigkeiten / Comfy / Anhang ====================
    readonly property bool ttsAvailable: speaker.available
    readonly property bool voiceAvailable: voiceRecorder.available
    readonly property var voiceState: voiceRecorder.recState
    readonly property bool comfyAvailable: comfyClient.available
    readonly property bool comfyBusy: comfyClient.busy
    readonly property string comfyStatus: comfyClient.statusText
    readonly property var comfyModels: comfyClient.models
    readonly property string comfyDefaultModel: settings.comfyDefaultModel
    readonly property bool autoSpeak: settings.ttsAutoSpeak

    // Attachment (nur controller-intern beschrieben; Host liest attachedFileName).
    property string attachedFileUrl: ""
    property string attachedFileName: ""

    // ==================== Read-Write: UI/Feature-State ====================
    property bool thinkingEnabled: false
    property bool imageMode: false

    // ==================== Konversationsliste (Sidebar-Modell) ====================
    property var conversationList: []
    // Treffer der Konversations-Suche (FTS5 über Titel+Inhalte; Einträge wie
    // conversationList + snippet). Leer, wenn kein aktiver Suchtext (>= 2 Zeichen).
    property var searchResults: []

    // ==================== Wissensbasis (bewertete Antworten + manuelle Einträge) ====================
    property var goodExamples: []
    property var manualEntries: []
    property bool knowledgeOpen: false

    // ==================== Signale ====================
    // Der Host verdrahtet dies auf chatView.insertTranscript() (Parent->Child).
    signal transcriptReady(string text)

    // ==================== Interne Instanzen ====================
    property AuroraSettings _settings: AuroraSettings { id: settings }

    property ModelManager _mm: ModelManager {
        id: modelManager
        settings: settings
        active: controller.active
    }

    property ToolRegistry _reg: ToolRegistry { id: toolRegistry; settings: settings }

    property AuroraEngine _engine: AuroraEngine {
        id: engine
        modelManager: modelManager
        store: ConversationStore
        settings: settings
        registry: toolRegistry
        comfy: comfyClient
        homeDir: FileIO.standardPath("home")
        thinkingEnabled: controller.thinkingEnabled
        chatFn: function(req) { return modelManager.chat(req) }
        embedFn: function(input, cb) {
            var m = settings.embedModel
            modelManager.embed(m, input, function(vec) {
                cb(vec ? { "vec": vec, "model": m } : null)
            })
        }
    }

    property VoiceRecorder _vr: VoiceRecorder {
        id: voiceRecorder
        language: settings.sttLanguage
        preferredSource: settings.sttSource
        onTranscriptReady: function(text) {
            controller._transientStatus = ""
            controller.transcriptReady(text)
        }
        onErrorOccurred: function(message) {
            controller._transientStatus = "Spracheingabe: " + message
            voiceStatusTimer.restart()
        }
    }

    // Sprach-/Bild-Status blendet sich nach kurzer Zeit selbst aus, sonst bliebe
    // die Fehlermeldung dauerhaft stehen.
    property Timer _voiceTimer: Timer {
        id: voiceStatusTimer
        interval: 6000
        onTriggered: if (!controller.busy) controller._transientStatus = ""
    }

    // Rückmeldung für /-Befehle (z. B. "Unbekannter Befehl") blendet sich nach
    // kurzer Zeit selbst aus. Wie bei den anderen Kind-Objekten (QtObject hat kein
    // default property) über eine Property angehängt.
    property Timer _cmdNoticeTimer: Timer { id: _noticeTimer; interval: 5000; onTriggered: controller.commandNotice = "" }

    property Speaker _sp: Speaker {
        id: speaker
        voice: settings.ttsVoice
        onErrorOccurred: function(message) {
            controller._transientStatus = "Sprachausgabe: " + message
            voiceStatusTimer.restart()
        }
    }

    property ComfyClient _comfy: ComfyClient {
        id: comfyClient
        endpoint: settings.comfyEnabled ? (settings.comfyEndpoint || "") : ""
        // Dieser Handler rendert BEIDE Wege ins Chat-Modell (Tool-Weg wie manueller
        // ImagePanel-Weg — appendGeneratedImage ist die EINZIGE Funktion, die eine
        // bild-tragende Chat-Zeile erzeugt). Task 4, zwei Aspekte:
        // 1) Einheitlicher conversationId-Guard über BEIDE Wege: nur anhängen, wenn
        //    die Konversation seit dem Start der Generierung (comfyClient.originConvId,
        //    von beiden Aufrufern gesetzt) unverändert ist — sonst verwerfen, statt
        //    das Bild bei Wechsel/„Neuer Chat" in die falsche Konversation zu schreiben.
        // 2) Der toolInitiated-Flag wird an appendGeneratedImage durchgereicht:
        //    tool-initiierte Bilder erscheinen sichtbar + werden persistiert, aber
        //    NICHT als assistant-Zeile in die API-History (_messages) eingefügt —
        //    sonst rutschte eine assistant-Zeile zwischen assistant(tool_calls) und
        //    das tool-Ergebnis (History zerrissen). Das Tool trägt sein Ergebnis
        //    separat über _pushToolMessage in _messages.
        onFinished: function(imagePath, promptText) {
            if (engine.conversationId !== comfyClient.originConvId) return
            engine.appendGeneratedImage(imagePath, promptText, comfyClient.toolInitiated)
        }
        onFailed: function(message) {
            // Ein fehlgeschlagener TOOL-Lauf meldet seinen Fehler selbst (über das
            // Tool-Ergebnis im Chat) — hier keine zusätzliche transiente Statuszeile.
            if (comfyClient.toolInitiated) return
            controller._transientStatus = "Bild: " + message
        }
    }

    // Zentraler Refresh nach Writes — die EINZIGE Refresh-Quelle, weil synchrone
    // Reads direkt nach einem asynchronen Write den alten Stand sähen.
    property Connections _storeConn: Connections {
        target: ConversationStore
        function onWriteCompleted(op) {
            if (op === "appendMessage" || op === "touchConversation" || op === "deleteConversation")
                controller.refreshConversationList()
            if (controller.knowledgeOpen && (op === "updateMessage" || op === "setEmbedding"))
                controller.refreshGoodExamples()
            if (controller.knowledgeOpen && (op === "addKnowledge" || op === "updateKnowledge"
                    || op === "setKnowledgeEmbedding" || op === "deleteKnowledge"))
                controller.refreshManualEntries()
        }
        function onWriteFailed(op, error) {
            console.warn("Aurora: DB-Schreibfehler", op, error)
        }
        function onReadFailed(op, error) {
            console.warn("Aurora: DB-Lesefehler", op, error)
            // Sichtbar statt stiller Leere (Audit): korrupte/gesperrte DB wirkt
            // sonst wie „keine Daten" — der Nutzer glaubt an Datenverlust.
            controller._transientStatus = "Datenbank-Lesefehler (" + op + ")"
            voiceStatusTimer.restart()
        }
    }

    // Auto-Vorlesen: eine fertige Assistenten-Antwort bei aktivem Toggle vorlesen.
    property Connections _speakConn: Connections {
        target: engine
        function onAssistantFinal(text) { if (controller.autoSpeak) controller.speak(text) }
    }

    property QtObject _fileDialog: Dialogs.FileDialog {
        id: fileDialog
        title: "Datei anhängen"
        onAccepted: {
            controller.attachedFileUrl = selectedFile
            var path = selectedFile.toString()
            controller.attachedFileName = path.substring(path.lastIndexOf("/") + 1)
        }
    }

    // ==================== Lifecycle-Methoden ====================
    function open() {
        var st = ConversationStore.open()
        if (!st.ok) console.warn("Aurora: Konversations-DB nicht verfügbar:", st.error)
    }

    function activate() {
        modelManager.refresh()
        voiceRecorder.checkAvailability()
        speaker.checkAvailability()
        comfyClient.checkAvailability()
        refreshConversationList()
        // Immer die letzte Konversation zeigen, statt eine neue anzulegen.
        if (engine.conversationId === "" && engine.chatModel.count === 0) {
            var latest = ConversationStore.latestConversationId()
            if (latest !== "") engine.loadConversation(latest)
            else engine.newConversation()
        }
    }

    // ==================== Chat-Methoden ====================
    // Nur als Slash-Befehl behandeln, wenn der erste Token ein Befehlsname sein
    // KANN (reine Buchstaben). "/etc/fstab …", "/home/…", "/tmp x" sind Pfad/Prosa
    // und müssen ans Modell, nicht verschluckt werden.
    function _looksLikeCommand(text) {
        if (!text || String(text).charAt(0) !== "/") return false
        var body = String(text).substring(1)
        var sp = body.indexOf(" ")
        var name = sp === -1 ? body : body.substring(0, sp)
        return /^[a-zA-Z]+$/.test(name)
    }

    // Caps-Priming: direkt nach einem Modellwechsel sind die /api/show-Caps evtl.
    // noch nicht da — frisch holen (withActiveCaps), dann über die Fassade senden.
    function sendMessage(text) {
        if (_looksLikeCommand(text)) {
            var _cmd = Commands.parse(text)
            if (_cmd) {
                // Ein Befehl konsumiert die aktuelle Eingabe, aber NICHT als
                // Anhang-tragende Nachricht — sonst reitet ein evtl. gesetzter
                // Anhang still auf der nächsten echten Nachricht mit (Task 10, Fix A).
                attachedFileUrl = ""; attachedFileName = ""
                runCommand(_cmd.name, _cmd.arg)
                return
            }
        }
        if (attachedFileUrl !== "") {
            var pathStr = FileIO.urlToPath(attachedFileUrl.toString())
            var name = attachedFileName
            var isImage = /\.(png|jpe?g|webp|bmp)$/i.test(pathStr)
            attachedFileUrl = ""; attachedFileName = ""
            if (isImage) {
                // Vision-Fähigkeit auf FRISCH geholten Caps entscheiden (Callback-Argument),
                // nicht auf evtl. veraltetem modelManager.activeCaps — direkt nach einem
                // Modellwechsel sind die /api/show-Caps sonst noch die des alten Modells.
                modelManager.withActiveCaps(function(caps) {
                    if (caps.indexOf("vision") === -1) {
                        engine.send(text + "\n\n(Hinweis: Bild '" + name + "' angehängt, aber das aktive Modell unterstützt keine Bildeingabe.)",
                                    { displayText: text + "  📎 " + name })
                        return
                    }
                    var b64 = FileIO.readBase64(pathStr)
                    if (!b64.ok) {
                        engine.send(text, null)
                        return
                    }
                    engine.send(text, { images: [b64.data], imagePath: pathStr, displayText: text })
                })
            } else {
                var fc = FileIO.readText(pathStr, 65536)
                var full = text + "\n\n--- Anhang: " + name + " ---\n" + (fc.ok ? fc.text : "(Datei konnte nicht gelesen werden)") + "\n--- Ende ---"
                modelManager.withActiveCaps(function() {
                    engine.send(full, { displayText: text + "  📎 " + name })
                })
            }
        } else {
            modelManager.withActiveCaps(function() { engine.send(text, null) })
        }
    }

    function _notify(text) { commandNotice = text; _noticeTimer.restart() }

    // Gleicht arg gegen die verfügbaren Modelle ab -> liefert den selectModel-Wert
    // (z. B. "local:gemma4:e4b") oder "" bei keinem Treffer. Popup fügt bereits den
    // exakten value ein; manuell getippte Namen werden gegen den Namensteil geprüft.
    function _matchModel(arg) {
        if (arg === "") return ""
        var entries = modelPickerEntries || []
        var a = arg.toLowerCase()
        for (var i = 0; i < entries.length; i++) {
            var e = entries[i]
            if (e.kind === "header" || e.enabled === false) continue
            if (String(e.value).toLowerCase() === a) return e.value          // exakter value (Popup)
        }
        // 2a: exakter Namensteil-Treffer (gewinnt vor einer Präfix-Kollision, z. B.
        // /model qwen3.5:9b vs. remote:qwen3.5:9b-q8_0 bei unsortierter Liste)
        for (var j = 0; j < entries.length; j++) {
            var e2 = entries[j]
            if (e2.kind === "header" || e2.enabled === false) continue
            if (String(e2.value).replace(/^(local|remote):/, "").toLowerCase() === a) return e2.value
        }
        // 2b: Präfix-Treffer (erst wenn kein exakter Namensteil gefunden wurde)
        for (var k = 0; k < entries.length; k++) {
            var e3 = entries[k]
            if (e3.kind === "header" || e3.enabled === false) continue
            if (String(e3.value).replace(/^(local|remote):/, "").toLowerCase().indexOf(a) === 0) return e3.value
        }
        return ""
    }

    function runCommand(name, arg) {
        var def = Commands.find(name)
        if (!def) { _notify("Unbekannter Befehl: /" + name + " — /help"); return }
        switch (name) {
        case "help":
            var names = []
            var l = Commands.list()
            for (var i = 0; i < l.length; i++) names.push("/" + l[i].name)
            _notify("Befehle: " + names.join("  "))
            break
        case "compact": engine.compact(); break
        case "new": newConversation(); break
        case "image": setImageMode(true); break
        case "memory": openMemory(); break
        case "knowledge": openKnowledge(); break
        case "export":
            var _ex = engine.exportConversation()
            _notify(_ex.ok ? "Exportiert nach " + _ex.path
                           : (_ex.error === "leer" ? "Export: nichts zu exportieren"
                                                   : "Export fehlgeschlagen: " + (_ex.error || "")))
            break
        case "search":
            if (arg === "") { _notify("Suchbegriff fehlt: /search <text>"); break }
            searchAndSend(arg); break
        case "model":
            if (arg === "") { _notify("Modell fehlt: /model <name>"); break }
            var val = _matchModel(arg)
            if (val === "") { _notify("Modell nicht gefunden: " + arg); break }
            selectModel(val); break
        }
    }

    function searchAndSend(text) {
        modelManager.withActiveCaps(function() {
            engine.send(text + "\n\n[Please use your web_search tool to find current information for this question.]",
                        { displayText: text + " 🔍" })
        })
    }

    function regenerate() { engine.regenerate() }
    function stop() {
        // Verworfene TOOL-Generierung mit abbrechen: ohne cancel() liefe das
        // Polling weiter und der Download schriebe ein Orphan-Bild nach
        // images/ — der originConvId-Guard in onFinished verwirft das
        // Ergebnis erst NACH dem Speichern. Der MANUELLE ImagePanel-Weg
        // bleibt bewusst unberührt (der Nutzer wartet dort auf sein Bild).
        if (comfyClient.busy && comfyClient.toolInitiated) comfyClient.cancel()
        engine.stop()
    }

    // ==================== Konversations-Methoden ====================
    function newConversation() { engine.newConversation(); refreshConversationList() }
    function loadConversation(convId) { engine.loadConversation(convId) }
    function deleteConversation(convId) { engine.deleteConversation(convId); refreshConversationList() }
    function refreshConversationList() {
        conversationList = engine.listConversations().map(function(c) {
            return { "id": c.id, "title": c.title !== "" ? c.title : "Neue Konversation",
                "created_at": c.createdAt, "updated_at": c.updatedAt }
        })
    }

    // Konversations-Suche (FTS5 im Store): Titel + user/assistant-Inhalte,
    // AND/Präfix je Wort. Unter 2 Zeichen keine Suche (Ergebnis leeren).
    function searchConversations(text) {
        var q = (text || "").trim()
        if (q.length < 2) { searchResults = []; return }
        searchResults = ConversationStore.searchConversations(q, 50).map(function(c) {
            return { "id": c.id, "title": c.title !== "" ? c.title : "Neue Konversation",
                "created_at": c.createdAt, "updated_at": c.updatedAt,
                "snippet": c.snippet || "" }
        })
    }

    // ==================== Wissensbasis-Methoden ====================
    function refreshGoodExamples() { goodExamples = engine.goodExamples() }
    function refreshManualEntries() { manualEntries = engine.knowledgeEntries() }
    function openKnowledge() { refreshGoodExamples(); refreshManualEntries(); knowledgeOpen = true }
    function closeKnowledge() { knowledgeOpen = false }
    // Entfernen aus der Wissensbasis = Rating auf 0 (der ChatController-Hook löscht
    // den Vektor). Die Liste aktualisiert sich über die Store-Connection nach dem
    // asynchronen Write (ein sofortiges refresh läse noch den alten Stand).
    function removeGoodExample(msgId) { engine.rateMessage(msgId, 0) }
    // Manuelle Einträge: ebenfalls Refresh erst über die Store-Connection.
    function addManualEntry(kind, title, url, content) { engine.addKnowledge(kind, title, url, content) }
    function updateManualEntry(id, kind, title, url, content) { engine.updateKnowledge(id, kind, title, url, content) }
    function removeManualEntry(id) { engine.removeKnowledge(id) }
    // Entfernen am Ort (Attribution an der Bubble, Scheibe C): die Quelle aus der
    // Wissensbasis nehmen — rated = Rating-Reset (der Hook löscht den Vektor),
    // knowledge = Eintrag löschen — und die sichtbare Attribution sofort strippen.
    function removeRagSource(rowMsgId, source, id) {
        if (source === "rated") removeGoodExample(id)
        else removeManualEntry(id)
        engine.stripRagSource(rowMsgId, id)
    }

    // ==================== Modell / Tool-Freigabe ====================
    function selectModel(value) { modelManager.selectModel(value) }
    function confirmOnce() { engine.confirmOnce() }
    function confirmForConversation() { engine.confirmForConversation() }
    function reject() { engine.reject() }

    // ==================== Sprache / Toggles / Anhang / Bild / Memory ====================
    function speak(text) { speaker.speak(_stripMarkdown(text)) }
    // Markdown für die Sprachausgabe entfernen (gilt für Auto-Vorlesen UND den
    // manuellen Bubble-Knopf, da beide über speak() laufen). Pragmatisch, kein
    // vollständiger Parser.
    function _stripMarkdown(t) {
        if (!t) return ""
        var s = t
        s = s.replace(/```[^\n]*\n?/g, "")            // Codefence-Zeilen (```lang / ```), Inhalt bleibt
        s = s.replace(/`([^`]+)`/g, "$1")             // inline `code`
        s = s.replace(/!\[[^\]]*\]\([^)]*\)/g, "")    // Bilder
        s = s.replace(/\[([^\]]+)\]\([^)]*\)/g, "$1")  // Links -> Linktext
        s = s.replace(/^[ \t]{0,3}#{1,6}[ \t]+/gm, "") // Überschriften-Marker
        s = s.replace(/^[ \t]{0,3}>[ \t]?/gm, "")       // Zitat-Marker
        s = s.replace(/^[ \t]*[-*+][ \t]+/gm, "")       // Aufzählungs-Marker
        s = s.replace(/^[ \t]*\d+\.[ \t]+/gm, "")       // nummerierte Liste
        s = s.replace(/\*\*([^*]+)\*\*/g, "$1")         // **fett**
        s = s.replace(/\*([^*]+)\*/g, "$1")             // *kursiv*
        s = s.replace(/_([^_]+)_/g, "$1")               // _kursiv_
        return s
    }
    function stopSpeaking() { speaker.stop() }
    function toggleVoice() { voiceRecorder.toggle() }
    function setThinking(on) { thinkingEnabled = on }
    function modelParamsFor(name) { return settings.paramsFor(name) }
    function setModelParams(name, obj) { settings.setModelParams(name, obj) }
    function rateMessage(msgId, rating) { engine.rateMessage(msgId, rating) }
    function setAutoSpeak(on) {
        // autoSpeak ist an settings.ttsAutoSpeak gebunden (reaktiv) — imperative
        // Zuweisung würde die Bindung brechen; requestPersist schreibt in den
        // ConfigStore, dessen revision-Bump die Bindung synchron aktualisiert.
        settings.requestPersist("ttsAutoSpeak", on)
        if (!on) speaker.stop()
    }
    function setImageMode(on) { imageMode = on }
    function openAttachment() { fileDialog.open() }
    function clearAttachment() { attachedFileUrl = ""; attachedFileName = "" }
    function generateImage(params) {
        // Manuelle Busy-Ablehnung hier direkt melden (nicht über comfyClient.failed),
        // sonst könnte der toolInitiated-Guard in onFailed die Rückmeldung schlucken,
        // solange eine tool-initiierte Generierung läuft (Minor). In der UI ist der
        // Generieren-Knopf während busy zwar ohnehin deaktiviert (ImagePanel) —
        // dieser Zweig ist die belt-and-suspenders-Absicherung.
        if (comfyClient.busy) {
            _transientStatus = "Bild: Es läuft bereits eine Generierung"
            voiceStatusTimer.restart()
            return
        }
        // Ursprungs-Konversation an die Generierung heften (einheitlicher Guard mit
        // dem Tool-Weg) — der onFinished-Handler verwirft das Bild bei Wechsel.
        params.originConvId = engine.conversationId
        comfyClient.generate(params)
    }
    function openMemory() { Qt.openUrlExternally("file://" + FileIO.standardPath("appData") + "/memory.md") }
}
