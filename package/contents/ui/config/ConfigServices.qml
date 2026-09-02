import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM
import net.niuton.aurora.core
import net.niuton.aurora.engine

// Dienste-Seite: lokale Quadlet-Dienste (ComfyUI, Speaches) starten/stoppen
// und ihren Gesundheitszustand sehen. Logik liegt im Engine-ServiceManager
// (getestet in tst_servicemanager); diese Seite ist reine Anzeige.
KCM.SimpleKCM {
    id: root

    // Die Endpunkte stehen in den Settings; der Manager leitet seine
    // Dienstliste daraus ab (statt sie fest verdrahtet zu haben).
    AuroraSettings { id: cfg }
    ServiceManager { id: svc; settings: cfg }

    property string actionMessage: ""
    property bool actionIsError: false

    Component.onCompleted: {
        svc.actionFinished.connect(_onAction)
        svc.refresh()
        refreshTimer.start()
    }

    function _onAction(id, ok, msg) {
        if (msg === "") {
            root.actionIsError = false
            root.actionMessage = ok ? "Dienst „" + id + "“ ist bereit." : ""
            return
        }
        root.actionIsError = !ok
        root.actionMessage = msg
    }

    function _stateText(id) {
        var s = svc.stateOf(id)
        // Entfernte Instanz: hier gibt es keine Unit — nur Erreichbarkeit.
        if (s === "remote")
            return svc.healthyOf(id) ? "erreichbar (anderer Rechner)"
                                     : "nicht erreichbar (anderer Rechner)"
        if (s === "active") return svc.healthyOf(id) ? "läuft (gesund)" : "läuft (Health ausstehend)"
        if (s === "starting") return "startet …"
        if (s === "stopping") return "stoppt …"
        if (s === "failed") return "fehlgeschlagen"
        if (s === "inactive") return "gestoppt"
        return "unbekannt"
    }

    function _stateColor(id) {
        var s = svc.stateOf(id)
        if (s === "remote") return svc.healthyOf(id) ? Kirigami.Theme.positiveTextColor
                                                     : Kirigami.Theme.disabledTextColor
        if (s === "active") return svc.healthyOf(id) ? Kirigami.Theme.positiveTextColor
                                                     : Kirigami.Theme.neutralTextColor
        if (s === "starting" || s === "stopping") return Kirigami.Theme.neutralTextColor
        if (s === "failed") return Kirigami.Theme.negativeTextColor
        return Kirigami.Theme.disabledTextColor
    }

    Timer {
        id: refreshTimer
        interval: 5000
        repeat: true
        onTriggered: svc.refresh()
    }

    ColumnLayout {
        spacing: Kirigami.Units.largeSpacing

        Repeater {
            model: svc.services

            delegate: RowLayout {
                id: svcRow
                required property var modelData
                Layout.fillWidth: true
                spacing: Kirigami.Units.largeSpacing

                Rectangle {
                    width: Kirigami.Units.gridUnit * 0.8
                    height: width
                    radius: width / 2
                    color: root._stateColor(svcRow.modelData.id)
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    QQC2.Label {
                        text: svcRow.modelData.label
                        font.bold: true
                    }
                    QQC2.Label {
                        font: Kirigami.Theme.smallFont
                        opacity: 0.7
                        text: root._stateText(svcRow.modelData.id) + " · " + svcRow.modelData.endpoint
                    }
                }

                QQC2.Button {
                    text: "Starten"
                    // Entfernte Dienste lassen sich von hier nicht schalten.
                    visible: svcRow.modelData.manageable
                        && svc.stateOf(svcRow.modelData.id) !== "active"
                    enabled: !svc.busyOf(svcRow.modelData.id)
                        && svc.stateOf(svcRow.modelData.id) !== "starting"
                    onClicked: svc.start(svcRow.modelData.id)
                }
                QQC2.Button {
                    text: "Stoppen"
                    visible: svcRow.modelData.manageable
                        && svc.stateOf(svcRow.modelData.id) === "active"
                    enabled: !svc.busyOf(svcRow.modelData.id)
                    onClicked: svc.stop(svcRow.modelData.id)
                }
            }
        }

        QQC2.Label {
            visible: root.actionMessage !== ""
            text: root.actionMessage
            wrapMode: Text.Wrap
            Layout.maximumWidth: Kirigami.Units.gridUnit * 28
            color: root.actionIsError ? Kirigami.Theme.negativeTextColor
                                      : Kirigami.Theme.positiveTextColor
        }

        Kirigami.Separator { Layout.fillWidth: true }

        Kirigami.FormLayout {
            Kirigami.Separator {
                Kirigami.FormData.isSection: true
                Kirigami.FormData.label: "Speaches (Spracheingabe/-ausgabe)"
            }

            QQC2.CheckBox {
                Kirigami.FormData.label: "Speaches nutzen:"
                text: "Aktiviert (Fallback: lokale Skripte)"
                checked: (ConfigStore.revision, ConfigStore.value("speachesEnabled"))
                onToggled: ConfigStore.setValue("speachesEnabled", checked)
            }

            QQC2.TextField {
                Kirigami.FormData.label: "Endpoint:"
                Layout.fillWidth: true
                text: (ConfigStore.revision, ConfigStore.value("speachesEndpoint"))
                onEditingFinished: ConfigStore.setValue("speachesEndpoint", text.trim())
            }

            QQC2.TextField {
                Kirigami.FormData.label: "STT-Modell:"
                Layout.fillWidth: true
                text: (ConfigStore.revision, ConfigStore.value("speachesSttModel"))
                onEditingFinished: ConfigStore.setValue("speachesSttModel", text.trim())
                QQC2.ToolTip.text: "faster-whisper-Modell auf dem Speaches-Server (wird beim ersten Diktat geladen)"
                QQC2.ToolTip.visible: hovered
            }
        }

        Kirigami.FormLayout {
            Kirigami.Separator {
                Kirigami.FormData.isSection: true
                Kirigami.FormData.label: "Verhalten"
            }

            QQC2.CheckBox {
                Kirigami.FormData.label: "Auto-Start:"
                text: "Dienste bei Bedarf automatisch starten"
                checked: (ConfigStore.revision, ConfigStore.value("servicesAutoStart"))
                onToggled: ConfigStore.setValue("servicesAutoStart", checked)
                QQC2.ToolTip.text: "Startet ComfyUI/Speaches automatisch, wenn ein Feature sie braucht (hält die dGPU wach, solange sie laufen)"
                QQC2.ToolTip.visible: hovered
            }
        }

        QQC2.Label {
            text: "Hinweis: Die Dienste sind rootless Podman-Quadlets (systemd-User). Bewusst kein Autostart beim Login — sie halten die dGPU wach, solange sie laufen. Manuell auch per Terminal: systemctl --user start|stop comfyui|speaches"
            wrapMode: Text.Wrap
            opacity: 0.7
            font: Kirigami.Theme.smallFont
            Layout.maximumWidth: Kirigami.Units.gridUnit * 28
        }
    }
}
