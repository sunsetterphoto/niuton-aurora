import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM
import net.niuton.aurora.core

KCM.SimpleKCM {
    id: root

    readonly property var permOptions: ["auto", "confirm", "off"]
    readonly property var permLabels: ["Automatisch", "Mit Bestätigung", "Deaktiviert"]

    Kirigami.FormLayout {
        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: "Sichere Tools (nur lesen)"
        }

        QQC2.ComboBox {
            id: webSearchCombo
            Kirigami.FormData.label: "Web-Suche:"
            model: root.permLabels
            Component.onCompleted: currentIndex = root.permOptions.indexOf(ConfigStore.value("toolWebSearch"))
            onActivated: ConfigStore.setValue("toolWebSearch", root.permOptions[currentIndex])
        }

        QQC2.ComboBox {
            id: readFileCombo
            Kirigami.FormData.label: "Datei lesen:"
            model: root.permLabels
            Component.onCompleted: currentIndex = root.permOptions.indexOf(ConfigStore.value("toolReadFile"))
            onActivated: ConfigStore.setValue("toolReadFile", root.permOptions[currentIndex])
        }

        QQC2.ComboBox {
            id: listDirCombo
            Kirigami.FormData.label: "Verzeichnis auflisten:"
            model: root.permLabels
            Component.onCompleted: currentIndex = root.permOptions.indexOf(ConfigStore.value("toolListDir"))
            onActivated: ConfigStore.setValue("toolListDir", root.permOptions[currentIndex])
        }

        QQC2.ComboBox {
            id: webFetchCombo
            Kirigami.FormData.label: "Webseite abrufen:"
            model: root.permLabels
            Component.onCompleted: currentIndex = root.permOptions.indexOf(ConfigStore.value("toolWebFetch"))
            onActivated: ConfigStore.setValue("toolWebFetch", root.permOptions[currentIndex])
        }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: "Schreibende Tools (Systemänderungen)"
        }

        QQC2.ComboBox {
            id: writeFileCombo
            Kirigami.FormData.label: "Datei schreiben:"
            model: root.permLabels
            Component.onCompleted: currentIndex = root.permOptions.indexOf(ConfigStore.value("toolWriteFile"))
            onActivated: ConfigStore.setValue("toolWriteFile", root.permOptions[currentIndex])
        }

        QQC2.ComboBox {
            id: runCommandCombo
            Kirigami.FormData.label: "Befehl ausführen:"
            model: root.permLabels
            Component.onCompleted: currentIndex = root.permOptions.indexOf(ConfigStore.value("toolRunCommand"))
            onActivated: ConfigStore.setValue("toolRunCommand", root.permOptions[currentIndex])
        }
    }
}
