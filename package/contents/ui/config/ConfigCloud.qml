import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM
import net.niuton.aurora.core
import net.niuton.aurora.engine

// Cloud-Rechner: statt dieses Rechners führt Aurora Befehle und Dateien in der
// isolierten Linux-Box eines Aurora-Servers aus (App-API, Geräte-Schlüssel).
// Aus, solange keine Adresse eingetragen ist. Der Schlüssel liegt nur im KWallet
// (KeyRing "cloudbox", Env-Rückfall AURORA_CLOUDBOX_KEY), nie in der rc-Datei.
KCM.SimpleKCM {
    id: root

    // Injizierbar für Tests; im Dialog die Core-Singletons.
    property var keyring: KeyRing
    property var http: Http

    property bool keyPresent: false
    property string keyStatus: ""
    property string endpointWarning: ""
    property string checkText: ""
    property string checkLevel: ""        // "" | "busy" | "ok" | "warning" | "error"

    readonly property string endpointValue: (ConfigStore.revision, String(ConfigStore.value("cloudBoxEndpoint") || ""))
    readonly property bool cloudSelectable: endpointValue !== "" && keyPresent
    readonly property bool cloudSelected: (ConfigStore.revision, ConfigStore.value("sandboxTarget") === "cloud")

    readonly property var permOptions: ["auto", "confirm", "off"]
    readonly property var permLabels: ["Automatisch", "Mit Bestätigung", "Deaktiviert"]
    readonly property var cloudTools: [
        { "key": "toolCloudRunCommand", "label": "Befehl ausführen:" },
        { "key": "toolCloudReadFile", "label": "Datei lesen:" },
        { "key": "toolCloudWriteFile", "label": "Datei schreiben:" },
        { "key": "toolCloudListDir", "label": "Ordner anzeigen:" },
        { "key": "toolCloudPreview", "label": "Vorschau öffnen:" },
        { "key": "toolCloudScreenshot", "label": "Screenshot:" }
    ]

    CloudBoxClient {
        id: probe
        endpoint: root.endpointValue
        keyring: root.keyring
        http: root.http
    }

    Component.onCompleted: {
        endpointField.text = endpointValue
        refreshKeyStatus()
    }

    function _cleanEndpoint(text) {
        var s = String(text || "").trim()
        while (s.length > 0 && s.charAt(s.length - 1) === "/") s = s.substring(0, s.length - 1)
        return s
    }

    function _bumpKeyRevision() {
        ConfigStore.setValue("cloudBoxKeyRevision", (parseInt(ConfigStore.value("cloudBoxKeyRevision")) || 0) + 1)
        probe.resetKey()
    }

    // Ohne Adresse oder Schlüssel ist „Cloud-Rechner" nicht wählbar — eine
    // frühere Auswahl fällt dann bewusst auf diesen Rechner zurück (die Engine
    // selbst kennt keinen Rückfall; sie würde die Werkzeuge nur sperren).
    function _ensureTargetValid() {
        if (!cloudSelectable && ConfigStore.value("sandboxTarget") === "cloud")
            ConfigStore.setValue("sandboxTarget", "device")
    }

    function saveEndpoint(text) {
        var ep = _cleanEndpoint(text)
        ConfigStore.setValue("cloudBoxEndpoint", ep)
        endpointField.text = ep
        if (ep !== "" && ep.indexOf("https://") !== 0)
            endpointWarning = ep.indexOf("http://") === 0
                ? "Achtung: http:// ist unverschlüsselt — Schlüssel und Daten gehen im Klartext über das Netz."
                : "Die Adresse muss mit https:// beginnen."
        else
            endpointWarning = ""
        checkText = ""
        checkLevel = ""
        _ensureTargetValid()
    }

    // Vorhandenen Schlüssel nie anzeigen — nur den Zustand.
    function refreshKeyStatus() {
        root.keyring.readSecret("cloudbox", function(res) {
            root.keyPresent = !!(res && res.ok && res.secret)
            root.keyStatus = !root.keyPresent ? "kein Schlüssel gespeichert"
                : (res.source === "env" ? "Schlüssel aus AURORA_CLOUDBOX_KEY" : "Schlüssel gespeichert (KWallet)")
            root._ensureTargetValid()
        })
    }

    function saveKey(text) {
        var key = String(text || "").trim()
        if (key === "") return
        root.keyring.writeSecret("cloudbox", key, function(res) {
            if (res && res.ok) {
                keyField.text = ""
                root._bumpKeyRevision()
                root.refreshKeyStatus()
            } else {
                root.keyStatus = "Fehler beim Speichern: " + ((res && res.error) || "unbekannt")
            }
        })
    }

    function removeKey() {
        root.keyring.removeSecret("cloudbox", function(res) {
            root._bumpKeyRevision()
            if (!(res && res.ok)) root.keyStatus = "Fehler beim Löschen: " + ((res && res.error) || "unbekannt")
            root.refreshKeyStatus()
            if (ConfigStore.value("sandboxTarget") === "cloud") ConfigStore.setValue("sandboxTarget", "device")
        })
    }

    function setTarget(t) {
        if (t === "cloud" && !cloudSelectable) return
        ConfigStore.setValue("sandboxTarget", t === "cloud" ? "cloud" : "device")
    }

    function setPermission(key, value) { ConfigStore.setValue(key, value) }

    // GET /api/v1/me mit den Feldwerten (vor dem Speichern prüfbar); leeres
    // Schlüsselfeld = gespeicherter Schlüssel.
    function checkConnection(endpointText, keyText) {
        checkLevel = "busy"
        checkText = "Prüfe …"
        var opts = { "endpoint": _cleanEndpoint(endpointText) }
        var k = String(keyText || "").trim()
        if (k !== "") opts.key = k
        probe.me(function(r) {
            if (r.ok) {
                var who = r.me.displayName + (r.me.deviceName ? " (" + r.me.deviceName + ")" : "")
                var tier = r.me.tier === "guest" ? "Gast" : (r.me.tier === "normal" ? "normal" : r.me.tier)
                if (!r.me.box) {
                    root.checkLevel = "warning"
                    root.checkText = "Verbunden als " + who + " — der Cloud-Rechner ist für dieses Konto abgeschaltet."
                } else {
                    root.checkLevel = "ok"
                    root.checkText = "Verbunden als " + who + " · Stufe: " + tier
                }
            } else {
                root.checkLevel = "error"
                root.checkText = CloudBoxTexts.userMessage(r.error)
            }
        }, opts)
    }

    function _levelColor(level) {
        if (level === "ok") return Kirigami.Theme.positiveTextColor
        if (level === "warning") return Kirigami.Theme.neutralTextColor
        if (level === "error") return Kirigami.Theme.negativeTextColor
        return Kirigami.Theme.textColor
    }

    Kirigami.FormLayout {
        QQC2.Label {
            text: "Statt auf diesem Rechner kann Aurora Befehle und Dateien in deinem Cloud-Rechner ausführen — "
                + "einer isolierten Linux-Maschine deines Aurora-Kontos. "
                + "Im Web unter Einstellungen → Geräte ein Gerät hinzufügen und den Schlüssel hier eintragen."
            wrapMode: Text.Wrap
            Layout.maximumWidth: Kirigami.Units.gridUnit * 25
        }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: "Verbindung"
        }

        QQC2.TextField {
            id: endpointField
            Kirigami.FormData.label: "Server-Adresse:"
            Layout.fillWidth: true
            placeholderText: "https://aurora.example"
            inputMethodHints: Qt.ImhUrlCharactersOnly | Qt.ImhNoAutoUppercase
            onEditingFinished: if (root._cleanEndpoint(text) !== root.endpointValue) root.saveEndpoint(text)
        }

        QQC2.Label {
            visible: root.endpointWarning !== ""
            text: root.endpointWarning
            color: Kirigami.Theme.neutralTextColor
            wrapMode: Text.Wrap
            Layout.maximumWidth: Kirigami.Units.gridUnit * 25
        }

        RowLayout {
            Kirigami.FormData.label: "Geräte-Schlüssel:"
            QQC2.TextField {
                id: keyField
                Layout.fillWidth: true
                placeholderText: root.keyPresent ? "Schlüssel liegt im KWallet" : "nk_…"
                echoMode: TextInput.Password
            }
            QQC2.Button {
                text: "Speichern"
                enabled: keyField.text.trim() !== ""
                onClicked: root.saveKey(keyField.text)
            }
            QQC2.Button {
                text: "Löschen"
                visible: root.keyPresent
                onClicked: root.removeKey()
            }
        }

        QQC2.Label {
            text: root.keyStatus + " — der Schlüssel liegt nie in der Konfigurationsdatei. "
                + "Für kopf-losen Betrieb: Umgebungsvariable AURORA_CLOUDBOX_KEY."
            wrapMode: Text.Wrap
            opacity: 0.7
            Layout.maximumWidth: Kirigami.Units.gridUnit * 25
        }

        RowLayout {
            QQC2.Button {
                text: "Verbindung prüfen"
                icon.name: "network-connect"
                enabled: root._cleanEndpoint(endpointField.text) !== "" && root.checkLevel !== "busy"
                onClicked: root.checkConnection(endpointField.text, keyField.text)
            }
            QQC2.Label {
                text: root.checkText
                color: root._levelColor(root.checkLevel)
                wrapMode: Text.Wrap
                Layout.maximumWidth: Kirigami.Units.gridUnit * 20
            }
        }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: "Befehle und Dateien"
        }

        QQC2.RadioButton {
            Kirigami.FormData.label: "Ausführen auf:"
            text: "Diesem Rechner"
            checked: !root.cloudSelected
            onToggled: if (checked) root.setTarget("device")
        }
        QQC2.RadioButton {
            text: "Cloud-Rechner"
            enabled: root.cloudSelectable
            checked: root.cloudSelected
            onToggled: if (checked) root.setTarget("cloud")
        }
        QQC2.Label {
            text: root.cloudSelectable
                ? (root.cloudSelected
                   ? "Befehle, Dateien, Vorschau und Screenshots laufen im Cloud-Rechner (Arbeitsordner /work). "
                     + "Auf diesem Rechner wird dann nichts ausgeführt."
                   : "Befehle und Dateien laufen auf diesem Rechner (wie bisher).")
                : "„Cloud-Rechner“ ist wählbar, sobald Adresse und Schlüssel eingetragen sind."
            wrapMode: Text.Wrap
            opacity: 0.7
            Layout.maximumWidth: Kirigami.Units.gridUnit * 25
        }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: "Rechte der Cloud-Werkzeuge"
        }

        Repeater {
            model: root.cloudTools
            delegate: QQC2.ComboBox {
                required property var modelData
                Kirigami.FormData.label: modelData.label
                model: root.permLabels
                Component.onCompleted: currentIndex = Math.max(0, root.permOptions.indexOf(ConfigStore.value(modelData.key)))
                onActivated: root.setPermission(modelData.key, root.permOptions[currentIndex])
            }
        }
    }
}
