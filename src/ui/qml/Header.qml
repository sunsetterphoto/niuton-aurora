import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import net.niuton.aurora.ui

RowLayout {
    id: header

    // Zustand (von main.qml gebunden)
    property bool sidebarOpen: false
    property bool canNewChat: false
    property var pickerEntries: []
    property string selectedModel: "auto"
    property string activeModel: ""
    property bool isRemoteModel: false
    property bool modelLoaded: false
    property bool modelLoading: false
    property bool thinkingEnabled: false
    property bool isPinned: false
    property bool isLoading: false
    property bool ttsAvailable: false
    property bool autoSpeakEnabled: false
    property bool localOk: false
    property bool remoteOk: false
    property bool comfyOk: false
    property bool showPin: true
    property bool showConfigure: true
    property bool showTune: true

    // Aktionen
    signal toggleSidebar()
    signal newChatRequested()
    signal modelSelected(string value)
    signal thinkingToggled(bool on)
    signal autoSpeakToggled(bool on)
    signal pinToggled(bool on)
    signal memoryRequested()
    signal knowledgeRequested()
    signal configureRequested()
    signal tuneModelRequested()
    signal closeRequested()

    spacing: Kirigami.Units.smallSpacing

    QQC2.ToolButton {
        icon.name: "application-menu"
        onClicked: header.toggleSidebar()
        QQC2.ToolTip { text: header.sidebarOpen ? "Seitenleiste schließen" : "Seitenleiste öffnen"; visible: parent.hovered; delay: Kirigami.Units.toolTipDelay }
    }

    QQC2.ToolButton {
        icon.name: "list-add"
        enabled: header.canNewChat
        onClicked: header.newChatRequested()
        QQC2.ToolTip { text: "Neuer Chat"; visible: parent.hovered; delay: Kirigami.Units.toolTipDelay }
    }

    // Wortmarke mit Aurora-Gradient-Unterstreichung
    ColumnLayout {
        spacing: 1

        Kirigami.Heading {
            text: "Aurora"
            level: 3
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 2
            radius: 1
            opacity: header.isLoading ? 1.0 : 0.65
            Behavior on opacity { NumberAnimation { duration: 300 } }
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0;  color: Theme.auroraGreen }
                GradientStop { position: 0.35; color: Theme.auroraCyan }
                GradientStop { position: 0.7;  color: Theme.auroraBlue }
                GradientStop { position: 1.0;  color: Theme.auroraViolet }
            }
        }
    }

    Item { Layout.fillWidth: true }

    // Backend-Gesundheit: Lokal / Remote / ComfyUI
    Row {
        spacing: 3

        Repeater {
            model: [
                { "name": "Ollama lokal", "ok": header.localOk },
                { "name": "Ollama remote", "ok": header.remoteOk },
                { "name": "ComfyUI (Bilder)", "ok": header.comfyOk }
            ]
            delegate: Rectangle {
                required property var modelData
                width: 6
                height: 6
                anchors.verticalCenter: parent.verticalCenter
                radius: 3
                color: modelData.ok
                    ? Theme.withAlpha(Kirigami.Theme.positiveTextColor, 0.9)
                    : Theme.withAlpha(Kirigami.Theme.textColor, 0.25)
                HoverHandler { id: dotHover }
                QQC2.ToolTip {
                    text: modelData.name + (modelData.ok ? " · verbunden" : " · offline")
                    visible: dotHover.hovered
                    delay: Kirigami.Units.toolTipDelay
                }
            }
        }
    }

    // Status-LED (aktives Modell)
    Rectangle {
        width: Kirigami.Units.smallSpacing * 2
        height: width
        radius: width / 2
        color: header.modelLoading ? Kirigami.Theme.neutralTextColor
             : header.modelLoaded ? Kirigami.Theme.positiveTextColor
             : Kirigami.Theme.negativeTextColor
        HoverHandler { id: modelLedHover }
        QQC2.ToolTip {
            text: header.modelLoading ? "Modell wird geladen..."
                : header.modelLoaded ? header.activeModel + " bereit"
                : "Modell nicht geladen"
            visible: modelLedHover.hovered
            delay: Kirigami.Units.toolTipDelay
        }
    }

    // Model selector (gruppiert: Auto / Lokal / Remote)
    // currentIndex wird imperativ synchronisiert statt deklarativ gebunden:
    // QQC2.ComboBox schreibt currentIndex bei User-Aktivierung selbst imperativ,
    // was eine deklarative Bindung dauerhaft bricht — danach folgt sie externen
    // selectedModel-Änderungen (Auto-Wechsel, loadConversation) nicht mehr.
    function _syncCurrentIndex() {
        for (var i = 0; i < header.pickerEntries.length; i++) {
            if (header.pickerEntries[i].value === header.selectedModel) {
                modelSelector.currentIndex = i
                return
            }
        }
        modelSelector.currentIndex = 0
    }
    onSelectedModelChanged: _syncCurrentIndex()
    onPickerEntriesChanged: _syncCurrentIndex()

    QQC2.ComboBox {
        id: modelSelector
        Layout.preferredWidth: Kirigami.Units.gridUnit * 10
        model: header.pickerEntries
        displayText: header.selectedModel === "auto"
            ? "Auto · " + header.activeModel
            : (header.isRemoteModel ? "🌐 " : "") + header.activeModel
        Component.onCompleted: header._syncCurrentIndex()
        delegate: QQC2.ItemDelegate {
            required property var modelData
            required property int index
            width: modelSelector.width
            enabled: modelData.kind !== "header" && modelData.enabled !== false
            highlighted: modelSelector.highlightedIndex === index
            contentItem: QQC2.Label {
                text: modelData.label
                font.bold: modelData.kind === "header"
                font.pointSize: modelData.kind === "header"
                    ? Kirigami.Theme.smallFont.pointSize
                    : Kirigami.Theme.defaultFont.pointSize
                opacity: modelData.kind === "header" ? 0.6 : 1.0
                elide: Text.ElideRight
            }
        }
        onActivated: function(index) {
            var entry = header.pickerEntries[index]
            if (entry && entry.kind !== "header" && entry.enabled !== false)
                header.modelSelected(entry.value)
        }
    }

    QQC2.ToolButton {
        visible: header.showTune
        icon.name: "adjustlevels"
        display: QQC2.AbstractButton.IconOnly
        onClicked: header.tuneModelRequested()
        QQC2.ToolTip.text: "Modell-Parameter feintunen"
        QQC2.ToolTip.visible: hovered
    }

    // Thinking toggle
    QQC2.ToolButton {
        checked: header.thinkingEnabled
        checkable: true
        onToggled: header.thinkingToggled(checked)
        // qqc2-desktop-style faerbt icon.source-SVGs NICHT per icon.color ein (nur
        // themed icon.name-Symbole). Daher die eigene SVG ueber Kirigami.Icon mit
        // isMask als themen-eingefaerbte Maske rendern (currentColor -> textColor).
        contentItem: Kirigami.Icon {
            source: header.thinkingEnabled
                ? Qt.resolvedUrl("icons/thinking-on.svg")
                : Qt.resolvedUrl("icons/thinking-off.svg")
            isMask: true
            color: Kirigami.Theme.textColor
            implicitWidth: Kirigami.Units.iconSizes.smallMedium
            implicitHeight: Kirigami.Units.iconSizes.smallMedium
        }
        QQC2.ToolTip {
            text: header.thinkingEnabled ? "Denkprozess aktiv (langsamer, bessere Qualität)"
                                         : "Denkprozess aus (schneller)"
            visible: parent.hovered
            delay: Kirigami.Units.toolTipDelay
        }
    }

    // Auto-Vorlesen
    QQC2.ToolButton {
        visible: header.ttsAvailable
        icon.name: header.autoSpeakEnabled ? "audio-speakers-symbolic" : "audio-volume-muted"
        checked: header.autoSpeakEnabled
        checkable: true
        onToggled: header.autoSpeakToggled(checked)
        QQC2.ToolTip {
            text: header.autoSpeakEnabled ? "Antworten werden vorgelesen" : "Vorlesen aus"
            visible: parent.hovered
            delay: Kirigami.Units.toolTipDelay
        }
    }

    // Pin / unpin
    QQC2.ToolButton {
        visible: header.showPin
        icon.name: header.isPinned ? "window-pin" : "window-unpin"
        checked: header.isPinned
        checkable: true
        onToggled: header.pinToggled(checked)
        QQC2.ToolTip { text: header.isPinned ? "Angepinnt (bleibt offen)" : "Anpinnen"; visible: parent.hovered; delay: Kirigami.Units.toolTipDelay }
    }

    // Überlauf-Menü für seltene Aktionen
    QQC2.ToolButton {
        id: overflowButton
        icon.name: "overflow-menu"
        onClicked: overflowMenu.popup(overflowButton, 0, overflowButton.height)
        QQC2.ToolTip { text: "Mehr"; visible: parent.hovered; delay: Kirigami.Units.toolTipDelay }

        QQC2.Menu {
            id: overflowMenu

            QQC2.MenuItem {
                text: "Memory bearbeiten"
                icon.name: "document-edit"
                onTriggered: header.memoryRequested()
            }
            QQC2.MenuItem {
                text: "Wissensbasis"
                icon.name: "bookmarks"
                onTriggered: header.knowledgeRequested()
            }
            QQC2.MenuItem {
                text: "Einstellungen"
                icon.name: "configure"
                visible: header.showConfigure
                onTriggered: header.configureRequested()
            }
        }
    }

    // Close
    QQC2.ToolButton {
        icon.name: "window-close"
        onClicked: header.closeRequested()
        QQC2.ToolTip { text: "Schließen"; visible: parent.hovered; delay: Kirigami.Units.toolTipDelay }
    }
}
