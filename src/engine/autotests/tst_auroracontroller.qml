import QtQuick
import QtTest
import net.niuton.aurora.core
import net.niuton.aurora.engine

Item {
    AuroraController { id: controller }

    TestCase {
        name: "AuroraController"

        // ConfigStore ist ein Singleton pro Prozess (nicht neu baubar) — vor jedem
        // Test auf Defaults zuruecksetzen. AURORA_CONFIG_PATH (s. CMake) haelt das
        // ausserhalb der echten ~/.config/net.niuton.aurora.rc.
        function init() { ConfigStore.reset() }

        // Die bare Instanz ist inert: active bleibt false -> kein ModelManager-Polling,
        // open()/activate()/checkAvailability() ungerufen -> kein Netz/Prozess-Spawn.
        function test_defaults() {
            compare(controller.busy, false)
            compare(controller.imageMode, false)
            compare(controller.thinkingEnabled, false)
            compare(controller.active, false)
            compare(controller.attachedFileName, "")
            compare(controller.statusText, "")
            compare(controller.conversationList.length, 0)
        }

        function test_interfaceMethodsExist() {
            verify(typeof controller.sendMessage === "function")
            verify(typeof controller.searchAndSend === "function")
            verify(typeof controller.newConversation === "function")
            verify(typeof controller.loadConversation === "function")
            verify(typeof controller.deleteConversation === "function")
            verify(typeof controller.selectModel === "function")
            verify(typeof controller.generateImage === "function")
            verify(typeof controller.openMemory === "function")
            verify(typeof controller.activate === "function")
            verify(typeof controller.open === "function")
        }

        // Reine State-Setter duerfen keine Seiteneffekte haben (kein Netz/Prozess).
        function test_pureStateSetters() {
            controller.setImageMode(true)
            compare(controller.imageMode, true)
            controller.setImageMode(false)
            compare(controller.imageMode, false)
            controller.setThinking(true)
            compare(controller.thinkingEnabled, true)
            controller.setThinking(false)
            compare(controller.thinkingEnabled, false)
        }

        // Markdown-Bereinigung für die Sprachausgabe (Auto + manueller Knopf).
        function test_stripMarkdown() {
            compare(controller._stripMarkdown("**x**"), "x")
            compare(controller._stripMarkdown("`ls`"), "ls")
            compare(controller._stripMarkdown("[a](http://b)"), "a")
            compare(controller._stripMarkdown("# Titel"), "Titel")
            compare(controller._stripMarkdown("- Punkt"), "Punkt")
        }

        // Slash-Befehls-Dispatch — nur netz-freie Befehle (kein /search <text>,
        // kein /model <treffer>, die würden engine.send/Netz auslösen).
        function test_commandList_vorhanden() {
            verify(controller.commandList.length >= 7)
        }
        function test_command_image_setztImageMode() {
            controller.setImageMode(false)
            controller.sendMessage("/image")
            compare(controller.imageMode, true)
        }
        function test_command_unbekannt_setztNoticeKeineAktion() {
            controller.commandNotice = ""
            controller.setImageMode(false)
            controller.sendMessage("/gibtsnicht")
            verify(controller.commandNotice.indexOf("/gibtsnicht") >= 0)
            compare(controller.imageMode, false)          // keine Aktion ausgelöst
        }
        function test_command_searchLeer_noticeKeinSend() {
            controller.commandNotice = ""
            controller.sendMessage("/search")
            verify(controller.commandNotice !== "")        // "Suchbegriff fehlt"
        }
        function test_command_help_listetBefehle() {
            controller.commandNotice = ""
            controller.sendMessage("/help")
            verify(controller.commandNotice.indexOf("/model") >= 0)
        }
        function test_command_export_inListe() {
            var hasExport = false
            for (var i = 0; i < controller.commandList.length; i++)
                if (controller.commandList[i].name === "export") hasExport = true
            verify(hasExport)
        }
        function test_command_export_leereKonversation_notice() {
            controller.commandNotice = ""
            controller.sendMessage("/export")
            // inerte Instanz: Store nicht geöffnet -> messages() leer -> Export-Notiz gesetzt
            verify(controller.commandNotice.indexOf("Export") >= 0)
        }
        function test_command_knowledge_oeffnetAnsicht() {
            controller.knowledgeOpen = false
            controller.sendMessage("/knowledge")
            compare(controller.knowledgeOpen, true)
            compare(controller.goodExamples.length, 0)   // Store nicht offen -> leer
        }
        function test_command_knowledge_inListe() {
            var has = false
            for (var i = 0; i < controller.commandList.length; i++)
                if (controller.commandList[i].name === "knowledge") has = true
            verify(has)
        }
        function test_closeKnowledge() {
            controller.openKnowledge()
            compare(controller.knowledgeOpen, true)
            controller.closeKnowledge()
            compare(controller.knowledgeOpen, false)
        }
        function test_manualEntries_default_leer() {
            compare(controller.manualEntries.length, 0)
        }
        function test_wissensMethodenExistieren() {
            verify(typeof controller.addManualEntry === "function")
            verify(typeof controller.updateManualEntry === "function")
            verify(typeof controller.removeManualEntry === "function")
            verify(typeof controller.refreshManualEntries === "function")
        }
        function test_openKnowledge_frischtBeideListen() {
            controller.knowledgeOpen = false
            controller.openKnowledge()
            compare(controller.knowledgeOpen, true)
            // Hinweis: Array.isArray() greift hier nicht — Q_INVOKABLE-QVariantList-
            // Rückgaben landen in QML als array-artige Sequence-Objekte (.length,
            // Index-Zugriff, ListView-model funktionieren, s. KnowledgeView.qml),
            // aber nicht als echtes JS-Array. Deshalb wie im Nachbartest
            // (test_command_knowledge_oeffnetAnsicht) über .length prüfen.
            compare(controller.manualEntries.length, 0)   // Store nicht offen -> leer
            compare(controller.goodExamples.length, 0)    // Store nicht offen -> leer
        }
    }
}
