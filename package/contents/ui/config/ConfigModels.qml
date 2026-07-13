import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM
import net.niuton.aurora.core

KCM.SimpleKCM {
    id: root

    property var localModelNames: []
    property string testStatus: ""

    Component.onCompleted: refreshLocalModels()

    function refreshLocalModels() {
        Http.getJson("http://127.0.0.1:11434/api/tags", function(res) {
            if (!res.ok) return
            var names = []
            var list = (res.data && res.data.models) || []
            for (var i = 0; i < list.length; i++) {
                if (list[i].name.indexOf("embed") === -1) names.push(list[i].name)
            }
            root.localModelNames = names
        })
    }

    function testRemote(url) {
        testStatus = "Teste Verbindung zu " + url + " ..."
        Http.getJson(url + "/api/tags", function(res) {
            if (res.ok) {
                var names = ((res.data && res.data.models) || []).map(function(m) { return m.name })
                testStatus = "Verbunden! " + names.length + " Modelle:\n" + names.join(", ")
            } else if (res.status > 0) {
                testStatus = "Nicht erreichbar (HTTP " + res.status + ")"
            } else {
                testStatus = "Nicht erreichbar (" + (res.error || "keine Verbindung") + ")"
            }
        })
    }

    // ComboBox, die eine Modell-Config-Eigenschaft direkt im ConfigStore haelt.
    // editable + localModelNames kommt async -> Nutzer tippt oft frei; onActivated
    // (Popup-Auswahl) reicht daher nicht, onAccepted (Enter) persistiert Getipptes.
    component ModelCombo: QQC2.ComboBox {
        property string configKey
        editable: true
        model: root.localModelNames
        Layout.fillWidth: true
        onModelChanged: {
            editText = ConfigStore.value(configKey)
            var idx = find(editText)
            if (idx >= 0) currentIndex = idx
        }
        Component.onCompleted: editText = ConfigStore.value(configKey)
        onActivated: ConfigStore.setValue(configKey, currentText)
        onAccepted: ConfigStore.setValue(configKey, editText)
    }

    Kirigami.FormLayout {
        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: "Auto-Modus: Energieprofil → lokales Modell"
        }

        ModelCombo {
            Kirigami.FormData.label: "Energiesparen:"
            configKey: "modelLowPower"
        }

        ModelCombo {
            Kirigami.FormData.label: "Ausgeglichen:"
            configKey: "modelBalanced"
        }

        ModelCombo {
            Kirigami.FormData.label: "Leistung:"
            configKey: "modelPerformance"
        }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: "Remote-Backend (Ollama)"
        }

        QQC2.CheckBox {
            id: remoteEnabledBox
            Kirigami.FormData.label: "Remote Backend:"
            text: "Aktiviert"
            checked: (ConfigStore.revision, ConfigStore.value("remoteEnabled"))
            onToggled: ConfigStore.setValue("remoteEnabled", checked)
        }

        RowLayout {
            Kirigami.FormData.label: "Endpoint (LAN):"
            QQC2.TextField {
                id: endpointField
                Layout.fillWidth: true
                placeholderText: "http://192.168.1.10:11434"
                text: (ConfigStore.revision, ConfigStore.value("remoteEndpoint"))
                onEditingFinished: ConfigStore.setValue("remoteEndpoint", text)
                enabled: remoteEnabledBox.checked
            }
            QQC2.Button {
                text: "Testen"
                enabled: remoteEnabledBox.checked && endpointField.text.trim() !== ""
                onClicked: root.testRemote(endpointField.text.trim())
            }
        }

        RowLayout {
            Kirigami.FormData.label: "Fallback (WLAN):"
            QQC2.TextField {
                id: fallbackField
                Layout.fillWidth: true
                placeholderText: "http://192.168.1.11:11434"
                text: (ConfigStore.revision, ConfigStore.value("remoteEndpointFallback"))
                onEditingFinished: ConfigStore.setValue("remoteEndpointFallback", text)
                enabled: remoteEnabledBox.checked
            }
            QQC2.Button {
                text: "Testen"
                enabled: remoteEnabledBox.checked && fallbackField.text.trim() !== ""
                onClicked: root.testRemote(fallbackField.text.trim())
            }
        }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: "Bildgenerierung (ComfyUI)"
        }

        QQC2.CheckBox {
            id: comfyEnabledBox
            Kirigami.FormData.label: "ComfyUI:"
            text: "Aktiviert"
            checked: (ConfigStore.revision, ConfigStore.value("comfyEnabled"))
            onToggled: ConfigStore.setValue("comfyEnabled", checked)
        }

        RowLayout {
            Kirigami.FormData.label: "Endpoint:"
            QQC2.TextField {
                id: comfyField
                Layout.fillWidth: true
                placeholderText: "http://192.168.1.10:8000"
                text: (ConfigStore.revision, ConfigStore.value("comfyEndpoint"))
                onEditingFinished: ConfigStore.setValue("comfyEndpoint", text)
                enabled: comfyEnabledBox.checked
            }
            QQC2.Button {
                text: "Testen"
                enabled: comfyEnabledBox.checked && comfyField.text.trim() !== ""
                onClicked: root.testComfy(comfyField.text.trim())
            }
        }

        QQC2.ComboBox {
            Kirigami.FormData.label: "Standard-Bildmodell:"
            enabled: comfyEnabledBox.checked
            textRole: "label"
            valueRole: "value"
            model: [
                { "value": "z_image_turbo", "label": "Z-Image Turbo (schnell)" },
                { "value": "z_image", "label": "Z-Image (Qualität)" }
            ]
            Component.onCompleted: currentIndex = Math.max(0, indexOfValue(ConfigStore.value("comfyDefaultModel")))
            onActivated: ConfigStore.setValue("comfyDefaultModel", currentValue)
        }

        QQC2.Label {
            visible: testStatus !== ""
            text: testStatus
            wrapMode: Text.Wrap
            opacity: 0.8
            Layout.maximumWidth: Kirigami.Units.gridUnit * 25
        }
    }

    function testComfy(url) {
        testStatus = "Teste ComfyUI unter " + url + " ..."
        Http.getJson(url + "/queue", function(res) {
            testStatus = res.ok
                ? "ComfyUI erreichbar!"
                : "Nicht erreichbar (HTTP " + res.status + ")"
        })
    }
}
