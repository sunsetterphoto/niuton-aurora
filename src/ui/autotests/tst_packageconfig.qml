import QtQuick
import QtTest

// Lädt jede KCM-Konfigseite einmal offscreen. Regressionsschutz für
// Laufzeit-Ladefehler, die Build und qmllint nicht sehen: package/-Seiten
// liegen in keinem QML-Modul (kein qmlcache) und hatten keinerlei
// Abdeckung — so schlug die Seite „Erweitert" im echten Dialog wochenlang
// still fehl (localeName an Validatoren, unter Qt 6.11 entfernt).
Item {
    id: root

    Loader { id: pageLoader }

    TestCase {
        name: "PackageConfig"

        function test_alleKcmSeitenLadenOhneFehler() {
            var pages = [ "ConfigGeneral.qml", "ConfigTools.qml", "ConfigModels.qml",
                          "ConfigModelStore.qml", "ConfigVoice.qml", "ConfigAdvanced.qml" ]
            for (var i = 0; i < pages.length; i++) {
                pageLoader.source = Qt.resolvedUrl("../../../package/contents/ui/config/" + pages[i])
                compare(pageLoader.status, Loader.Ready, pages[i] + " lädt nicht")
                verify(pageLoader.item !== null, pages[i] + ": item ist null")
                pageLoader.source = ""
            }
        }
    }
}
