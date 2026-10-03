import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import net.niuton.aurora.ui

Rectangle {
    id: sidebar

    // ==================== Routinen ====================
    // Gemappte Zeilen aus dem Scheduler (controller.routineList): {id, title,
    // scheduleText, nextRunText-Äquivalent via nextRun, lastStatus, enabled …}.
    property var routines: []
    property string runningRoutineId: ""
    property bool routinesOpen: true
    // ==================== Chats ====================
    property var conversations: []
    property string currentId: ""
    property bool canNewChat: false
    property bool chatsOpen: true
    // Treffer-Modell der Konversations-Suche (Host füllt es via searchRequested;
    // Einträge wie conversations + snippet). searching steuert die Listenquelle.
    property var searchResults: []
    readonly property bool searching: searchField.text.trim().length >= 2
    // Beim Suchen ist die Trefferliste das einzige sichtbare Modell — Sektionen
    // weichen (volle Höhe für die Treffer, keine Routinen im Weg).
    readonly property bool browseMode: !sidebar.searching

    signal newChatRequested()
    signal loadRequested(string convId)
    signal deleteRequested(string convId)
    signal searchRequested(string text)
    signal routinesToggleRequested(bool open)
    signal chatsToggleRequested(bool open)
    signal routineAddRequested()
    signal routineEditRequested(var routine)
    signal routineDeleteRequested(string id)
    signal routineRunRequested(string id)

    // Löschen-Bestätigung: id der Zeile, die auf den zweiten (bestätigenden)
    // Klick wartet. "" = keine Zeile bestätigungsbereit. Zurückgesetzt beim
    // Verlassen der Zeile (HoverHandler) oder Klick woanders (Laden/Neuer Chat).
    // Getrennte Tokens für Routinen und Chats (IDs stammen aus demselben
    // UUID-Raum, aber getrennte State-Maschinen sind billiger zu denken).
    property string _confirmId: ""
    property string _routineConfirmId: ""

    // Bei Modell-Refresh (conversations neu zugewiesen — passiert praktisch bei
    // jedem Chat-Zug via refreshConversationList()) werden alle Delegates neu
    // erzeugt; ein bewaffneter Zustand darf nicht auf dem Root überleben, sonst
    // "bewaffnet" sich die neu erzeugte Zeile ohne Nutzeraktion selbst wieder.
    onConversationsChanged: _confirmId = ""
    onRoutinesChanged: _routineConfirmId = ""

    clip: true
    color: Theme.withAlpha(Kirigami.Theme.textColor, 0.03)

    // Intern-Exposure für Tests (Konvention wie Header.qml)
    property var _routineListView: routineListView
    property var _convListView: convListView
    property var _routinesToggleBtn: routinesToggleBtn
    property var _chatsToggleBtn: chatsToggleBtn
    property var _routineAddBtn: routineAddBtn
    property var _routineEmptyHint: routineEmptyHint
    property var _searchField: searchField

    // "Heute 14:32" / "27.06." aus ISO-Datum
    function _prettyDate(iso) {
        var d = new Date(iso)
        if (isNaN(d.getTime())) return ""
        var now = new Date()
        var sameDay = d.toDateString() === now.toDateString()
        if (sameDay) return Qt.formatTime(d, "hh:mm")
        return Qt.formatDate(d, "dd.MM.")
    }

    // "in 3 h" / "fällig" / "pausiert" aus ms-Epoch (RoutineScheduler liefert
    // die Rohwerte; das Label baut die View, damit die Zeile ohne Timer-Refresh
    // bei jedem Bindungsdurchlauf frisch rechnet)
    function _routineNextText(row) {
        if (!row.enabled || !row.nextRun) return "pausiert"
        var d = row.nextRun - Date.now()
        if (d <= 0) return "fällig"
        var min = Math.round(d / 60000)
        if (min < 1) return "in <1 min"
        if (min < 60) return "in " + min + " min"
        var h = Math.floor(min / 60), rest = min % 60
        if (h < 24) return "in " + h + " h" + (rest ? " " + rest + " min" : "")
        return "in " + Math.round(h / 24) + " d"
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Kirigami.Units.smallSpacing
        spacing: Kirigami.Units.smallSpacing

        QQC2.ToolButton {
            Layout.fillWidth: true
            icon.name: "list-add"
            text: "Neuer Chat"
            enabled: sidebar.canNewChat
            onClicked: {
                sidebar._confirmId = ""
                sidebar.newChatRequested()
            }
        }

        // Konversations-Suche (FTS5 im Store): Titel + Inhalte, Debounce gegen
        // Suchläufe pro Tastenschlag. Der Host beantwortet searchRequested und
        // füllt searchResults; ab 2 Zeichen wird das Treffer-Modell gezeigt.
        QQC2.TextField {
            id: searchField
            Layout.fillWidth: true
            placeholderText: "Suchen …"
            rightPadding: clearSearch.width
            onTextChanged: searchDebounce.restart()

            QQC2.ToolButton {
                id: clearSearch
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                icon.name: "edit-clear"
                display: QQC2.AbstractButton.IconOnly
                visible: searchField.text !== ""
                onClicked: searchField.text = ""
            }

            Timer {
                id: searchDebounce
                interval: 300
                repeat: false
                onTriggered: sidebar.searchRequested(searchField.text)
            }
        }

        // ==================== Sektion: Routinen ====================
        Kirigami.Separator {
            Layout.fillWidth: true
            visible: sidebar.browseMode
        }

        RowLayout {
            Layout.fillWidth: true
            visible: sidebar.browseMode
            spacing: 0

            QQC2.ToolButton {
                id: routinesToggleBtn
                icon.name: sidebar.routinesOpen ? "arrow-down" : "arrow-right"
                display: QQC2.AbstractButton.IconOnly
                text: sidebar.routinesOpen ? "Routinen einklappen" : "Routinen ausklappen"
                onClicked: sidebar.routinesToggleRequested(!sidebar.routinesOpen)
                QQC2.ToolTip.text: text
                QQC2.ToolTip.visible: hovered
            }

            QQC2.Label {
                Layout.fillWidth: true
                text: "Routinen" + (sidebar.routines.length > 0 ? "  (" + sidebar.routines.length + ")" : "")
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                font.bold: true
                opacity: 0.8

                MouseArea {
                    anchors.fill: parent
                    onClicked: sidebar.routinesToggleRequested(!sidebar.routinesOpen)
                }
            }

            QQC2.ToolButton {
                id: routineAddBtn
                icon.name: "list-add"
                display: QQC2.AbstractButton.IconOnly
                visible: sidebar.routinesOpen
                text: "Routine hinzufügen"
                onClicked: {
                    sidebar._routineConfirmId = ""
                    sidebar.routineAddRequested()
                }
                QQC2.ToolTip.text: "Neue Routine anlegen — oder sage Aurora im Chat, was sie regelmäßig tun soll"
                QQC2.ToolTip.visible: hovered
            }
        }

        // Routinen-Liste: kompakte Zeilen (Titel, Zeitplan + nächster Lauf,
        // Statusbadge). Klick öffnet den Bearbeiten-Dialog; Play führt außer
        // der Reihe aus; Delete mit Zwei-Klick-Bestätigung wie bei Chats.
        ListView {
            id: routineListView
            visible: sidebar.browseMode && sidebar.routinesOpen
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(contentHeight, sidebar.height * 0.35)
            interactive: contentHeight > height
            model: sidebar.routines
            clip: true
            spacing: 2

            delegate: Rectangle {
                id: routineDelegate
                required property var modelData
                required property int index
                // Test-Exposure (Konvention wie Header.qml)
                readonly property var _runBtn: runBtn
                readonly property var _deleteBtn: routineDeleteButton
                readonly property var _statusLabel: statusLabel
                function click() { routineRowMouse.clicked(null) }
                width: routineListView.width
                height: routineColumn.implicitHeight + Kirigami.Units.smallSpacing * 2
                radius: Kirigami.Units.smallSpacing
                color: routineHoverHandler.hovered
                    ? Theme.withAlpha(Kirigami.Theme.highlightColor, 0.15)
                    : "transparent"

                Behavior on color { ColorAnimation { duration: 100 } }

                RowLayout {
                    anchors.fill: parent
                    anchors.margins: Kirigami.Units.smallSpacing

                    ColumnLayout {
                        id: routineColumn
                        Layout.fillWidth: true
                        spacing: 0

                        QQC2.Label {
                            Layout.fillWidth: true
                            text: routineDelegate.modelData.title !== ""
                                  ? routineDelegate.modelData.title : "Routine"
                            elide: Text.ElideRight
                            color: routineDelegate.modelData.enabled
                                ? Kirigami.Theme.textColor
                                : Kirigami.Theme.disabledTextColor
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                        }

                        QQC2.Label {
                            id: statusLabel
                            Layout.fillWidth: true
                            // Laufender Lauf hat Vorrang vor dem nächsten Termin
                            text: routineDelegate.modelData.id === sidebar.runningRoutineId
                                ? "läuft …"
                                : routineDelegate.modelData.scheduleText + " · "
                                  + sidebar._routineNextText(routineDelegate.modelData)
                                  + (routineDelegate.modelData.lastStatus === "error"
                                     ? "  ⚠ letzter Lauf fehlgeschlagen" : "")
                            elide: Text.ElideRight
                            font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                            font.italic: routineDelegate.modelData.id === sidebar.runningRoutineId
                            opacity: 0.6
                            color: Kirigami.Theme.textColor
                        }
                    }

                    QQC2.ToolButton {
                        id: runBtn
                        Layout.preferredWidth: Kirigami.Units.iconSizes.small
                        Layout.preferredHeight: Kirigami.Units.iconSizes.small
                        icon.name: "media-playback-start"
                        display: QQC2.AbstractButton.IconOnly
                        visible: routineHoverHandler.hovered
                        enabled: routineDelegate.modelData.id !== sidebar.runningRoutineId
                        onClicked: sidebar.routineRunRequested(routineDelegate.modelData.id)
                        QQC2.ToolTip.text: "Jetzt ausführen"
                        QQC2.ToolTip.visible: hovered
                    }

                    QQC2.ToolButton {
                        Layout.preferredWidth: Kirigami.Units.iconSizes.small
                        Layout.preferredHeight: Kirigami.Units.iconSizes.small
                        icon.name: "document-edit"
                        display: QQC2.AbstractButton.IconOnly
                        visible: routineHoverHandler.hovered
                        onClicked: sidebar.routineEditRequested(routineDelegate.modelData)
                        QQC2.ToolTip.text: "Routine bearbeiten"
                        QQC2.ToolTip.visible: hovered
                    }

                    QQC2.ToolButton {
                        id: routineDeleteButton
                        readonly property bool armed: sidebar._routineConfirmId === routineDelegate.modelData.id
                        Layout.preferredWidth: Kirigami.Units.iconSizes.small
                        Layout.preferredHeight: Kirigami.Units.iconSizes.small
                        icon.name: armed ? "dialog-warning" : "edit-delete"
                        icon.color: armed ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.textColor
                        visible: routineHoverHandler.hovered || armed
                        onClicked: {
                            if (armed) {
                                sidebar._routineConfirmId = ""
                                sidebar.routineDeleteRequested(routineDelegate.modelData.id)
                            } else {
                                sidebar._routineConfirmId = routineDelegate.modelData.id
                            }
                        }
                        QQC2.ToolTip.text: armed ? "Routine wirklich löschen?" : "Routine löschen"
                        QQC2.ToolTip.visible: hovered
                    }
                }

                MouseArea {
                    id: routineRowMouse
                    anchors.fill: parent
                    z: -1
                    onClicked: sidebar.routineEditRequested(routineDelegate.modelData)
                }

                HoverHandler {
                    id: routineHoverHandler
                    onHoveredChanged: {
                        if (!hovered && sidebar._routineConfirmId === routineDelegate.modelData.id)
                            sidebar._routineConfirmId = ""
                    }
                }
            }

            // Leerzustand nur im aufgeklappten, nicht-laufenden Zustand —
            // Hinweis auf den natürlichen Weg, Routinen anzulegen (Chat).
            QQC2.Label {
                id: routineEmptyHint
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: parent.top
                anchors.topMargin: Kirigami.Units.smallSpacing * 2
                visible: sidebar.routines.length === 0
                text: "Noch keine Routinen — sage Aurora im Chat,\nwas sie regelmäßig tun soll."
                font.italic: true
                opacity: 0.5
                horizontalAlignment: Text.AlignHCenter
            }
        }

        // ==================== Sektion: Chats ====================
        Kirigami.Separator {
            Layout.fillWidth: true
            visible: sidebar.browseMode
        }

        RowLayout {
            Layout.fillWidth: true
            visible: sidebar.browseMode
            spacing: 0

            QQC2.ToolButton {
                id: chatsToggleBtn
                icon.name: sidebar.chatsOpen || sidebar.searching ? "arrow-down" : "arrow-right"
                display: QQC2.AbstractButton.IconOnly
                text: sidebar.chatsOpen ? "Chats einklappen" : "Chats ausklappen"
                onClicked: sidebar.chatsToggleRequested(!sidebar.chatsOpen)
                QQC2.ToolTip.text: text
                QQC2.ToolTip.visible: hovered
            }

            QQC2.Label {
                Layout.fillWidth: true
                text: "Chats"
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                font.bold: true
                opacity: 0.8

                MouseArea {
                    anchors.fill: parent
                    onClicked: sidebar.chatsToggleRequested(!sidebar.chatsOpen)
                }
            }
        }

        QQC2.Label {
            Layout.fillWidth: true
            visible: sidebar.searching && sidebar.searchResults.length === 0
            text: "Keine Treffer"
            font.italic: true
            opacity: 0.5
        }

        ListView {
            id: convListView
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: sidebar.chatsOpen || sidebar.searching
            model: sidebar.searching ? sidebar.searchResults : sidebar.conversations
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
                            // Liste ist nach updated_at (letzte Aktivität) sortiert —
                            // hier dasselbe Feld zeigen, sonst widerspricht das Datum
                            // der Reihenfolge. Fallback auf created_at zur Sicherheit
                            // (z. B. falls updated_at mal fehlt).
                            text: sidebar._prettyDate(modelData.updated_at || modelData.created_at)
                            font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                            opacity: 0.5
                            color: modelData.id === sidebar.currentId
                                ? Kirigami.Theme.highlightedTextColor
                                : Kirigami.Theme.textColor
                        }

                        // Snippet-Zeile: nur bei Inhalts-Treffern der Suche belegt
                        // (Titel-Treffer und die normale Liste haben kein snippet).
                        QQC2.Label {
                            Layout.fillWidth: true
                            visible: text !== ""
                            text: modelData.snippet || ""
                            elide: Text.ElideRight
                            font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                            font.italic: true
                            opacity: 0.5
                            color: modelData.id === sidebar.currentId
                                ? Kirigami.Theme.highlightedTextColor
                                : Kirigami.Theme.textColor
                        }
                    }

                    QQC2.ToolButton {
                        id: deleteButton
                        readonly property bool armed: sidebar._confirmId === modelData.id
                        Layout.preferredWidth: Kirigami.Units.iconSizes.small
                        Layout.preferredHeight: Kirigami.Units.iconSizes.small
                        icon.name: armed ? "dialog-warning" : "edit-delete"
                        icon.color: armed ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.textColor
                        visible: convHoverHandler.hovered || modelData.id === sidebar.currentId || armed
                        onClicked: {
                            if (armed) {
                                sidebar._confirmId = ""
                                sidebar.deleteRequested(modelData.id)
                            } else {
                                sidebar._confirmId = modelData.id
                            }
                        }
                        QQC2.ToolTip.text: armed ? "Wirklich löschen?" : "Konversation löschen"
                        QQC2.ToolTip.visible: hovered
                    }
                }

                HoverHandler {
                    id: convHoverHandler
                    onHoveredChanged: {
                        if (!hovered && sidebar._confirmId === modelData.id) {
                            sidebar._confirmId = ""
                        }
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    z: -1
                    onClicked: {
                        sidebar._confirmId = ""
                        sidebar.loadRequested(modelData.id)
                    }
                }
            }
        }
    }
}
