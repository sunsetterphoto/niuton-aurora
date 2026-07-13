#include <QApplication>
#include <QIcon>
#include <QQmlApplicationEngine>
#include <QQuickWindow>
#include <KAboutData>
#include <KDBusService>
#include <KLocalizedString>

int main(int argc, char *argv[])
{
    QApplication app(argc, argv);

    KLocalizedString::setApplicationDomain(QByteArrayLiteral("aurora"));

    KAboutData about(QStringLiteral("aurora"),
                     QStringLiteral("Aurora"),
                     QStringLiteral("0.1.0"),
                     QStringLiteral("Lokaler KI-Assistent"),
                     KAboutLicense::GPL_V3);
    // KDBusService bildet den D-Bus-Namen als reversed(organizationDomain) + "."
    // + componentName. Ohne dies defaultet KAboutData organizationDomain auf
    // "kde.org" -> der Name waere "org.kde.net.niuton.aurora". Mit niuton.net +
    // componentName "aurora" ergibt sich "net.niuton.aurora" (= die App-Id).
    about.setOrganizationDomain(QByteArrayLiteral("niuton.net"));
    about.setDesktopFileName(QStringLiteral("net.niuton.aurora"));
    KAboutData::setApplicationData(about);
    QApplication::setWindowIcon(QIcon::fromTheme(QStringLiteral("aurora")));

    // Single-Instance: ein zweiter Start meldet sich per D-Bus bei der laufenden
    // Instanz (activateRequested) und beendet sich; siehe Handler unten.
    KDBusService service(KDBusService::Unique);

    QQmlApplicationEngine engine;
    engine.loadFromModule("net.niuton.aurora.app", "Main");
    if (engine.rootObjects().isEmpty())
        return -1;

    QObject::connect(&service, &KDBusService::activateRequested, &engine,
                     [&engine](const QStringList &, const QString &) {
        const auto objs = engine.rootObjects();
        if (objs.isEmpty())
            return;
        if (auto *w = qobject_cast<QQuickWindow *>(objs.first())) {
            w->show();
            w->raise();
            w->requestActivate();
        }
    });

    return app.exec();
}
