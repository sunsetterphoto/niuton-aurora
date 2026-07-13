cmake_minimum_required(VERSION 3.20)
project(aurora VERSION 0.1.0)

find_package(ECM 6.0 REQUIRED NO_MODULE)
set(CMAKE_MODULE_PATH ${ECM_MODULE_PATH})

include(KDEInstallDirs)
include(KDECMakeSettings)
include(KDECompilerSettings NO_POLICY_SCOPE)
include(ECMQmlModule)

find_package(Qt6 6.6 REQUIRED COMPONENTS Core Qml Network Sql Quick Widgets Gui)
find_package(Plasma REQUIRED)
find_package(KF6 6.0 REQUIRED COMPONENTS DBusAddons CoreAddons I18n)

add_subdirectory(src/core)
add_subdirectory(src/engine)
add_subdirectory(src/ui)

option(BUILD_APP "Standalone-App (src/app) bauen" ON)
if(BUILD_APP)
    add_subdirectory(src/app)
    # App-Icon nur zusammen mit der App ausliefern (Icon=aurora in der .desktop).
    install(FILES package/contents/icons/aurora.svg
            DESTINATION ${KDE_INSTALL_ICONDIR}/hicolor/scalable/apps)
endif()

plasma_install_package(package org.kde.aurora)
