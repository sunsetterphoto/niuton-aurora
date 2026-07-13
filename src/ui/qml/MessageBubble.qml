import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import net.niuton.aurora.ui

Item {
    id: bubble

    // Qt 6 auto-binds these from ListModel roles (exact name match)
    required property string text
    required property bool isUser
    required property string thinking
    required property bool streaming
    required property string ts
    required property string mediaPath
    required property string mediaType
    required property string status
    required property string toolActivity
    required property string msgId
    required property int rating

    // Bound explicitly from parent
    property bool showThinking: false
    property bool isLast: false
    property bool canSpeak: false

    signal regenerateRequested()
    signal speakRequested(string text)
    signal rateRequested(string msgId, int rating)

    readonly property real maxBubbleWidth: width * 0.85
    readonly property real pad: Kirigami.Units.largeSpacing

    // Aktionszeile sichtbar? Letzte Bubble dauerhaft, sonst bei Hover; nie während
    // des Streamings. Einzige Quelle für opacity + enabled der Aktionszeile.
    readonly property bool _actionsShown: (bubble.isLast || bubbleHover.hovered) && !bubble.streaming

    // Zeigt die Bubble einen Body (Haupt-Bubble)? Wenn nicht (leere Assistant-Nachricht),
    // darf die Aktionszeile keine Höhe reservieren -> sonst Ghost-Bubble mit Leerabstand.
    readonly property bool _hasBody: bubble.text !== "" || bubble.isUser || bubble.streaming || bubble.mediaPath !== ""

    readonly property var _activity: {
        if (isUser || !toolActivity) return []
        try { return JSON.parse(toolActivity) } catch (e) { return [] }
    }

    implicitHeight: wrapper.height + Kirigami.Units.smallSpacing * 2

    // Sanftes Einblenden neuer Nachrichten
    opacity: 0
    Component.onCompleted: opacity = 1
    Behavior on opacity { NumberAnimation { duration: 180 } }

    // Blinkender Streaming-Cursor
    property bool _blinkOn: true
    Timer {
        running: bubble.streaming
        interval: 450
        repeat: true
        onTriggered: bubble._blinkOn = !bubble._blinkOn
        onRunningChanged: if (!running) bubble._blinkOn = true
    }

    // Unsichtbares TextEdit als Clipboard-Brücke (QML hat keine Clipboard-API)
    TextEdit {
        id: clipboardHelper
        visible: false
        function copyText(t) {
            text = t
            selectAll()
            copy()
            text = ""
        }
    }

    HoverHandler { id: bubbleHover }

    // Zerlegt Markdown in Text- und ```Code```-Segmente
    function _segments(t) {
        var parts = []
        var chunks = t.split("```")
        for (var i = 0; i < chunks.length; i++) {
            if (i % 2 === 0) {
                if (chunks[i].replace(/\s/g, "") !== "")
                    parts.push({ "isCode": false, "content": chunks[i].trim(), "lang": "" })
            } else {
                var c = chunks[i]
                var lang = ""
                var body = c
                var nl = c.indexOf("\n")
                if (nl !== -1 && /^[a-zA-Z0-9_+#.-]*$/.test(c.substring(0, nl).trim())) {
                    lang = c.substring(0, nl).trim()
                    body = c.substring(nl + 1)
                }
                parts.push({ "isCode": true, "content": body.replace(/\n+$/, ""), "lang": lang })
            }
        }
        if (parts.length === 0)
            parts.push({ "isCode": false, "content": "", "lang": "" })
        return parts
    }

    Column {
        id: wrapper
        y: Kirigami.Units.smallSpacing
        width: bubble.maxBubbleWidth
        spacing: 2

        anchors.left: bubble.isUser ? undefined : parent.left
        anchors.right: bubble.isUser ? parent.right : undefined
        anchors.leftMargin: Kirigami.Units.smallSpacing
        anchors.rightMargin: Kirigami.Units.smallSpacing

        // ---------- Thinking (einklappbar über showThinking) ----------
        Rectangle {
            visible: !bubble.isUser && bubble.showThinking && bubble.thinking !== ""
            width: parent.width
            height: visible ? thinkCol.height + Kirigami.Units.smallSpacing * 2 : 0
            radius: Kirigami.Units.smallSpacing
            color: Theme.withAlpha(Kirigami.Theme.textColor, 0.04)
            border.color: Theme.withAlpha(Kirigami.Theme.textColor, 0.15)
            border.width: 1

            Column {
                id: thinkCol
                x: Kirigami.Units.smallSpacing
                y: Kirigami.Units.smallSpacing
                width: parent.width - Kirigami.Units.smallSpacing * 2
                spacing: 2

                QQC2.Label {
                    text: "Denkprozess"
                    font.bold: true
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                    opacity: 0.6
                }

                QQC2.Label {
                    width: parent.width
                    text: bubble.thinking
                    wrapMode: Text.Wrap
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                    opacity: 0.6
                    textFormat: Text.PlainText
                    maximumLineCount: 20
                    elide: Text.ElideRight
                }
            }
        }

        // ---------- Haupt-Bubble ----------
        Rectangle {
            id: bubbleRect
            visible: bubble._hasBody
            // User-Bubbles schmiegen sich an den Inhalt, Aurora nutzt die volle Breite
            width: bubble.isUser
                ? Math.min(parent.width, userLabel.implicitWidth + bubble.pad * 2)
                : parent.width
            height: contentCol.height + bubble.pad * 2
            anchors.right: bubble.isUser ? parent.right : undefined

            radius: Kirigami.Units.gridUnit * 0.6
            color: bubble.isUser
                ? Kirigami.Theme.highlightColor
                : Theme.withAlpha(Kirigami.Theme.textColor, 0.055)
            border.color: bubble.isUser
                ? "transparent"
                : Theme.withAlpha(Kirigami.Theme.textColor, 0.09)
            border.width: bubble.isUser ? 0 : 1

            // Aurora-Akzentstreifen an Aurora-Antworten (Signature-Element)
            Rectangle {
                visible: !bubble.isUser
                width: 3
                anchors.left: parent.left
                anchors.leftMargin: -1
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.topMargin: bubbleRect.radius / 2
                anchors.bottomMargin: bubbleRect.radius / 2
                radius: 1.5
                gradient: Gradient {
                    GradientStop { position: 0.0;  color: Theme.withAlpha(Theme.auroraGreen, bubble.streaming ? 0.9 : 0.55) }
                    GradientStop { position: 0.35; color: Theme.withAlpha(Theme.auroraCyan, bubble.streaming ? 0.9 : 0.55) }
                    GradientStop { position: 0.7;  color: Theme.withAlpha(Theme.auroraBlue, bubble.streaming ? 0.9 : 0.55) }
                    GradientStop { position: 1.0;  color: Theme.withAlpha(Theme.auroraViolet, bubble.streaming ? 0.9 : 0.55) }
                }
            }

            Column {
                id: contentCol
                x: bubble.pad + (bubble.isUser ? 0 : 2)
                y: bubble.pad
                width: bubbleRect.width - x - bubble.pad
                spacing: Kirigami.Units.smallSpacing

                // Generiertes/angehängtes Bild
                Image {
                    visible: bubble.mediaPath !== ""
                    source: bubble.mediaPath !== "" ? "file://" + bubble.mediaPath : ""
                    width: Math.min(implicitWidth > 0 ? implicitWidth : parent.width, parent.width)
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true

                    TapHandler {
                        onTapped: Qt.openUrlExternally("file://" + bubble.mediaPath)
                    }
                }

                // User-Nachricht (immer Klartext)
                QQC2.Label {
                    id: userLabel
                    visible: bubble.isUser
                    width: parent.width
                    text: bubble.isUser ? bubble.text : ""
                    wrapMode: Text.Wrap
                    color: Kirigami.Theme.highlightedTextColor
                    textFormat: Text.PlainText
                }

                // Aurora-Antwort als Text-/Code-Segmente
                Repeater {
                    model: bubble.isUser ? [] : bubble._segments(
                        bubble.text + (bubble.streaming && bubble._blinkOn ? " ▍" : ""))

                    delegate: Column {
                        id: segment
                        required property var modelData
                        width: parent.width
                        spacing: 0

                        // Text-Segment (Markdown)
                        QQC2.Label {
                            visible: !segment.modelData.isCode
                            width: parent.width
                            text: visible ? segment.modelData.content : ""
                            wrapMode: Text.Wrap
                            color: Kirigami.Theme.textColor
                            textFormat: Text.MarkdownText
                            onLinkActivated: function(link) { Qt.openUrlExternally(link) }
                        }

                        // Code-Segment mit Kopieren-Button
                        Rectangle {
                            visible: segment.modelData.isCode
                            width: parent.width
                            height: visible ? codeCol.height + Kirigami.Units.smallSpacing * 2 : 0
                            radius: Kirigami.Units.smallSpacing
                            color: Theme.withAlpha(Kirigami.Theme.textColor, 0.07)
                            border.color: Theme.withAlpha(Kirigami.Theme.textColor, 0.12)
                            border.width: 1

                            Column {
                                id: codeCol
                                x: Kirigami.Units.smallSpacing
                                y: Kirigami.Units.smallSpacing
                                width: parent.width - Kirigami.Units.smallSpacing * 2
                                spacing: 2

                                Item {
                                    width: parent.width
                                    height: Math.max(codeLangLabel.height, codeCopyButton.height)

                                    QQC2.Label {
                                        id: codeLangLabel
                                        anchors.left: parent.left
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: segment.modelData.lang !== "" ? segment.modelData.lang : "Code"
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                                        opacity: 0.5
                                    }

                                    QQC2.ToolButton {
                                        id: codeCopyButton
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        icon.name: "edit-copy"
                                        display: QQC2.AbstractButton.IconOnly
                                        onClicked: clipboardHelper.copyText(segment.modelData.content)
                                        QQC2.ToolTip { text: "Code kopieren"; visible: parent.hovered; delay: Kirigami.Units.toolTipDelay }
                                    }
                                }

                                QQC2.Label {
                                    width: parent.width
                                    text: segment.modelData.isCode ? segment.modelData.content : ""
                                    wrapMode: Text.WrapAnywhere
                                    textFormat: Text.PlainText
                                    font.family: "monospace"
                                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                                }
                            }
                        }
                    }
                }
            }
        }

        // ---------- Tool-Chips (aus toolActivity) ----------
        Flow {
            id: toolChips
            width: parent.width
            spacing: Kirigami.Units.smallSpacing
            visible: !bubble.isUser && bubble._activity.length > 0

            Repeater {
                model: bubble._activity
                delegate: Rectangle {
                    id: chip
                    required property var modelData
                    height: chipRow.height + Kirigami.Units.smallSpacing
                    width: chipRow.width + Kirigami.Units.smallSpacing * 2
                    radius: Kirigami.Units.smallSpacing
                    color: Theme.withAlpha(Kirigami.Theme.textColor, 0.06)
                    border.width: 1
                    border.color: Theme.withAlpha(Kirigami.Theme.textColor, 0.12)

                    Row {
                        id: chipRow
                        x: Kirigami.Units.smallSpacing
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Kirigami.Units.smallSpacing

                        QQC2.BusyIndicator {
                            width: Kirigami.Units.iconSizes.small; height: width
                            anchors.verticalCenter: parent.verticalCenter
                            visible: chip.modelData.status === "running"
                            running: visible
                        }
                        QQC2.Label {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: chip.modelData.status !== "running"
                            text: chip.modelData.status === "done" ? "✓"
                                : chip.modelData.status === "denied" ? "⛔"
                                : chip.modelData.status === "error" ? "✗" : "○"
                            color: chip.modelData.status === "done" ? Theme.auroraGreen
                                 : (chip.modelData.status === "denied" || chip.modelData.status === "error")
                                   ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.textColor
                        }
                        QQC2.Label {
                            anchors.verticalCenter: parent.verticalCenter
                            text: chip.modelData.describe || chip.modelData.name
                            elide: Text.ElideRight
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                        }
                        QQC2.Label {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: chip.modelData.durationMs > 0
                            text: (chip.modelData.durationMs / 1000).toFixed(1) + "s"
                            opacity: 0.5
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                        }
                    }
                }
            }
        }

        // ---------- Hinweis: Denkprozess vorhanden, aber ausgeblendet ----------
        QQC2.Label {
            visible: !bubble.isUser && !bubble.showThinking && bubble.thinking !== ""
            text: "Denkprozess verfügbar"
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            font.italic: true
            opacity: 0.5
        }

        // ---------- Aborted-Marker ----------
        QQC2.Label {
            visible: !bubble.isUser && bubble.status === "aborted"
            text: "[abgebrochen]"
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            font.italic: true
            opacity: 0.5
        }

        // ---------- Aktionszeile (letzte Bubble dauerhaft, sonst bei Hover) ----------
        // Immer im Layout (Höhe dauerhaft reserviert) -> Hover verrutscht die Liste
        // nicht; nur opacity blendet, enabled folgt (transparente Buttons fangen
        // keine Klicks/Tooltips).
        Row {
            id: actionRow
            visible: bubble._hasBody
            anchors.right: bubble.isUser ? parent.right : undefined
            spacing: 0
            opacity: bubble._actionsShown ? 1.0 : 0.0
            enabled: bubble._actionsShown
            Behavior on opacity { NumberAnimation { duration: 120 } }

            QQC2.ToolButton {
                icon.name: "edit-copy"
                icon.width: Kirigami.Units.iconSizes.small
                icon.height: Kirigami.Units.iconSizes.small
                padding: Math.round(Kirigami.Units.smallSpacing / 2)
                display: QQC2.AbstractButton.IconOnly
                onClicked: clipboardHelper.copyText(bubble.text)
                QQC2.ToolTip { text: "Nachricht kopieren"; visible: parent.hovered; delay: Kirigami.Units.toolTipDelay }
            }

            QQC2.ToolButton {
                icon.name: "audio-speakers-symbolic"
                icon.width: Kirigami.Units.iconSizes.small
                icon.height: Kirigami.Units.iconSizes.small
                padding: Math.round(Kirigami.Units.smallSpacing / 2)
                display: QQC2.AbstractButton.IconOnly
                visible: !bubble.isUser && bubble.canSpeak
                onClicked: bubble.speakRequested(bubble.text)
                QQC2.ToolTip { text: "Vorlesen"; visible: parent.hovered; delay: Kirigami.Units.toolTipDelay }
            }

            QQC2.ToolButton {
                icon.name: "view-refresh"
                icon.width: Kirigami.Units.iconSizes.small
                icon.height: Kirigami.Units.iconSizes.small
                padding: Math.round(Kirigami.Units.smallSpacing / 2)
                display: QQC2.AbstractButton.IconOnly
                visible: !bubble.isUser && bubble.isLast
                onClicked: bubble.regenerateRequested()
                QQC2.ToolTip { text: "Antwort neu generieren"; visible: parent.hovered; delay: Kirigami.Units.toolTipDelay }
            }

            QQC2.ToolButton {
                visible: !bubble.isUser && bubble.msgId !== ""
                text: "👍"
                display: QQC2.AbstractButton.TextOnly
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                padding: Math.round(Kirigami.Units.smallSpacing / 2)
                opacity: bubble.rating === 1 ? 1.0 : 0.5
                onClicked: bubble.rateRequested(bubble.msgId, bubble.rating === 1 ? 0 : 1)
                QQC2.ToolTip { text: "Gute Antwort"; visible: parent.hovered; delay: Kirigami.Units.toolTipDelay }
            }

            QQC2.ToolButton {
                visible: !bubble.isUser && bubble.msgId !== ""
                text: "👎"
                display: QQC2.AbstractButton.TextOnly
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                padding: Math.round(Kirigami.Units.smallSpacing / 2)
                opacity: bubble.rating === -1 ? 1.0 : 0.5
                onClicked: bubble.rateRequested(bubble.msgId, bubble.rating === -1 ? 0 : -1)
                QQC2.ToolTip { text: "Schlechte Antwort"; visible: parent.hovered; delay: Kirigami.Units.toolTipDelay }
            }

            QQC2.Label {
                anchors.verticalCenter: parent.verticalCenter
                leftPadding: Kirigami.Units.smallSpacing
                text: bubble.ts
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                opacity: 0.45
            }
        }
    }
}
