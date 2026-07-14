import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM
import net.niuton.aurora.core

KCM.SimpleKCM {
    id: root

    property string statusMessage: ""

    Kirigami.FormLayout {
        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: "Daten"
        }

        QQC2.Button {
            Kirigami.FormData.label: "Konversationen:"
            text: "Alle Konversationen löschen"
            icon.name: "edit-delete"
            onClicked: {
                deleteDialog.what = "conversations"
                deleteDialog.open()
            }
        }

        QQC2.Button {
            Kirigami.FormData.label: "Memory:"
            text: "Memory zurücksetzen"
            icon.name: "edit-clear-history"
            onClicked: {
                deleteDialog.what = "memory"
                deleteDialog.open()
            }
        }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: "Einstellungen"
        }

        QQC2.Button {
            Kirigami.FormData.label: "Zurücksetzen:"
            text: "Alle Einstellungen zurücksetzen"
            icon.name: "edit-undo"
            onClicked: {
                deleteDialog.what = "settings"
                deleteDialog.open()
            }
        }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: "Chat"
        }

        QQC2.CheckBox {
            Kirigami.FormData.label: "Tool-Aufrufe:"
            text: "Zwei-Phasen-Fallback (kein Streaming, wenn Tools aktiv sind)"
            checked: (ConfigStore.revision, ConfigStore.value("twoPhaseToolCalls"))
            onToggled: ConfigStore.setValue("twoPhaseToolCalls", checked)
        }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: "Wissensbasis"
        }

        QQC2.TextField {
            Kirigami.FormData.label: "Embedding-Modell:"
            text: (ConfigStore.revision, ConfigStore.value("embedModel"))
            onEditingFinished: ConfigStore.setValue("embedModel", text)
            QQC2.ToolTip.text: "Modell für die Einbettung bewerteter Antworten (muss auf dem aktiven Ollama-Backend vorhanden sein)"
            QQC2.ToolTip.visible: hovered
        }

        QQC2.Label {
            visible: statusMessage !== ""
            text: statusMessage
            color: statusMessage.indexOf("Fehler") === 0 ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.positiveTextColor
            wrapMode: Text.Wrap
        }
    }

    QQC2.Dialog {
        id: deleteDialog
        property string what: ""
        title: "Bestätigung"
        modal: true
        standardButtons: QQC2.Dialog.Ok | QQC2.Dialog.Cancel
        contentItem: QQC2.Label {
            text: {
                if (deleteDialog.what === "conversations") return "Alle Konversationen unwiderruflich löschen?"
                if (deleteDialog.what === "memory") return "Memory auf Standard zurücksetzen?"
                if (deleteDialog.what === "settings") return "Alle Einstellungen auf Standardwerte zurücksetzen?"
                return ""
            }
            wrapMode: Text.Wrap
        }
        onAccepted: {
            if (what === "conversations") {
                var openResult = ConversationStore.open()
                if (!openResult.ok) {
                    root.statusMessage = "Fehler: Konversations-Datenbank konnte nicht geöffnet werden (" + openResult.error + ")."
                    return
                }
                var convs = ConversationStore.listConversations()
                for (var i = 0; i < convs.length; i++)
                    ConversationStore.deleteConversation(convs[i].id)
                root.statusMessage = "Konversationen gelöscht. Widget neu öffnen."
            } else if (what === "memory") {
                var writeResult = FileIO.writeText(FileIO.standardPath("appData") + "/memory.md", "")
                if (!writeResult.ok) {
                    root.statusMessage = "Fehler: Memory konnte nicht zurückgesetzt werden (" + writeResult.error + ")."
                    return
                }
                root.statusMessage = "Memory zurückgesetzt. Widget neu öffnen."
            } else if (what === "settings") {
                ConfigStore.reset()
                root.statusMessage = "Einstellungen zurückgesetzt."
            }
        }
    }
}
