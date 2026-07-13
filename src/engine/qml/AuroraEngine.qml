import QtQuick
import net.niuton.aurora.engine

QtObject {
    id: engine

    // Injektion
    property var modelManager: null
    property var store: null
    property var settings: null
    property var registry: null
    property var resolver: PermissionResolver {}
    property var grants: GrantStore {}
    property var comfy: null
    property var chatFn: null
    property var embedFn: null
    property string homeDir: ""
    property bool thinkingEnabled: false

    // durchgereichter Zustand (Alias muss id-verwurzelt sein -> ctlInner, NICHT die
    // Property _ctl; ein Alias auf eine Property lädt nicht)
    readonly property alias chatModel: ctlInner.chatModel
    readonly property string state: _ctl.state
    readonly property bool busy: _ctl.busy
    readonly property string conversationId: _ctl.conversationId
    readonly property var pendingTool: _ctl.pendingTool
    readonly property string statusText: _ctl.statusText

    // Vom ChatController durchgereicht (Auto-Vorlesen-Trigger für den Host/Controller).
    signal assistantFinal(string text)

    property ChatController _ctl: ChatController {
        id: ctlInner
        store: engine.store; settings: engine.settings; registry: engine.registry
        resolver: engine.resolver; grants: engine.grants; comfy: engine.comfy
        chatFn: engine.chatFn; embedFn: engine.embedFn; homeDir: engine.homeDir; thinkingEnabled: engine.thinkingEnabled
        activeModel: engine.modelManager ? engine.modelManager.activeModel : ""
        activeCaps: engine.modelManager ? engine.modelManager.activeCaps : []
        isRemote: engine.modelManager ? engine.modelManager.isRemote : false
        comfyAvailable: engine.comfy ? engine.comfy.available : false
        onAssistantFinal: function(text) { engine.assistantFinal(text) }
    }

    // Chat-API
    function send(text, extra) { _ctl.send(text, extra) }
    function compact() { _ctl.compact() }
    function exportConversation() { return _ctl.exportConversation() }
    function stop() { _ctl.stop() }
    function confirmOnce() { _ctl.confirmOnce() }
    function confirmForConversation() { _ctl.confirmForConversation() }
    function reject() { _ctl.reject() }
    function regenerate() { _ctl.regenerate() }
    function newConversation() { _ctl.newConversation() }
    function loadConversation(id) { _ctl.loadConversation(id) }
    function appendGeneratedImage(p, t) { _ctl.appendGeneratedImage(p, t) }
    function rateMessage(msgId, rating) { _ctl.rateMessage(msgId, rating) }

    // Konversations-API
    function listConversations() { return engine.store.listConversations() }
    function deleteConversation(id) {
        if (id === _ctl.conversationId && _ctl.state !== "idle") _ctl.stop()
        engine.store.deleteConversation(id)
        if (id === _ctl.conversationId) _ctl.newConversation()
    }
    function goodExamples() { return engine.store ? engine.store.goodExamples() : [] }

    // ==================== Wissensbasis: manuelle Einträge ====================
    function knowledgeEntries() { return engine.store ? engine.store.knowledgeEntries() : [] }

    function addKnowledge(kind, title, url, content) {
        if (!engine.store || typeof engine.store.addKnowledge !== "function") return ""
        var id = engine.store.newUuid()
        engine.store.addKnowledge({ "id": id, "kind": kind, "title": title, "url": url, "content": content })
        _embedKnowledge(id, title, content)
        return id
    }

    function updateKnowledge(id, kind, title, url, content) {
        if (!engine.store || typeof engine.store.updateKnowledge !== "function") return
        engine.store.updateKnowledge(id, { "kind": kind, "title": title, "url": url, "content": content })
        _embedKnowledge(id, title, content)
    }

    function removeKnowledge(id) {
        if (engine.store && typeof engine.store.deleteKnowledge === "function")
            engine.store.deleteKnowledge(id)
    }

    // Best-effort + feature-detektiert (spiegelt ChatController._syncEmbedding):
    // Titel+Inhalt einbetten und den Vektor auf DIESEN Eintrag legen. Leerer Text
    // -> Vektor löschen. Embed-Fehler (r == null) -> alten Vektor stehen lassen.
    function _embedKnowledge(id, title, content) {
        if (!engine.store || typeof engine.store.setKnowledgeEmbedding !== "function") return
        var text = ((title || "") + "\n" + (content || "")).trim()
        if (text === "") { engine.store.setKnowledgeEmbedding(id, [], ""); return }
        if (!engine.embedFn) return
        engine.embedFn(text, function(r) {
            if (r && r.vec && r.vec.length > 0) engine.store.setKnowledgeEmbedding(id, r.vec, r.model)
        })
    }

    // Modell-API (delegiert)
    function selectModel(v) { if (engine.modelManager) engine.modelManager.selectModel(v) }
}
