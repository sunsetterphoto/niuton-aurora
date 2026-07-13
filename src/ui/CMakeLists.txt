ecm_add_qml_module(auroraui
    URI net.niuton.aurora.ui
    VERSION 1.0
    GENERATE_PLUGIN_SOURCE
)

# ecm_target_qml_sources() erkennt "pragma Singleton" im Dateiinhalt nicht;
# Qt6QmlMacros.cmake liest dafuer ausschliesslich die Source-Property
# QT_QML_SINGLETON_TYPE, und zwar synchron beim Aufruf von qt6_target_qml_sources()
# (nicht deferred) -- die Property muss also VOR ecm_target_qml_sources() gesetzt
# werden, sonst landet in der generierten qmldir keine "singleton"-Zeile und
# Theme.<token> bleibt undefined.
set_source_files_properties(qml/Theme.qml PROPERTIES QT_QML_SINGLETON_TYPE true)

ecm_target_qml_sources(auroraui SOURCES
    qml/Theme.qml
    qml/MessageBubble.qml
    qml/ChatInput.qml
    qml/ChatView.qml
    qml/Header.qml
    qml/Sidebar.qml
    qml/ImagePanel.qml
    qml/ModelTuner.qml
    qml/MainView.qml
    qml/KnowledgeView.qml
)

# Icon-Assets fuers Thinking-Toggle (Header.qml): diese ECM-Version kennt bei
# ecm_target_qml_sources() nur das Keyword SOURCES, keine eigene RESOURCES-Klausel;
# Nicht-QML-Dateien (Extension != .qml/.js/.mjs) werden intern automatisch als
# RESOURCES an qt6_target_qml_sources() durchgereicht und landen so in der
# Modul-Ressource (siehe ECMQmlModule6.cmake).
# PATH icons ist noetig, sonst landet der Resource-Alias ohne "icons/"-Praefix
# direkt neben Header.qml im Modul-Wurzelverzeichnis, und Header.qml's
# Qt.resolvedUrl("icons/thinking-on.svg") laeuft ins Leere (empirisch mit
# QT_LOGGING_RULES="qt.qml.debug=true" als "Cannot open" gefunden).
ecm_target_qml_sources(auroraui PATH icons SOURCES
    icons/thinking-on.svg
    icons/thinking-off.svg
)

target_link_libraries(auroraui PRIVATE Qt6::Qml)

ecm_finalize_qml_module(auroraui DESTINATION ${KDE_INSTALL_QMLDIR})

if(BUILD_TESTING)
    find_program(QMLTESTRUNNER_EXECUTABLE NAMES qmltestrunner
        HINTS "${QT6_INSTALL_PREFIX}/${QT6_INSTALL_BINS}"
        PATHS /usr/lib64/qt6/bin /usr/lib/qt6/bin)
    if(NOT QMLTESTRUNNER_EXECUTABLE)
        message(FATAL_ERROR "qmltestrunner nicht gefunden (Paket qt6-qtdeclarative-devel?)")
    endif()
    function(aurora_ui_qmltest name)
        add_test(NAME ${name} COMMAND ${QMLTESTRUNNER_EXECUTABLE}
            -input ${CMAKE_CURRENT_SOURCE_DIR}/autotests/${name}.qml
            -import ${CMAKE_BINARY_DIR}/bin)
        set_tests_properties(${name} PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")
    endfunction()
    aurora_ui_qmltest(tst_theme)
    aurora_ui_qmltest(tst_modeltuner)
    aurora_ui_qmltest(tst_messagebubble)
    aurora_ui_qmltest(tst_knowledgeview)
endif()
