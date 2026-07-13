ecm_add_qml_module(auroracoreplugin
    URI net.niuton.aurora.core
    VERSION 1.0
    GENERATE_PLUGIN_SOURCE
)

target_sources(auroracoreplugin PRIVATE
    src/configstore.cpp
    src/configstore.h
    src/conversationstore.cpp
    src/conversationstore.h
    src/fileio.cpp
    src/fileio.h
    src/http.cpp
    src/http.h
    src/ndjsonstream.cpp
    src/ndjsonstream.h
    src/processrunner.cpp
    src/processrunner.h
    src/utf8trim.h
)
target_include_directories(auroracoreplugin PRIVATE src)
target_link_libraries(auroracoreplugin PRIVATE Qt6::Core Qt6::Qml Qt6::Network Qt6::Sql)

ecm_finalize_qml_module(auroracoreplugin DESTINATION ${KDE_INSTALL_QMLDIR})

if(BUILD_TESTING)
    find_package(Qt6 6.6 REQUIRED COMPONENTS Test)

    # KDECompilerSettings definiert QT_NO_CAST_FROM_ASCII projektweit; die Tests
    # verwenden bewusst rohe String-Literale (lesbarer Testcode), daher gezielt
    # für die Testbinaries gelockert.
    set(AURORA_TEST_CAST_RELAX
        -UQT_NO_CAST_FROM_ASCII
        -UQT_NO_CAST_TO_ASCII
        -UQT_NO_CAST_FROM_BYTEARRAY
        -UQT_NO_URL_CAST_FROM_STRING
    )

    function(aurora_core_test name)
        add_executable(${name} ${ARGN})
        target_include_directories(${name} PRIVATE src autotests)
        target_link_libraries(${name} PRIVATE Qt6::Core Qt6::Qml Qt6::Network Qt6::Sql Qt6::Test)
        target_compile_options(${name} PRIVATE ${AURORA_TEST_CAST_RELAX})
        add_test(NAME ${name} COMMAND ${name})
    endfunction()

    aurora_core_test(test_fileio autotests/test_fileio.cpp src/fileio.cpp)
    aurora_core_test(test_http autotests/test_http.cpp autotests/testhttpserver.h src/http.cpp)
    aurora_core_test(test_ndjsonstream autotests/test_ndjsonstream.cpp autotests/testhttpserver.h src/ndjsonstream.cpp)
    aurora_core_test(test_processrunner autotests/test_processrunner.cpp src/processrunner.cpp)
    aurora_core_test(test_conversationstore autotests/test_conversationstore.cpp src/conversationstore.cpp)
    aurora_core_test(test_configstore autotests/test_configstore.cpp src/configstore.cpp)
endif()
