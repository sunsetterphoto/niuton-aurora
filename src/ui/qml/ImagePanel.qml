import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import net.niuton.aurora.ui

// Bild-Modus: Prompt, Modell, Format, Seed -> ComfyUI
Rectangle {
    id: panel

    property bool busy: false
    property string statusText: ""
    property var models: []
    property string defaultModel: "z_image_turbo"

    signal generateRequested(var params)
    signal closeRequested()

    readonly property var sizePresets: [
        { "label": "1:1 · 1024×1024", "w": 1024, "h": 1024 },
        { "label": "16:9 · 1280×720", "w": 1280, "h": 720 },
        { "label": "9:16 · 720×1280", "w": 720, "h": 1280 },
        { "label": "3:2 · 1152×768", "w": 1152, "h": 768 }
    ]

    implicitHeight: panelColumn.implicitHeight + Kirigami.Units.smallSpacing * 2
    radius: Kirigami.Units.gridUnit * 0.6
    color: Theme.withAlpha(Kirigami.Theme.textColor, 0.05)
    border.width: 1
    border.color: Theme.withAlpha(Theme.auroraViolet, 0.45)

    function _generate() {
        if (promptField.text.trim() === "" || panel.busy) return
        var preset = sizePresets[sizeCombo.currentIndex]
        var seed = parseInt(seedField.text)
        panel.generateRequested({
            "prompt": promptField.text.trim(),
            "model": modelCombo.currentValue,
            "width": preset.w,
            "height": preset.h,
            "seed": isNaN(seed) ? 0 : seed
        })
    }

    ColumnLayout {
        id: panelColumn
        anchors.fill: parent
        anchors.margins: Kirigami.Units.smallSpacing
        spacing: Kirigami.Units.smallSpacing

        RowLayout {
            Layout.fillWidth: true

            Kirigami.Icon {
                source: "insert-image"
                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                Layout.preferredHeight: Kirigami.Units.iconSizes.small
            }
            QQC2.Label {
                text: "Bild generieren"
                font.bold: true
            }
            Item { Layout.fillWidth: true }
            QQC2.ToolButton {
                icon.name: "dialog-close"
                onClicked: panel.closeRequested()
                QQC2.ToolTip { text: "Zurück zum Chat"; visible: parent.hovered; delay: Kirigami.Units.toolTipDelay }
            }
        }

        QQC2.TextArea {
            id: promptField
            Layout.fillWidth: true
            Layout.preferredHeight: Kirigami.Units.gridUnit * 3
            placeholderText: "Beschreibe das Bild (englisch funktioniert am besten)..."
            wrapMode: TextEdit.Wrap
            enabled: !panel.busy
            Keys.onReturnPressed: function(event) {
                if (event.modifiers & Qt.ControlModifier) panel._generate()
                else event.accepted = false
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            QQC2.ComboBox {
                id: modelCombo
                Layout.preferredWidth: Kirigami.Units.gridUnit * 9
                textRole: "label"
                valueRole: "value"
                model: panel.models
                enabled: !panel.busy
                Component.onCompleted: currentIndex = Math.max(0, indexOfValue(panel.defaultModel))
            }

            QQC2.ComboBox {
                id: sizeCombo
                Layout.preferredWidth: Kirigami.Units.gridUnit * 8
                model: panel.sizePresets.map(function(p) { return p.label })
                enabled: !panel.busy
            }

            QQC2.TextField {
                id: seedField
                Layout.preferredWidth: Kirigami.Units.gridUnit * 5
                placeholderText: "Seed (zufällig)"
                validator: IntValidator { bottom: 0 }
                enabled: !panel.busy
            }

            Item { Layout.fillWidth: true }

            QQC2.Button {
                icon.name: panel.busy ? "media-playback-stop" : "media-playback-start"
                text: panel.busy ? "Läuft..." : "Generieren"
                enabled: !panel.busy && promptField.text.trim() !== ""
                onClicked: panel._generate()
            }
        }

        RowLayout {
            Layout.fillWidth: true
            visible: panel.busy
            spacing: Kirigami.Units.smallSpacing

            QQC2.BusyIndicator {
                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                Layout.preferredHeight: Kirigami.Units.iconSizes.small
                running: true
            }
            QQC2.Label {
                text: panel.statusText || "Generiere..."
                font.italic: true
                opacity: 0.7
            }
        }
    }
}
