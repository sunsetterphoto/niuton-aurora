import QtQuick
import QtTest
import net.niuton.aurora.core

// KCM-Seite „Cloud-Rechner": Adresse, Geräte-Schlüssel (nur KWallet), Verbindung
// prüfen und die Auswahl „Befehle und Dateien". KeyRing und Http werden als
// Attrappen injiziert (setSource mit Startwerten, also VOR onCompleted).
Item {
    id: root

    QtObject {
        id: keyringMock
        property string stored: ""
        property string source: ""
        property var writes: []
        property int removes: 0
        function readSecret(ref, cb) {
            cb({ "ok": true, "secret": keyringMock.stored, "source": keyringMock.source })
        }
        function writeSecret(ref, secret, cb) {
            writes.push({ "ref": ref, "secret": secret })
            keyringMock.stored = secret
            cb({ "ok": true })
        }
        function removeSecret(ref, cb) { removes++; keyringMock.stored = ""; cb({ "ok": true }) }
    }

    QtObject {
        id: httpMock
        property var calls: []
        function request(opts, cb) { calls.push({ "opts": opts, "cb": cb }) }
        function answer(r) { calls[calls.length - 1].cb(r) }
        function last() { return calls[calls.length - 1].opts }
    }

    Loader { id: loader }

    TestCase {
        name: "CloudSettings"

        property var page: null

        function init() {
            ConfigStore.reset()
            keyringMock.stored = ""
            keyringMock.source = ""
            keyringMock.writes = []
            keyringMock.removes = 0
            httpMock.calls = []
            loader.source = ""
            loader.setSource(Qt.resolvedUrl("../../../package/contents/ui/config/ConfigCloud.qml"),
                             { "keyring": keyringMock, "http": httpMock })
            compare(loader.status, Loader.Ready, "ConfigCloud.qml lädt nicht")
            page = loader.item
        }

        function test_vorgabe_dieserRechnerUndCloudNichtWaehlbar() {
            compare(page.keyPresent, false)
            compare(page.cloudSelectable, false)
            compare(ConfigStore.value("sandboxTarget"), "device")
            page.setTarget("cloud")                       // ohne Adresse/Schlüssel: verweigert
            compare(ConfigStore.value("sandboxTarget"), "device")
        }

        function test_adresseWirdBereinigtGespeichert() {
            page.saveEndpoint("  https://aurora.example/  ")
            compare(ConfigStore.value("cloudBoxEndpoint"), "https://aurora.example")
            compare(page.endpointWarning, "")
            page.saveEndpoint("http://aurora.example")
            verify(page.endpointWarning.indexOf("unverschlüsselt") >= 0)
        }

        function test_schluesselNurImKWallet() {
            page.saveEndpoint("https://aurora.example")
            page.saveKey("  nk_abc  ")
            compare(keyringMock.writes.length, 1)
            compare(keyringMock.writes[0].ref, "cloudbox")
            compare(keyringMock.writes[0].secret, "nk_abc")
            compare(ConfigStore.value("cloudBoxKeyRevision"), 1)
            compare(page.keyPresent, true)
            compare(page.cloudSelectable, true)
            // nie in der Konfigurationsdatei
            verify(!ConfigStore.contains("cloudBoxKey"))
            page.setTarget("cloud")
            compare(ConfigStore.value("sandboxTarget"), "cloud")
        }

        function test_schluesselAusUmgebung() {
            keyringMock.stored = "nk_env"
            keyringMock.source = "env"
            page.refreshKeyStatus()
            compare(page.keyPresent, true)
            verify(page.keyStatus.indexOf("AURORA_CLOUDBOX_KEY") >= 0)
        }

        function test_schluesselLoeschenSchaltetZurueck() {
            page.saveEndpoint("https://aurora.example")
            page.saveKey("nk_abc")
            page.setTarget("cloud")
            page.removeKey()
            compare(keyringMock.removes, 1)
            compare(page.keyPresent, false)
            compare(ConfigStore.value("sandboxTarget"), "device")
            compare(ConfigStore.value("cloudBoxKeyRevision"), 2)
        }

        function test_adresseLeerenSchaltetZurueck() {
            page.saveEndpoint("https://aurora.example")
            page.saveKey("nk_abc")
            page.setTarget("cloud")
            page.saveEndpoint("")
            compare(ConfigStore.value("sandboxTarget"), "device")
            compare(page.cloudSelectable, false)
        }

        function test_verbindungPruefenGutfall() {
            page.saveEndpoint("https://aurora.example")
            page.saveKey("nk_abc")
            page.checkConnection("https://aurora.example", "")
            var o = httpMock.last()
            compare(o.url, "https://aurora.example/api/v1/me")
            compare(o.headers["Authorization"], "Bearer nk_abc")
            httpMock.answer({ "ok": true, "status": 200, "data": { "username": "anna", "displayName": "Anna",
                "tier": "normal", "features": { "box": true }, "device": { "id": "d", "name": "Laptop" } } })
            compare(page.checkLevel, "ok")
            verify(page.checkText.indexOf("Verbunden als Anna (Laptop)") >= 0)
        }

        // Prüfen vor dem Speichern: Schlüssel aus dem Feld
        function test_verbindungPruefenMitFeldwerten() {
            page.checkConnection("https://other.example/", "nk_feld")
            compare(httpMock.last().url, "https://other.example/api/v1/me")
            compare(httpMock.last().headers["Authorization"], "Bearer nk_feld")
        }

        function test_verbindungPruefenFehler() {
            page.checkConnection("https://aurora.example", "nk_falsch")
            httpMock.answer({ "ok": false, "status": 401, "error": "HTTP 401",
                              "data": { "error": { "code": "unauthorized", "message": "x" } } })
            compare(page.checkLevel, "error")
            verify(page.checkText.indexOf("Einstellungen → Geräte") >= 0)
            page.checkConnection("https://aurora.example", "nk_x")
            httpMock.answer({ "ok": true, "status": 200, "data": { "username": "b", "features": { "box": false } } })
            compare(page.checkLevel, "warning")
            verify(page.checkText.indexOf("abgeschaltet") >= 0)
        }

        function test_rechteDerCloudWerkzeuge() {
            page.setPermission("toolCloudRunCommand", "confirm")
            compare(ConfigStore.value("toolCloudRunCommand"), "confirm")
        }
    }
}
