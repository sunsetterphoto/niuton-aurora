import QtQuick
import org.kde.plasma.configuration

ConfigModel {
    ConfigCategory {
        name: "Allgemein"
        icon: "configure"
        source: "config/ConfigGeneral.qml"
    }
    ConfigCategory {
        name: "Tools"
        icon: "configure-toolbars"
        source: "config/ConfigTools.qml"
    }
    ConfigCategory {
        name: "Modelle"
        icon: "application-x-executable"
        source: "config/ConfigModels.qml"
    }
    ConfigCategory {
        name: "Sprache"
        icon: "audio-input-microphone"
        source: "config/ConfigVoice.qml"
    }
    ConfigCategory {
        name: "Erweitert"
        icon: "preferences-other"
        source: "config/ConfigAdvanced.qml"
    }
}
