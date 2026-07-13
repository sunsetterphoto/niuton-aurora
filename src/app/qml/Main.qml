import QtQuick
import org.kde.kirigami as Kirigami
import net.niuton.aurora.engine
import net.niuton.aurora.ui

Kirigami.AbstractApplicationWindow {
    id: appWindow
    title: "Aurora"
    minimumWidth: Kirigami.Units.gridUnit * 20
    minimumHeight: Kirigami.Units.gridUnit * 24
    width: Kirigami.Units.gridUnit * 34
    height: Kirigami.Units.gridUnit * 44

    // Eigene id (nicht "controller"): MainView hat selbst eine Property "controller",
    // die den gleichnamigen äußeren Bezeichner verdecken würde (QML-Scoping) — die
    // Injektion unten bliebe dann für immer undefined (Selbstreferenz statt Zugriff
    // auf diese Instanz). Gleiche Konvention wie im Widget-Host (package/contents/ui/main.qml).
    AuroraController {
        id: auroraController
        active: appWindow.visible
    }

    // Reihenfolge wie im Widget-Host: erst DB öffnen, dann aktivieren
    // (Refresh-Kaskade — die App MUSS activate() rufen, nicht nur active binden).
    Component.onCompleted: {
        auroraController.open()
        auroraController.activate()
    }

    MainView {
        anchors.fill: parent
        controller: auroraController
        showPin: false
        showConfigure: false
        onCloseRequested: appWindow.close()
    }
}
