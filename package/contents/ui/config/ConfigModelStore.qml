import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM
import net.niuton.aurora.core
import net.niuton.aurora.engine

// Modell-Store: Ollama-Modelle per Klick installieren/aktualisieren/entfernen.
// Die gesamte Pull-/Lösch-Logik liegt im host-neutralen Engine-ModelStore
// (getestet in tst_modelstore); diese Seite ist reine Anzeige.
KCM.SimpleKCM {
    id: root

    ModelStore { id: store }

    // "local" | "remote" — Remote nur anbieten, wenn in den Modelleinstellungen aktiviert
    property string backend: "local"
    readonly property string backendUrl: backend === "remote"
        ? ConfigStore.value("remoteEndpoint") : "http://127.0.0.1:11434"
    readonly property bool remoteEnabled: (ConfigStore.revision, ConfigStore.value("remoteEnabled"))

    // Echter Backend-Bestand: [{name, sizeGB, caps}]
    property var installedEntries: []
    property string backendStatus: ""
    property string actionStatus: ""
    property bool actionIsError: false
    // Zwei-Klick-Bestätigung fürs Entfernen (Muster: Sidebar._confirmId)
    property string confirmTag: ""

    Component.onCompleted: {
        store.pullFinished.connect(_onPullFinished)
        refresh()
    }
    onBackendChanged: refresh()

    function isInstalled(tag) {
        for (var i = 0; i < installedEntries.length; i++)
            if (installedEntries[i].name === tag) return true
        return false
    }

    function _inCatalog(tag) {
        for (var i = 0; i < store.catalog.length; i++)
            if (store.catalog[i].tag === tag) return true
        return false
    }

    function refresh() {
        store.listInstalled(root.backendUrl, function(ok, entries) {
            root.installedEntries = entries
            root.backendStatus = ok ? "" : "Ollama nicht erreichbar (" + root.backendUrl + ")"
        })
    }

    function _startPull(tag) {
        root.actionStatus = ""
        root.confirmTag = ""
        store.pull(root.backendUrl, tag)
    }

    function _remove(tag) {
        store.remove(root.backendUrl, tag, function(ok, err) {
            root.actionIsError = !ok
            root.actionStatus = ok
                ? tag + " wurde entfernt."
                : "Entfernen fehlgeschlagen: " + err
            root.refresh()
        })
    }

    function _onPullFinished(ok, error) {
        if (ok) {
            root.actionIsError = false
            root.actionStatus = store.activeModel + " wurde installiert."
            refresh()
        } else {
            root.actionIsError = true
            root.actionStatus = "Download fehlgeschlagen: " + error
        }
    }

    function fmtGB(gb) {
        return (gb >= 10 ? Math.round(gb) : Math.round(gb * 10) / 10) + " GB"
    }

    function fmtBytes(b) {
        return fmtGB(b / 1e9)
    }

    // Fortschrittszeile eines laufenden Pulls (Katalog-Eintrag, Installiert-
    // Zeile und Freitext nutzen dieselbe Zeile — sichtbar ist nur die passende).
    component PullProgress: RowLayout {
        Layout.fillWidth: true
        spacing: Kirigami.Units.smallSpacing
        QQC2.ProgressBar {
            Layout.fillWidth: true
            from: 0
            to: 1
            value: store.progress
            indeterminate: store.totalBytes === 0
        }
        QQC2.Label {
            text: store.totalBytes > 0
                ? root.fmtBytes(store.completedBytes) + " / " + root.fmtBytes(store.totalBytes)
                : store.statusText
        }
        QQC2.Button {
            text: "Abbrechen"
            onClicked: store.cancelPull()
        }
    }

    // Aktions-Buttons für ein installiertes Modell (Katalog- und Bestandszeile):
    // Aktualisieren (Re-Pull) + Entfernen mit Zwei-Klick-Bestätigung.
    component InstalledActions: RowLayout {
        required property string tag
        QQC2.Button {
            text: "Aktualisieren"
            icon.name: "view-refresh"
            enabled: !store.busy && root.backendStatus === ""
            onClicked: root._startPull(tag)
        }
        QQC2.Button {
            text: root.confirmTag === tag ? "Wirklich entfernen?" : "Entfernen"
            enabled: !store.busy
            onClicked: {
                if (root.confirmTag === tag) {
                    root.confirmTag = ""
                    root._remove(tag)
                } else {
                    root.confirmTag = tag
                }
            }
        }
    }

    ColumnLayout {
        spacing: Kirigami.Units.largeSpacing

        RowLayout {
            visible: root.remoteEnabled
            QQC2.Label { text: "Backend:" }
            QQC2.ComboBox {
                model: ["Lokal", "Remote"]
                currentIndex: root.backend === "remote" ? 1 : 0
                enabled: !store.busy
                onActivated: root.backend = (currentIndex === 1 ? "remote" : "local")
            }
            QQC2.Label { text: root.backendUrl; opacity: 0.6 }
        }

        QQC2.Label {
            visible: root.backendStatus !== ""
            text: root.backendStatus
            color: Kirigami.Theme.negativeTextColor
            wrapMode: Text.Wrap
            Layout.maximumWidth: Kirigami.Units.gridUnit * 28
        }

        // Freitext: beliebiger Ollama-Tag außerhalb des Katalogs + Link zur Library
        RowLayout {
            Layout.fillWidth: true
            QQC2.TextField {
                id: freeTag
                Layout.fillWidth: true
                placeholderText: "beliebiges Modell, z. B. llama4:scout"
                onAccepted: if (freeInstall.enabled) freeInstall.clicked()
            }
            QQC2.Button {
                id: freeInstall
                text: "Installieren"
                enabled: freeTag.text.trim() !== "" && !store.busy && root.backendStatus === ""
                onClicked: root._startPull(freeTag.text.trim())
            }
            QQC2.Button {
                text: "Bibliothek"
                icon.name: "internet-web-browser"
                QQC2.ToolTip.text: "Alle verfügbaren Modelle auf ollama.com durchstöbern"
                QQC2.ToolTip.visible: hovered
                onClicked: Qt.openUrlExternally("https://ollama.com/library")
            }
        }

        // Fortschritt eines Pulls, der weder Katalog- noch Bestandszeile hat
        PullProgress {
            visible: store.busy && !root._inCatalog(store.activeModel) && !root.isInstalled(store.activeModel)
        }

        Kirigami.Separator { Layout.fillWidth: true }

        QQC2.Label {
            text: "Katalog"
            font.bold: true
        }

        Repeater {
            model: store.catalog

            delegate: ColumnLayout {
                id: entry
                required property var modelData
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.largeSpacing

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0
                        QQC2.Label {
                            text: entry.modelData.titel
                            font.bold: true
                        }
                        QQC2.Label {
                            font: Kirigami.Theme.smallFont
                            opacity: 0.7
                            text: entry.modelData.tag
                                + (entry.modelData.sizeLabel !== "" ? " · " + entry.modelData.sizeLabel : "")
                                + (entry.modelData.kontext !== "" ? " · " + entry.modelData.kontext + " Kontext" : "")
                        }
                        QQC2.Label {
                            Layout.fillWidth: true
                            text: entry.modelData.beschreibung
                            wrapMode: Text.Wrap
                            opacity: 0.85
                        }
                        QQC2.Label {
                            visible: entry.modelData.caps.length > 0
                            text: entry.modelData.caps.join(" · ")
                            font: Kirigami.Theme.smallFont
                            color: Kirigami.Theme.highlightColor
                        }
                    }

                    QQC2.Button {
                        visible: !root.isInstalled(entry.modelData.tag)
                            && !(store.busy && store.activeModel === entry.modelData.tag)
                        text: "Installieren"
                        enabled: !store.busy && root.backendStatus === ""
                        onClicked: root._startPull(entry.modelData.tag)
                    }

                    ColumnLayout {
                        visible: root.isInstalled(entry.modelData.tag)
                        spacing: Kirigami.Units.smallSpacing
                        QQC2.Label {
                            text: "Installiert ✓"
                            color: Kirigami.Theme.positiveTextColor
                        }
                        InstalledActions { tag: entry.modelData.tag }
                    }
                }

                PullProgress {
                    visible: store.busy && store.activeModel === entry.modelData.tag
                }

                Kirigami.Separator { Layout.fillWidth: true }
            }
        }

        QQC2.Label {
            text: "Auf diesem Backend installiert"
            font.bold: true
        }

        QQC2.Label {
            visible: root.installedEntries.length === 0 && root.backendStatus === ""
            text: "Keine Modelle installiert."
            opacity: 0.7
        }

        Repeater {
            model: root.installedEntries

            delegate: ColumnLayout {
                id: installedRow
                required property var modelData
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.largeSpacing

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0
                        QQC2.Label {
                            text: installedRow.modelData.name
                            font.bold: true
                        }
                        QQC2.Label {
                            font: Kirigami.Theme.smallFont
                            opacity: 0.7
                            text: root.fmtGB(installedRow.modelData.sizeGB)
                                + (installedRow.modelData.caps.length > 0
                                   ? " · " + installedRow.modelData.caps.join(" · ") : "")
                        }
                    }

                    InstalledActions { tag: installedRow.modelData.name }
                }

                PullProgress {
                    visible: store.busy && store.activeModel === installedRow.modelData.name
                }

                Kirigami.Separator { Layout.fillWidth: true }
            }
        }

        QQC2.Label {
            visible: root.actionStatus !== ""
            text: root.actionStatus
            wrapMode: Text.Wrap
            Layout.maximumWidth: Kirigami.Units.gridUnit * 28
            color: root.actionIsError ? Kirigami.Theme.negativeTextColor
                                      : Kirigami.Theme.positiveTextColor
        }

        QQC2.Label {
            text: "Hinweis: Den Dialog während des Downloads geöffnet lassen — Schließen bricht den Download ab (er lässt sich später fortsetzen). „Aktualisieren“ lädt die neueste Version eines Modells erneut herunter."
            wrapMode: Text.Wrap
            opacity: 0.7
            font: Kirigami.Theme.smallFont
            Layout.maximumWidth: Kirigami.Units.gridUnit * 28
        }
    }
}
