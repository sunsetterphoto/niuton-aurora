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

        // Slash-Heuristik: nur reine Buchstaben-Tokens gelten als Befehlsname —
        // Pfade/Prosa mit führendem "/" (z. B. "/etc/fstab …") sind kein Befehl.
        function test_looksLikeCommand() {
            verify(controller._looksLikeCommand("/help"))
            verify(controller._looksLikeCommand("/knowledge"))
            verify(controller._looksLikeCommand("/gibtsnicht"))   // reiner Buchstaben-Vertipper -> bleibt Befehl (Notiz)
            verify(controller._looksLikeCommand("/model qwen"))   // Name = "model"
            verify(!controller._looksLikeCommand("/etc/fstab hat einen Fehler"))
            verify(!controller._looksLikeCommand("/home/x"))
            verify(!controller._looksLikeCommand("/tmp/a b"))
            verify(!controller._looksLikeCommand("hallo"))
            verify(!controller._looksLikeCommand(""))
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
        // Ein Slash-Befehl konsumiert die Eingabe, NICHT einen evtl. gesetzten
        // Anhang — sonst reitet die Datei still auf der nächsten echten Nachricht
        // mit (Audit AuroraController.qml:213/Task 10, Fix A).
        function test_command_leertAnhang() {
            controller.attachedFileUrl = "file:///tmp/report.pdf"
            controller.attachedFileName = "report.pdf"
            controller.sendMessage("/new")
            compare(controller.attachedFileUrl, "")
            compare(controller.attachedFileName, "")
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
        // Task 4: manuelle Generierung hängt an, solange die Konversation seit
        // dem (simulierten) generateImage()-Start unverändert ist. originConvId wird
        // direkt gesetzt statt über generateImage() -> kein echter comfy.generate()-
        // Netzaufruf (die Instanz bleibt gemäß Dateikopf-Kommentar netz-frei).
        function test_manualImage_appendsWhenConversationUnchanged() {
            controller._comfy.originConvId = controller.conversationId
            controller._comfy.toolInitiated = false
            var before = controller.chatModel.count
            controller._comfy.finished("/tmp/katze.png", "eine Katze")
            compare(controller.chatModel.count, before + 1)
        }

        // Task 4: Konversationswechsel nach Start der Generierung -> Bild wird
        // verworfen, nicht in die neue (falsche) Konversation gehängt.
        function test_manualImage_discardedWhenConversationChanged() {
            controller._comfy.originConvId = controller.conversationId  // "Start" der Generierung
            controller.newConversation()                                // simuliert "/new" während die Generierung läuft
            controller._comfy.toolInitiated = false
            var before = controller.chatModel.count
            controller._comfy.finished("/tmp/hund.png", "ein Hund")
            compare(controller.chatModel.count, before)            // verworfen
        }

        // Task 4 (Fix nach Review): tool-initiierte Generierungen MÜSSEN sichtbar
        // im Chat erscheinen (kein Render-Regress) — appendGeneratedImage ist die
        // einzige Funktion, die eine bild-tragende Chat-Zeile erzeugt.
        function test_toolImage_surfacesVisually() {
            controller._comfy.originConvId = controller.conversationId  // Ursprung = aktuelle Konversation
            controller._comfy.toolInitiated = true
            var before = controller.chatModel.count
            controller._comfy.finished("/tmp/tool.png", "vom Tool generiert")
            compare(controller.chatModel.count, before + 1)   // Bild sichtbar angehängt
            var row = controller.chatModel.get(controller.chatModel.count - 1)
            compare(row.mediaPath, "/tmp/tool.png")
            compare(row.mediaType, "image")
            controller._comfy.toolInitiated = false
        }

        // Task 4 (Fix 2 nach Re-Review): der conversationId-Guard gilt jetzt auch für
        // den TOOL-Weg — ein tool-Bild, dessen Ursprungskonversation sich vor dem
        // finished geändert hat, wird VERWORFEN (nicht in die aktuelle geschrieben).
        function test_toolImage_discardedWhenConversationChanged() {
            controller._comfy.originConvId = controller.conversationId  // Ursprung der tool-Generierung
            controller._comfy.toolInitiated = true
            controller.newConversation()                                // Nutzer wechselt Konversation, während ComfyUI noch rechnet
            var before = controller.chatModel.count
            controller._comfy.finished("/tmp/tool2.png", "vom Tool generiert")
            compare(controller.chatModel.count, before)            // verworfen, nicht falsch zugeordnet
            controller._comfy.toolInitiated = false
        }

        // Task 4 (Minor): manueller generateImage()-Aufruf während einer laufenden
        // Generierung meldet die Ablehnung direkt (nicht über den gegateten onFailed)
        // und ruft comfyClient.generate() NICHT auf.
        function test_generateImage_busyRejectsWithFeedback() {
            controller._comfy.busy = true
            controller._transientStatus = ""
            var beforeOrigin = controller._comfy.originConvId
            controller.generateImage({ prompt: "x" })
            verify(controller._transientStatus.indexOf("läuft bereits") >= 0)
            compare(controller._comfy.originConvId, beforeOrigin)   // generate() nicht aufgerufen -> originConvId unverändert
            controller._comfy.busy = false
        }

        // Task 4 (Sprache/Robustheit): Speaker.errorOccurred (piper/aplay-Fehler)
        // wird wie voiceRecorder.onErrorOccurred an den transienten Status
        // gebunden — direkter Signal-Aufruf statt echtem Prozess-Spawn (piper/
        // aplay dürfen in Tests nicht real gestartet werden).
        function test_speakerError_setztTransientStatus() {
            controller._transientStatus = ""
            controller._sp.errorOccurred("Sprachausgabe fehlgeschlagen: Testfehler")
            compare(controller._transientStatus, "Sprachausgabe: Sprachausgabe fehlgeschlagen: Testfehler")
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
