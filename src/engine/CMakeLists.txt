ecm_add_qml_module(auroraengine
    URI net.niuton.aurora.engine
    VERSION 1.0
    GENERATE_PLUGIN_SOURCE
)

ecm_target_qml_sources(auroraengine SOURCES
    qml/PromptBuilder.js
    qml/ContextCompactor.js
    qml/Commands.js
    qml/ConversationExport.js
    qml/AuroraSettings.qml
    qml/OllamaClient.qml
    qml/ChatJob.qml
    qml/ModelManager.qml
    qml/ChatController.qml
    qml/Tool.qml
    qml/ToolRegistry.qml
    qml/PermissionResolver.qml
    qml/GrantStore.qml
    qml/CategoryPolicy.qml
    qml/tools/ReadFileTool.qml
    qml/tools/ListDirectoryTool.qml
    qml/tools/WriteFileTool.qml
    qml/tools/WebSearchTool.qml
    qml/tools/WebFetchTool.qml
    qml/tools/RunCommandTool.qml
    qml/tools/GenerateImageTool.qml
    qml/VoiceRecorder.qml
    qml/Speaker.qml
    qml/ComfyClient.qml
    qml/AuroraEngine.qml
    qml/AuroraController.qml
)

target_link_libraries(auroraengine PRIVATE Qt6::Qml)

ecm_finalize_qml_module(auroraengine DESTINATION ${KDE_INSTALL_QMLDIR})

if(BUILD_TESTING)
    # qmltestrunner liegt auf Fedora unter /usr/lib64/qt6/bin (nicht im PATH)
    find_program(QMLTESTRUNNER_EXECUTABLE NAMES qmltestrunner
        HINTS "${QT6_INSTALL_PREFIX}/${QT6_INSTALL_BINS}"
        PATHS /usr/lib64/qt6/bin /usr/lib/qt6/bin)
    if(NOT QMLTESTRUNNER_EXECUTABLE)
        message(FATAL_ERROR "qmltestrunner nicht gefunden (Paket qt6-qtdeclarative-devel?)")
    endif()

    # ARGN nimmt zusaetzliche ENVIRONMENT-Eintraege entgegen (z.B. einen
    # build-lokalen AURORA_CONFIG_PATH), damit Tests, die den ConfigStore
    # (net.niuton.aurora.core) beruehren, NIE in die echte
    # ~/.config/net.niuton.aurora.rc schreiben.
    function(aurora_engine_qmltest name)
        add_test(NAME ${name} COMMAND ${QMLTESTRUNNER_EXECUTABLE}
            -input ${CMAKE_CURRENT_SOURCE_DIR}/autotests/${name}.qml
            -import ${CMAKE_BINARY_DIR}/bin)
        set(_env "QT_QPA_PLATFORM=offscreen")
        if(ARGN)
            list(APPEND _env ${ARGN})
        endif()
        set_tests_properties(${name} PROPERTIES ENVIRONMENT "${_env}")
    endfunction()

    aurora_engine_qmltest(tst_aurorasettings
        "AURORA_CONFIG_PATH=${CMAKE_BINARY_DIR}/tst_aurorasettings.rc")
    aurora_engine_qmltest(tst_ollamaclient_models)
    aurora_engine_qmltest(tst_ollamaclient_chat)
    aurora_engine_qmltest(tst_ollamaclient_embed)
    aurora_engine_qmltest(tst_modelmanager
        "AURORA_CONFIG_PATH=${CMAKE_BINARY_DIR}/tst_modelmanager.rc")
    aurora_engine_qmltest(tst_tool)
    aurora_engine_qmltest(tst_tools_fileio)
    aurora_engine_qmltest(tst_tools_netproc)
    aurora_engine_qmltest(tst_tools_generate)
    aurora_engine_qmltest(tst_toolregistry)
    aurora_engine_qmltest(tst_permission)
    aurora_engine_qmltest(tst_promptbuilder)
    aurora_engine_qmltest(tst_chatcontroller_stream)
    aurora_engine_qmltest(tst_chatcontroller_tools)
    aurora_engine_qmltest(tst_chatcontroller_confirm)
    aurora_engine_qmltest(tst_chatcontroller_stop)
    aurora_engine_qmltest(tst_chatcontroller_activity)
    aurora_engine_qmltest(tst_chatcontroller_rating)
    aurora_engine_qmltest(tst_chatcontroller_embed)
    aurora_engine_qmltest(tst_contextcompactor)
    aurora_engine_qmltest(tst_chatcontroller_compaction)
    aurora_engine_qmltest(tst_auroraengine)
    aurora_engine_qmltest(tst_auroraengine_knowledge)
    aurora_engine_qmltest(tst_auroracontroller
        "AURORA_CONFIG_PATH=${CMAKE_BINARY_DIR}/tst_auroracontroller.rc"
        "AURORA_DB_PATH=${CMAKE_BINARY_DIR}/tst_auroracontroller.db")
    aurora_engine_qmltest(tst_commands)
    aurora_engine_qmltest(tst_conversationexport)
    aurora_engine_qmltest(tst_comfyclient
        "XDG_DATA_HOME=${CMAKE_BINARY_DIR}/tst_comfyclient_data")
endif()
