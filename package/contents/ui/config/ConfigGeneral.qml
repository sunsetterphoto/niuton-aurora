import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM
import net.niuton.aurora.core

KCM.SimpleKCM {
    id: root

    Kirigami.FormLayout {
        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: "Modell-Verwaltung"
        }

        ColumnLayout {
            Kirigami.FormData.label: "Entladezeit:"
            QQC2.Slider {
                id: unloadSlider
                from: 30
                to: 1800
                stepSize: 30
                Layout.fillWidth: true
                Component.onCompleted: value = ConfigStore.value("unloadSeconds")
                onMoved: ConfigStore.setValue("unloadSeconds", value)
            }
            QQC2.Label {
                text: {
                    var mins = Math.floor(unloadSlider.value / 60)
                    var secs = unloadSlider.value % 60
                    if (mins > 0 && secs > 0) return mins + " min " + secs + " s"
                    if (mins > 0) return mins + " min"
                    return secs + " s"
                }
                opacity: 0.7
            }
        }
    }
}
