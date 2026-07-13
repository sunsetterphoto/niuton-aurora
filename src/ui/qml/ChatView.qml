import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import net.niuton.aurora.ui

ColumnLayout {
    id: chatViewRoot

    // ---------- Eingänge (Host -> ChatView) ----------
    property alias chatModel: listView.model
    property bool busy: false
    property string statusText: ""       // vom Host bereits gemergt
    property var pendingTool: null
    property bool showThinking: false
    property bool ttsAvailable: false
    property bool voiceAvailable: false
    property string voiceState: "idle"
    property bool comfyAvailable: false
    property bool imageMode: false
    property string attachedFileName: ""
    property var commandList: []
    property var modelEntries: []
    property string commandNotice: ""

    // ---------- Ausgänge (ChatView -> Host) ----------
    signal messageSent(string text)
    signal searchRequested(string text)
    signal attachRequested()
    signal clearAttachment()
    signal abortRequested()
    signal voiceToggled()
    signal imageModeRequested()
    signal regenerateRequested()
    signal speakRequested(string text)
    signal rateRequested(string msgId, int rating)
    signal confirmOnceRequested()
    signal confirmForConversationRequested()
    signal rejectRequested()

    spacing: Kirigami.Units.smallSpacing

    // ---------- Öffentliche Methode (Host -> Kind, imperativ) ----------
    // Transkript aus dem VoiceRecorder ins Eingabefeld übernehmen
    // (Regel aus main.qml: bei nicht-leerem Feld mit Leerzeichen verketten).
    function insertTranscript(text) {
        chatInput.text = chatInput.text.trim() !== ""
            ? chatInput.text.trim() + " " + text : text
    }

    // ---------- Autoscroll ----------
    Timer {
        id: scrollTimer
        interval: 50
        repeat: false
        onTriggered: listView.positionViewAtEnd()
    }

    // ---------- Nachrichtenliste ----------
    QQC2.ScrollView {
        Layout.fillWidth: true
        Layout.fillHeight: true

        ListView {
            id: listView
            spacing: Kirigami.Units.smallSpacing
            clip: true

            delegate: MessageBubble {
                required property int index
                width: listView.width
                showThinking: chatViewRoot.showThinking
                isLast: index === listView.count - 1 && !chatViewRoot.busy
                canSpeak: chatViewRoot.ttsAvailable
                onRegenerateRequested: chatViewRoot.regenerateRequested()
                onSpeakRequested: function(text) { chatViewRoot.speakRequested(text) }
                onRateRequested: function(msgId, rating) { chatViewRoot.rateRequested(msgId, rating) }
            }

            // Neue Nachricht -> ans Ende. Zusätzlich dem in-place wachsenden
            // Streaming-Text folgen (count ändert sich beim Streaming nicht).
            onCountChanged: scrollTimer.restart()
            onContentHeightChanged: if (chatViewRoot.busy) scrollTimer.restart()
        }
    }

    // ---------- Statuszeile (Aurora-Schimmerbalken + Text) ----------
    ColumnLayout {
        Layout.fillWidth: true
        Layout.leftMargin: Kirigami.Units.smallSpacing
        Layout.rightMargin: Kirigami.Units.smallSpacing
        visible: chatViewRoot.busy || chatViewRoot.statusText !== ""
        spacing: 2

        Item {
            id: shimmerTrack
            Layout.fillWidth: true
            Layout.preferredHeight: 2
            clip: true
            visible: chatViewRoot.busy

            Rectangle {
                id: shimmerBar
                width: parent.width * 0.35
                height: parent.height
                radius: 1
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.0;  color: "transparent" }
                    GradientStop { position: 0.25; color: Theme.auroraGreen }
                    GradientStop { position: 0.5;  color: Theme.auroraCyan }
                    GradientStop { position: 0.75; color: Theme.auroraBlue }
                    GradientStop { position: 1.0;  color: "transparent" }
                }

                XAnimator on x {
                    from: -shimmerTrack.width * 0.35
                    to: shimmerTrack.width
                    duration: 1400
                    loops: Animation.Infinite
                    running: chatViewRoot.busy
                }
            }
        }

        QQC2.Label {
            text: chatViewRoot.statusText
            font.italic: true
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            opacity: 0.7
        }
    }

    // ---------- Attachment-Indikator ----------
    RowLayout {
        Layout.fillWidth: true
        Layout.leftMargin: Kirigami.Units.smallSpacing
        visible: chatViewRoot.attachedFileName !== ""
        spacing: Kirigami.Units.smallSpacing

        Kirigami.Icon {
            source: "mail-attachment"
            Layout.preferredWidth: Kirigami.Units.iconSizes.small
            Layout.preferredHeight: Kirigami.Units.iconSizes.small
        }
        QQC2.Label {
            text: chatViewRoot.attachedFileName
            elide: Text.ElideMiddle
            Layout.fillWidth: true
        }
        QQC2.ToolButton {
            icon.name: "edit-delete-remove"
            Layout.preferredWidth: Kirigami.Units.iconSizes.small
            Layout.preferredHeight: Kirigami.Units.iconSizes.small
            onClicked: chatViewRoot.clearAttachment()
        }
    }

    // ---------- Tool-Bestätigungs-Bar ----------
    Rectangle {
        Layout.fillWidth: true
        implicitHeight: confirmColumn.implicitHeight + Kirigami.Units.smallSpacing * 2
        visible: chatViewRoot.pendingTool !== null
        color: Qt.rgba(Kirigami.Theme.neutralTextColor.r, Kirigami.Theme.neutralTextColor.g, Kirigami.Theme.neutralTextColor.b, 0.15)
        radius: Kirigami.Units.smallSpacing
        border.color: Kirigami.Theme.neutralTextColor
        border.width: 1

        ColumnLayout {
            id: confirmColumn
            anchors.fill: parent
            anchors.margins: Kirigami.Units.smallSpacing

            QQC2.Label {
                Layout.fillWidth: true
                text: chatViewRoot.pendingTool ? chatViewRoot.pendingTool.description : ""
                wrapMode: Text.Wrap
                font.family: "monospace"
                font.pointSize: Kirigami.Theme.smallFont.pointSize
            }
            QQC2.Label {
                Layout.fillWidth: true
                visible: chatViewRoot.pendingTool
                    && (chatViewRoot.pendingTool.name === "run_command"
                        || chatViewRoot.pendingTool.name === "write_file")
                text: "⚠ „Für diesen Chat” gilt für ALLE weiteren " + (chatViewRoot.pendingTool ? chatViewRoot.pendingTool.name : "") + "-Aufrufe in diesem Chat."
                wrapMode: Text.Wrap
                color: Kirigami.Theme.neutralTextColor
                font.pointSize: Kirigami.Theme.smallFont.pointSize
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                QQC2.Button {
                    text: "Ja"; icon.name: "dialog-ok-apply"
                    onClicked: chatViewRoot.confirmOnceRequested()
                }
                QQC2.Button {
                    text: "Ja, für diesen Chat"; icon.name: "dialog-ok"
                    onClicked: chatViewRoot.confirmForConversationRequested()
                }
                QQC2.Button {
                    text: "Nein"; icon.name: "dialog-cancel"
                    onClicked: chatViewRoot.rejectRequested()
                }
                Item { Layout.fillWidth: true }
            }
        }
    }

    // ---------- Befehls-Notiz (über der Eingabe) ----------
    QQC2.Label {
        visible: chatViewRoot.commandNotice !== ""
        Layout.fillWidth: true
        Layout.leftMargin: Kirigami.Units.smallSpacing
        Layout.rightMargin: Kirigami.Units.smallSpacing
        text: chatViewRoot.commandNotice
        wrapMode: Text.Wrap
        font.pointSize: Kirigami.Theme.smallFont.pointSize
        opacity: 0.7
    }

    // ---------- Eingabe (Chat-Modus) ----------
    ChatInput {
        id: chatInput
        visible: !chatViewRoot.imageMode
        Layout.fillWidth: true
        Layout.leftMargin: Kirigami.Units.smallSpacing
        Layout.rightMargin: Kirigami.Units.smallSpacing
        Layout.bottomMargin: Kirigami.Units.smallSpacing
        isGenerating: chatViewRoot.busy
        voiceAvailable: chatViewRoot.voiceAvailable
        voiceState: chatViewRoot.voiceState
        comfyAvailable: chatViewRoot.comfyAvailable
        commands: chatViewRoot.commandList
        modelEntries: chatViewRoot.modelEntries
        onVoiceToggled: chatViewRoot.voiceToggled()
        onImageModeRequested: chatViewRoot.imageModeRequested()
        onMessageSent: function(text) { chatViewRoot.messageSent(text) }
        onAttachRequested: chatViewRoot.attachRequested()
        onSearchRequested: function(text) { chatViewRoot.searchRequested(text) }
        onAbortRequested: chatViewRoot.abortRequested()
    }
}
