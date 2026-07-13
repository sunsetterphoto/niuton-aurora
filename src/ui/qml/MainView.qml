import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

// Geteilte Haupt-View (Header + Sidebar | Chat-Spalte). Dumb-View: property-in
// (controller injiziert) / signal-out. Widget UND App montieren nur diese
// Komponente; host-spezifische Aktionen (Pin/Konfigurieren/Schließen) gehen
// per Signal nach außen. Sibling-Typen (Header/Sidebar/ChatView/ImagePanel)
// stammen aus demselben Modul (kein Selbst-Import nötig).
ColumnLayout {
    id: root
    spacing: 0

    // ==================== Schnittstelle ====================
    property var controller
    property bool isPinned: false          // Pin-Knopf-Zustand (Host bindet)
    property bool showPin: true            // App blendet Pin aus
    property bool showConfigure: true      // App blendet Konfigurieren aus
    signal pinToggled(bool on)
    signal configureRequested()
    signal closeRequested()

    property bool _sidebarOpen: false      // interner View-Zustand (beide Hosts)
    property bool _tuneOpen: false         // ModelTuner-Sichtbarkeit (interner View-Zustand)

    Header {
        Layout.fillWidth: true
        Layout.margins: Kirigami.Units.smallSpacing

        sidebarOpen: root._sidebarOpen
        canNewChat: true
        pickerEntries: root.controller.modelPickerEntries
        selectedModel: root.controller.selectedModel
        activeModel: root.controller.activeModel
        isRemoteModel: root.controller.isRemoteModel
        modelLoaded: root.controller.modelLoaded
        modelLoading: root.controller.modelLoading
        thinkingEnabled: root.controller.thinkingEnabled
        isPinned: root.isPinned
        isLoading: root.controller.busy
        ttsAvailable: root.controller.ttsAvailable
        autoSpeakEnabled: root.controller.autoSpeak
        localOk: root.controller.localOk
        remoteOk: root.controller.remoteOk
        comfyOk: root.controller.comfyAvailable
        showPin: root.showPin
        showConfigure: root.showConfigure

        onToggleSidebar: root._sidebarOpen = !root._sidebarOpen
        onNewChatRequested: root.controller.newConversation()
        onModelSelected: function(value) { root.controller.selectModel(value) }
        onThinkingToggled: function(on) { root.controller.setThinking(on) }
        onAutoSpeakToggled: function(on) { root.controller.setAutoSpeak(on) }
        onPinToggled: function(on) { root.pinToggled(on) }
        onMemoryRequested: root.controller.openMemory()
        onKnowledgeRequested: root.controller.openKnowledge()
        onConfigureRequested: root.configureRequested()
        onTuneModelRequested: root._tuneOpen = !root._tuneOpen
        onCloseRequested: root.closeRequested()
    }

    Kirigami.Separator { Layout.fillWidth: true }

    RowLayout {
        Layout.fillWidth: true
        Layout.fillHeight: true
        spacing: 0

        Sidebar {
            Layout.preferredWidth: root._sidebarOpen ? Kirigami.Units.gridUnit * 10 : 0
            Layout.fillHeight: true
            visible: root._sidebarOpen

            conversations: root.controller.conversationList
            currentId: root.controller.conversationId
            canNewChat: true

            onNewChatRequested: root.controller.newConversation()
            onLoadRequested: function(convId) { root.controller.loadConversation(convId) }
            onDeleteRequested: function(convId) { root.controller.deleteConversation(convId) }

            Behavior on Layout.preferredWidth { NumberAnimation { duration: 150 } }
        }

        Kirigami.Separator {
            Layout.fillHeight: true
            visible: root._sidebarOpen
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Kirigami.Units.smallSpacing

            // Model-Loading-Indikator (plasma-neutral: QQC2 statt PlasmaComponents)
            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.smallSpacing
                visible: root.controller.modelLoading
                spacing: Kirigami.Units.smallSpacing
                QQC2.BusyIndicator {
                    Layout.preferredWidth: Kirigami.Units.iconSizes.small
                    Layout.preferredHeight: Kirigami.Units.iconSizes.small
                    running: true
                }
                QQC2.Label {
                    text: "Lade " + root.controller.activeModel + "..."
                    font.italic: true
                    opacity: 0.7
                }
            }

            ModelTuner {
                id: modelTuner
                Layout.fillWidth: true
                visible: root._tuneOpen
                modelName: root.controller.activeModel
                params: root.controller.modelParamsFor(root.controller.activeModel)
                onSaveRequested: function(p) {
                    root.controller.setModelParams(root.controller.activeModel, p)
                    root._tuneOpen = false
                }
                onCloseRequested: root._tuneOpen = false
            }

            ChatView {
                id: chatView
                visible: !root.controller.knowledgeOpen
                Layout.fillWidth: true
                Layout.fillHeight: true

                chatModel: root.controller.chatModel
                busy: root.controller.busy
                statusText: root.controller.statusText
                pendingTool: root.controller.pendingTool
                showThinking: root.controller.thinkingEnabled
                ttsAvailable: root.controller.ttsAvailable
                voiceAvailable: root.controller.voiceAvailable
                voiceState: root.controller.voiceState
                comfyAvailable: root.controller.comfyAvailable
                imageMode: root.controller.imageMode
                attachedFileName: root.controller.attachedFileName
                commandList: root.controller.commandList
                modelEntries: root.controller.modelPickerEntries
                commandNotice: root.controller.commandNotice

                onMessageSent: function(text) { root.controller.sendMessage(text) }
                onSearchRequested: function(text) { root.controller.searchAndSend(text) }
                onAttachRequested: root.controller.openAttachment()
                onClearAttachment: root.controller.clearAttachment()
                onAbortRequested: root.controller.stop()
                onVoiceToggled: root.controller.toggleVoice()
                onImageModeRequested: root.controller.setImageMode(true)
                onRegenerateRequested: root.controller.regenerate()
                onSpeakRequested: function(text) { root.controller.speak(text) }
                onRateRequested: function(msgId, rating) { root.controller.rateMessage(msgId, rating) }
                onConfirmOnceRequested: root.controller.confirmOnce()
                onConfirmForConversationRequested: root.controller.confirmForConversation()
                onRejectRequested: root.controller.reject()
            }

            KnowledgeView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: root.controller.knowledgeOpen
                examples: root.controller.goodExamples
                manualEntries: root.controller.manualEntries
                onRemoveRequested: function(msgId) { root.controller.removeGoodExample(msgId) }
                onRemoveEntryRequested: function(id) { root.controller.removeManualEntry(id) }
                onAddRequested: function(kind, title, url, content) { root.controller.addManualEntry(kind, title, url, content) }
                onEditRequested: function(id, kind, title, url, content) { root.controller.updateManualEntry(id, kind, title, url, content) }
                onCloseRequested: root.controller.closeKnowledge()
            }

            // Transkript aus dem VoiceRecorder ins Eingabefeld — hier möglich,
            // weil chatView im selben Scope liegt.
            Connections {
                target: root.controller
                function onTranscriptReady(text) { chatView.insertTranscript(text) }
            }

            ImagePanel {
                visible: root.controller.imageMode
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.smallSpacing
                Layout.rightMargin: Kirigami.Units.smallSpacing
                Layout.bottomMargin: Kirigami.Units.smallSpacing
                busy: root.controller.comfyBusy
                statusText: root.controller.comfyStatus
                models: root.controller.comfyModels
                defaultModel: root.controller.comfyDefaultModel
                onGenerateRequested: function(params) { root.controller.generateImage(params) }
                onCloseRequested: root.controller.setImageMode(false)
            }
        }
    }
}
