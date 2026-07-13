qt_add_executable(aurora main.cpp)

qt_add_qml_module(aurora
    URI net.niuton.aurora.app
    VERSION 1.0
    QML_FILES qml/Main.qml
)

target_link_libraries(aurora PRIVATE
    Qt6::Quick
    Qt6::Widgets
    KF6::DBusAddons
    KF6::CoreAddons
    KF6::I18n
)

install(TARGETS aurora ${KDE_INSTALL_TARGETS_DEFAULT_ARGS})
install(FILES net.niuton.aurora.desktop DESTINATION ${KDE_INSTALL_APPDIR})
