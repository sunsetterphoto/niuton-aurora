import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import net.niuton.aurora.ui

// Wissensbasis-Verwaltung: zwei Abschnitte — manuell kuratierte Einträge
// ("Meine Einträge": Link/Notiz/Fakt mit Titel/URL/Inhalt) und die mit 👍
// bewerteten Antworten ("Bewertete Antworten"). Dumb-View: property-in
// (manualEntries/examples) / signal-out. add/edit/removeEntry betreffen die
// manuellen Einträge, removeRequested die bewerteten Antworten.
Rectangle {
    id: knowledge

    property var manualEntries: []
    property var examples: []

    signal addRequested(string kind, string title, string url, string content)
    signal editRequested(string id, string kind, string title, string url, string content)
    signal removeEntryRequested(string id)
    signal removeRequested(string msgId)
    signal closeRequested()

    // Formular-Zustand
    property bool _formOpen: false
    property string _editingId: ""        // "" = Neu-Modus, sonst Bearbeiten

    clip: true
    color: Theme.withAlpha(Kirigami.Theme.textColor, 0.03)
    radius: Kirigami.Units.smallSpacing

    // ---- Art-Enum <-> Anzeige ----
    readonly property var _kinds: [
        { "value": "link", "text": "Link" },
        { "value": "note", "text": "Notiz" },
        { "value": "fact", "text": "Fakt" }
    ]
    function _kindLabel(kind) {
        for (var i = 0; i < _kinds.length; i++) if (_kinds[i].value === kind) return _kinds[i].text
        return kind
    }
    function _kindIndex(kind) {
        for (var i = 0; i < _kinds.length; i++) if (_kinds[i].value === kind) return i
        return 0
    }
    function _kindIcon(kind) {
        if (kind === "link") return "link"
        if (kind === "fact") return "documentinfo"
        return "view-pim-notes"          // Notiz
    }

    // ---- Text-Helfer ----
    function _pretty(iso) {
        var d = new Date(iso)
        if (isNaN(d.getTime())) return ""
        return Qt.formatDateTime(d, "dd.MM.yyyy HH:mm")
    }
    function _short(s, n) {
        s = String(s || "").replace(/\s+/g, " ").trim()
        return s.length > n ? s.substring(0, n) + "…" : s
    }
    function _canSave(kind, title, url, content) {
        if (String(url || "").trim() !== "") return true
        return String(title || "").trim() !== "" || String(content || "").trim() !== ""
    }

    // ---- Formular-Steuerung ----
    function _startAdd() {
        _editingId = ""
        kindCombo.currentIndex = 0
        titleField.text = ""
        urlField.text = ""
        contentArea.text = ""
        _formOpen = true
    }
    function _startEdit(entry) {
        _editingId = entry.id
        kindCombo.currentIndex = _kindIndex(entry.kind)
        titleField.text = entry.title || ""
        urlField.text = entry.url || ""
        contentArea.text = entry.content || ""
        _formOpen = true
    }
    function _cancel() { _formOpen = false; _editingId = "" }
    function _emitSave(kind, title, url, content) {
        if (!_canSave(kind, title, url, content)) return
        if (_editingId === "") knowledge.addRequested(kind, title, url, content)
        else knowledge.editRequested(_editingId, kind, title, url, content)
        _formOpen = false
        _editingId = ""
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Kirigami.Units.smallSpacing
        spacing: Kirigami.Units.smallSpacing

        // ---- Kopfzeile ----
        RowLayout {
            Layout.fillWidth: true
            Kirigami.Heading { level: 4; text: "Wissensbasis"; Layout.fillWidth: true }
            QQC2.ToolButton {
                icon.name: "list-add"
                onClicked: knowledge._startAdd()
                QQC2.ToolTip.text: "Eintrag hinzufügen"
                QQC2.ToolTip.visible: hovered
            }
            QQC2.ToolButton {
                icon.name: "window-close"
                onClicked: knowledge.closeRequested()
                QQC2.ToolTip.text: "Schließen"
                QQC2.ToolTip.visible: hovered
            }
        }

        Kirigami.Separator { Layout.fillWidth: true }

        // ---- Formular (Neu/Bearbeiten) ----
        Rectangle {
            Layout.fillWidth: true
            visible: knowledge._formOpen
            radius: Kirigami.Units.smallSpacing
            color: Theme.withAlpha(Kirigami.Theme.textColor, 0.05)
            border.color: Theme.withAlpha(Theme.auroraCyan, 0.45)
            border.width: 1
            implicitHeight: formColumn.implicitHeight + Kirigami.Units.smallSpacing * 2

            ColumnLayout {
                id: formColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.smallSpacing

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing
                    QQC2.ComboBox {
                        id: kindCombo
                        model: knowledge._kinds
                        textRole: "text"
                        valueRole: "value"
                    }
                    QQC2.TextField {
                        id: titleField
                        Layout.fillWidth: true
                        placeholderText: "Titel"
                    }
                }
                QQC2.TextField {
                    id: urlField
                    Layout.fillWidth: true
                    placeholderText: "URL (optional)"
                    inputMethodHints: Qt.ImhUrlCharactersOnly | Qt.ImhNoAutoUppercase
                }
                QQC2.TextArea {
                    id: contentArea
                    Layout.fillWidth: true
                    Layout.preferredHeight: Kirigami.Units.gridUnit * 4
                    placeholderText: "Inhalt"
                    wrapMode: TextEdit.Wrap
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing
                    Item { Layout.fillWidth: true }
                    QQC2.Button {
                        text: "Abbrechen"
                        onClicked: knowledge._cancel()
                    }
                    QQC2.Button {
                        text: "Speichern"
                        highlighted: true
                        enabled: knowledge._canSave(kindCombo.currentValue, titleField.text,
                                                     urlField.text, contentArea.text)
                        onClicked: knowledge._emitSave(kindCombo.currentValue, titleField.text,
                                                       urlField.text, contentArea.text)
                    }
                }
            }
        }

        // ---- Zwei Abschnitte, gemeinsam scrollend ----
        QQC2.ScrollView {
            id: scroll
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true

            ColumnLayout {
                width: scroll.availableWidth
                spacing: Kirigami.Units.smallSpacing

                // ==== Abschnitt: Meine Einträge ====
                QQC2.Label {
                    Layout.fillWidth: true
                    text: "Meine Einträge (" + knowledge.manualEntries.length + ")"
                    font.bold: true
                    opacity: 0.7
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                }
                QQC2.Label {
                    Layout.fillWidth: true
                    visible: knowledge.manualEntries.length === 0
                    text: "Noch keine eigenen Einträge. Mit „+“ Links oder Infos sammeln."
                    wrapMode: Text.Wrap
                    opacity: 0.6
                }
                Repeater {
                    model: knowledge.manualEntries
                    delegate: Rectangle {
                        required property var modelData
                        Layout.fillWidth: true
                        implicitHeight: entryRow.implicitHeight + Kirigami.Units.smallSpacing * 2
                        radius: Kirigami.Units.smallSpacing
                        color: entryHover.hovered
                            ? Theme.withAlpha(Kirigami.Theme.highlightColor, 0.12)
                            : Theme.withAlpha(Kirigami.Theme.textColor, 0.04)
                        Behavior on color { ColorAnimation { duration: 100 } }

                        RowLayout {
                            id: entryRow
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.margins: Kirigami.Units.smallSpacing
                            spacing: Kirigami.Units.smallSpacing

                            Kirigami.Icon {
                                source: knowledge._kindIcon(modelData.kind)
                                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                                Layout.preferredHeight: Kirigami.Units.iconSizes.small
                                Layout.alignment: Qt.AlignTop
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 1

                                QQC2.Label {
                                    Layout.fillWidth: true
                                    text: knowledge._short(modelData.title, 90)
                                    font.bold: true
                                    elide: Text.ElideRight
                                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                                }
                                QQC2.Label {
                                    Layout.fillWidth: true
                                    visible: String(modelData.content || "") !== ""
                                    text: knowledge._short(modelData.content, 120)
                                    wrapMode: Text.Wrap
                                    maximumLineCount: 2
                                    elide: Text.ElideRight
                                    opacity: 0.75
                                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                                }
                                QQC2.Label {
                                    Layout.fillWidth: true
                                    visible: String(modelData.url || "") !== ""
                                    text: knowledge._short(modelData.url, 80)
                                    color: Kirigami.Theme.linkColor
                                    elide: Text.ElideRight
                                    opacity: 0.85
                                    font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                                    font.underline: urlHover.hovered
                                    HoverHandler { id: urlHover; cursorShape: Qt.PointingHandCursor }
                                    TapHandler { onTapped: Qt.openUrlExternally(modelData.url) }
                                }
                                RowLayout {
                                    spacing: Kirigami.Units.smallSpacing
                                    QQC2.Label {
                                        text: knowledge._kindLabel(modelData.kind) + " · " + knowledge._pretty(modelData.createdAt)
                                        opacity: 0.5
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                                    }
                                    QQC2.Label {
                                        visible: modelData.hasEmbedding === false
                                        text: "· nicht eingebettet"
                                        color: Kirigami.Theme.neutralTextColor
                                        opacity: 0.85
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                                    }
                                }
                            }

                            QQC2.ToolButton {
                                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                                Layout.preferredHeight: Kirigami.Units.iconSizes.small
                                Layout.alignment: Qt.AlignTop
                                icon.name: "document-edit"
                                visible: entryHover.hovered
                                onClicked: knowledge._startEdit(modelData)
                                QQC2.ToolTip.text: "Bearbeiten"
                                QQC2.ToolTip.visible: hovered
                            }
                            QQC2.ToolButton {
                                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                                Layout.preferredHeight: Kirigami.Units.iconSizes.small
                                Layout.alignment: Qt.AlignTop
                                icon.name: "edit-delete"
                                visible: entryHover.hovered
                                onClicked: knowledge.removeEntryRequested(modelData.id)
                                QQC2.ToolTip.text: "Eintrag entfernen"
                                QQC2.ToolTip.visible: hovered
                            }
                        }
                        HoverHandler { id: entryHover }
                    }
                }

                Kirigami.Separator { Layout.fillWidth: true; Layout.topMargin: Kirigami.Units.smallSpacing }

                // ==== Abschnitt: Bewertete Antworten ====
                QQC2.Label {
                    Layout.fillWidth: true
                    text: "Bewertete Antworten (" + knowledge.examples.length + ")"
                    font.bold: true
                    opacity: 0.7
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                }
                QQC2.Label {
                    Layout.fillWidth: true
                    visible: knowledge.examples.length === 0
                    text: "Noch keine bewerteten Antworten. Gib einer Antwort ein 👍, um sie hier zu sammeln."
                    wrapMode: Text.Wrap
                    opacity: 0.6
                }
                Repeater {
                    model: knowledge.examples
                    delegate: Rectangle {
                        required property var modelData
                        Layout.fillWidth: true
                        implicitHeight: exampleColumn.implicitHeight + Kirigami.Units.smallSpacing * 2
                        radius: Kirigami.Units.smallSpacing
                        color: exampleHover.hovered
                            ? Theme.withAlpha(Kirigami.Theme.highlightColor, 0.12)
                            : Theme.withAlpha(Kirigami.Theme.textColor, 0.04)
                        Behavior on color { ColorAnimation { duration: 100 } }

                        RowLayout {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.margins: Kirigami.Units.smallSpacing
                            spacing: Kirigami.Units.smallSpacing

                            ColumnLayout {
                                id: exampleColumn
                                Layout.fillWidth: true
                                spacing: 1

                                QQC2.Label {
                                    Layout.fillWidth: true
                                    text: knowledge._short(modelData.question, 90)
                                    font.bold: true
                                    elide: Text.ElideRight
                                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                                }
                                QQC2.Label {
                                    Layout.fillWidth: true
                                    text: knowledge._short(modelData.answer, 120)
                                    wrapMode: Text.Wrap
                                    maximumLineCount: 2
                                    elide: Text.ElideRight
                                    opacity: 0.75
                                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                                }
                                RowLayout {
                                    spacing: Kirigami.Units.smallSpacing
                                    QQC2.Label {
                                        text: (modelData.model || "") + " · " + knowledge._pretty(modelData.createdAt)
                                        opacity: 0.5
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                                    }
                                    QQC2.Label {
                                        visible: modelData.hasEmbedding === false
                                        text: "· nicht eingebettet"
                                        color: Kirigami.Theme.neutralTextColor
                                        opacity: 0.85
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                                    }
                                }
                            }

                            QQC2.ToolButton {
                                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                                Layout.preferredHeight: Kirigami.Units.iconSizes.small
                                Layout.alignment: Qt.AlignTop
                                icon.name: "edit-delete"
                                visible: exampleHover.hovered
                                onClicked: knowledge.removeRequested(modelData.id)
                                QQC2.ToolTip.text: "Aus der Wissensbasis entfernen"
                                QQC2.ToolTip.visible: hovered
                            }
                        }
                        HoverHandler { id: exampleHover }
                    }
                }
            }
        }
    }
}
