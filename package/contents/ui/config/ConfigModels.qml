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
    // Feedback für die Auto-Modus-Dropdowns: bleibt leer, solange /api/tags
    // erreichbar ist; sonst Hinweis, damit leere Dropdowns nicht wie ein
    // Defekt aussehen (analog zum Remote-/Comfy-testStatus).
    property string localStatus: ""
    // Status des OpenRouter-Schlüssels ("leer" | "gespeichert" | Fehlermeldung)
    property string keyStatus: ""

    // --- Inferenz-Status -----------------------------------------------
    // Zeigt pro erreichbarem Ollama-Backend, welche Modelle geladen sind und
    // ob sie im GPU-VRAM oder auf der CPU rechnen. Quelle: /api/ps
    // (size_vram vs. size). Polling alle 5 s, solange die Seite sichtbar ist.
    property string inferLocalText: ""
    property string inferLocalLevel: ""   // "gpu" | "partial" | "cpu" | "off" | "down" | ""
    property string inferRemoteText: ""
    property string inferRemoteLevel: ""
    property bool inferRemoteWanted: false

    Component.onCompleted: {
        refreshLocalModels()
        refreshInfer()
        refreshKeyStatus()
    }

    // Vorhandenen Schlüssel nicht in das Passwortfeld schreiben — nur den
    // Zustand anzeigen. Der echte Wert bleibt, wo er ist (KWallet/Env).
    function refreshKeyStatus() {
        KeyRing.readSecret("openrouter", function(res) {
            root.keyStatus = res.ok && res.secret !== ""
                ? (res.source === "env" ? "Schlüssel aus AURORA_OPENROUTER_KEY" : "gespeichert")
                : "leer"
        })
    }

    function saveOpenRouterKey() {
        var value = openrouterKeyField.text.trim()
        if (value === "") return
        KeyRing.writeSecret("openrouter", value, function(res) {
            root.keyStatus = res.ok ? "gespeichert" : ("Fehler: " + (res.error || "unbekannt"))
            if (res.ok) openrouterKeyField.text = ""
        })
    }

    function _fmtVRAM(b) { return (Math.round(b / 1e8) / 10) + " GB" }

    function _levelColor(level) {
        if (level === "gpu") return Kirigami.Theme.positiveTextColor
        if (level === "partial") return Kirigami.Theme.neutralTextColor
        if (level === "cpu") return Kirigami.Theme.negativeTextColor
        return Kirigami.Theme.textColor
    }

    function _inferFromPs(res, label) {
        if (!res.ok) return { text: label + ": nicht erreichbar", level: "down" }
        var models = (res.data && res.data.models) || []
        if (models.length === 0) return { text: label + ": kein Modell geladen", level: "off" }
        var parts = []
        var worst = "gpu"
        for (var i = 0; i < models.length; i++) {
            var m = models[i]
            var vram = m.size_vram || 0
            var size = m.size || 0
            if (vram <= 0) {
                parts.push(m.name + " — CPU (kein VRAM belegt)")
                worst = "cpu"
            } else if (vram >= size * 0.98) {
                parts.push(m.name + " — GPU (" + _fmtVRAM(vram) + " im VRAM)")
            } else {
                parts.push(m.name + " — GPU teilweise (" + _fmtVRAM(vram) + " von " + _fmtVRAM(size) + " im VRAM)")
                if (worst === "gpu") worst = "partial"
            }
        }
        return { text: label + ":\n" + parts.join("\n"), level: worst }
    }

    function refreshInfer() {
        Http.getJson("http://127.0.0.1:11434/api/ps", function(res) {
            var r = root._inferFromPs(res, "Lokal (127.0.0.1)")
            root.inferLocalText = r.text
            root.inferLocalLevel = r.level
        })
        var ep = (ConfigStore.value("remoteEndpoint") || "").trim()
        root.inferRemoteWanted = !!ConfigStore.value("remoteEnabled") && ep !== ""
        if (root.inferRemoteWanted) {
            var short = ep.replace(/^https?:\/\//, "")
            Http.getJson(ep + "/api/ps", function(res) {
                var r2 = root._inferFromPs(res, "Remote (" + short + ")")
                root.inferRemoteText = r2.text
                root.inferRemoteLevel = r2.level
            })
        } else {
            root.inferRemoteText = ""
            root.inferRemoteLevel = ""
        }
    }

    Timer {
        interval: 5000
        repeat: true
        running: root.visible
        onTriggered: root.refreshInfer()
    }

    function refreshLocalModels() {
        Http.getJson("http://127.0.0.1:11434/api/tags", function(res) {
            if (!res.ok) {
                root.localStatus = "Lokales Ollama nicht erreichbar"
                return
            }
            root.localStatus = ""
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
            Kirigami.FormData.label: "Inferenz-Status"
        }

        QQC2.Label {
            Kirigami.FormData.label: "Recheneinheit:"
            text: root.inferLocalText !== "" ? root.inferLocalText : "Lokal (127.0.0.1): …"
            color: root._levelColor(root.inferLocalLevel)
            wrapMode: Text.Wrap
            Layout.maximumWidth: Kirigami.Units.gridUnit * 25
        }

        QQC2.Label {
            visible: root.inferRemoteWanted
            text: root.inferRemoteText !== "" ? root.inferRemoteText : "Remote: …"
            color: root._levelColor(root.inferRemoteLevel)
            wrapMode: Text.Wrap
            Layout.maximumWidth: Kirigami.Units.gridUnit * 25
        }

        QQC2.Label {
            visible: root.inferLocalLevel === "cpu"
            text: "Das Modell rechnet auf der CPU. Häufige Ursachen: VRAM durch andere Prozesse belegt (z. B. ComfyUI) oder Ollama wurde vor dem GPU-Treiber gestartet — dann hilft: systemctl restart ollama"
            wrapMode: Text.Wrap
            opacity: 0.8
            color: Kirigami.Theme.negativeTextColor
            Layout.maximumWidth: Kirigami.Units.gridUnit * 25
        }

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

        QQC2.Label {
            visible: root.localStatus !== ""
            text: root.localStatus
            wrapMode: Text.Wrap
            opacity: 0.8
            color: Kirigami.Theme.negativeTextColor
            Layout.maximumWidth: Kirigami.Units.gridUnit * 25
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
            Kirigami.FormData.label: "OpenRouter (Cloud)"
        }

        // Explizit opt-in: fremde Cloud ist die begründete Ausnahme und wird
        // nie automatisch gewählt (Auto-Modus greift nur auf eigene Backends).
        QQC2.CheckBox {
            id: openrouterEnabledBox
            Kirigami.FormData.label: "OpenRouter:"
            text: "Aktivieren"
            checked: (ConfigStore.revision, ConfigStore.value("openrouterEnabled"))
            onToggled: ConfigStore.setValue("openrouterEnabled", checked)
        }

        RowLayout {
            visible: openrouterEnabledBox.checked
            Kirigami.FormData.label: "API-Schlüssel:"
            QQC2.TextField {
                id: openrouterKeyField
                Layout.fillWidth: true
                placeholderText: root.keyStatus === "gespeichert"
                    ? "Schlüssel liegt im KWallet"
                    : root.keyStatus === "leer" ? "kein Schlüssel gespeichert" : "sk-or-…"
                echoMode: TextInput.PasswordEchoOnEdit
            }
            QQC2.Button {
                text: "Speichern"
                enabled: openrouterKeyField.text.trim() !== ""
                onClicked: root.saveOpenRouterKey()
            }
        }

        QQC2.Label {
            visible: openrouterEnabledBox.checked
            text: root.keyStatus !== ""
                ? root.keyStatus
                : "Der Schlüssel liegt im KWallet (nicht in der Konfigurationsdatei)."
            wrapMode: Text.Wrap
            opacity: 0.8
            Layout.maximumWidth: Kirigami.Units.gridUnit * 25
        }

        QQC2.Label {
            visible: openrouterEnabledBox.checked
            text: "Für kopf-losen Betrieb stattdessen die Umgebungsvariable AURORA_OPENROUTER_KEY setzen."
            wrapMode: Text.Wrap
            opacity: 0.6
            Layout.maximumWidth: Kirigami.Units.gridUnit * 25
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

        QQC2.CheckBox {
            Kirigami.FormData.label: "VRAM:"
            text: "Nach Generierung freigeben"
            enabled: comfyEnabledBox.checked
            checked: (ConfigStore.revision, ConfigStore.value("comfyFreeVram"))
            onToggled: ConfigStore.setValue("comfyFreeVram", checked)
        }

        QQC2.Label {
            visible: comfyEnabledBox.checked
            text: "Empfohlen, wenn ComfyUI und das Sprachmodell dieselbe GPU nutzen — sonst fällt Ollama beim nächsten Laden auf die CPU zurück."
            wrapMode: Text.Wrap
            opacity: 0.7
            Layout.maximumWidth: Kirigami.Units.gridUnit * 25
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
