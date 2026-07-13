import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import net.niuton.aurora.ui

Rectangle {
    id: sidebar

    property var conversations: []
    property string currentId: ""
    property bool canNewChat: false

    signal newChatRequested()
    signal loadRequested(string convId)
    signal deleteRequested(string convId)

    clip: true
    color: Theme.withAlpha(Kirigami.Theme.textColor, 0.03)

    // "Heute 14:32" / "27.06." aus ISO-Datum
    function _prettyDate(iso) {
        var d = new Date(iso)
        if (isNaN(d.getTime())) return ""
        var now = new Date()
        var sameDay = d.toDateString() === now.toDateString()
        if (sameDay) return Qt.formatTime(d, "hh:mm")
        return Qt.formatDate(d, "dd.MM.")
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Kirigami.Units.smallSpacing

        QQC2.ToolButton {
            Layout.fillWidth: true
            icon.name: "list-add"
            text: "Neuer Chat"
            enabled: sidebar.canNewChat
            onClicked: sidebar.newChatRequested()
        }

        Kirigami.Separator { Layout.fillWidth: true }

        ListView {
            id: convListView
            Layout.fillWidth: true
            Layout.fillHeight: true
            model: sidebar.conversations
            clip: true
            spacing: 2

            delegate: Rectangle {
                required property var modelData
                required property int index
                width: convListView.width
                height: convColumn.implicitHeight + Kirigami.Units.smallSpacing * 2
                radius: Kirigami.Units.smallSpacing
                color: modelData.id === sidebar.currentId
                    ? Theme.withAlpha(Kirigami.Theme.highlightColor, 0.85)
                    : convHoverHandler.hovered
                        ? Theme.withAlpha(Kirigami.Theme.highlightColor, 0.15)
                        : "transparent"

                Behavior on color { ColorAnimation { duration: 100 } }

                RowLayout {
                    anchors.fill: parent
                    anchors.margins: Kirigami.Units.smallSpacing

                    ColumnLayout {
                        id: convColumn
                        Layout.fillWidth: true
                        spacing: 0

                        QQC2.Label {
                            Layout.fillWidth: true
                            text: modelData.title
                            elide: Text.ElideRight
                            color: modelData.id === sidebar.currentId
                                ? Kirigami.Theme.highlightedTextColor
                                : Kirigami.Theme.textColor
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                        }

                        QQC2.Label {
                            text: sidebar._prettyDate(modelData.created_at)
                            font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                            opacity: 0.5
                            color: modelData.id === sidebar.currentId
                                ? Kirigami.Theme.highlightedTextColor
                                : Kirigami.Theme.textColor
                        }
                    }

                    QQC2.ToolButton {
                        Layout.preferredWidth: Kirigami.Units.iconSizes.small
                        Layout.preferredHeight: Kirigami.Units.iconSizes.small
                        icon.name: "edit-delete"
                        visible: convHoverHandler.hovered || modelData.id === sidebar.currentId
                        onClicked: sidebar.deleteRequested(modelData.id)
                    }
                }

                HoverHandler { id: convHoverHandler }

                MouseArea {
                    anchors.fill: parent
                    z: -1
                    onClicked: sidebar.loadRequested(modelData.id)
                }
            }
        }
    }
}
