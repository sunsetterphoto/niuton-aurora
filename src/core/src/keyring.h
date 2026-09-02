#pragma once

#include <QDBusConnection>
#include <QJSValue>
#include <QList>
#include <QObject>
#include <QQmlEngine>
#include <QString>
#include <QVariantMap>

#include <functional>

// Schlüsselablage hinter der QML-Singleton-Fläche (Phase 2): der
// OpenRouter-API-Key gehört NICHT in die Config-Datei (~/.config/
// net.niuton.aurora.rc, Modus 644) — die Registry hält nur den keyRef, das
// Secret liegt im KWallet (kwalletd6 via D-Bus, keine KF6-Dev-Abhängigkeit).
//
// Reihenfolge beim Lesen: zuerst die Umgebungsvariable AURORA_<KEY>_KEY
// (kopf-loser Betrieb ohne grafische Sitzung), dann das Wallet. Leer heißt
// "nicht gesetzt" und ist KEIN Fehler — der Aufrufer entscheidet.
//
// Tests: D-Bus-Connection injizierbar (privater QDBusServer mit Fake-
// kwalletd), siehe tst_keyring.cpp — kein echter Daemon, kein Netz.
class KeyRing : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    Q_PROPERTY(QString walletName READ walletName WRITE setWalletName NOTIFY walletNameChanged)
    Q_PROPERTY(QString folder READ folder WRITE setFolder NOTIFY folderChanged)

public:
    explicit KeyRing(QObject *parent = nullptr);

    QString walletName() const;
    void setWalletName(const QString &walletName);
    QString folder() const;
    void setFolder(const QString &folder);

    // callback(result): { ok, secret?, error? }. Fehlende Einträge liefern
    // ok:true mit leerem secret (Abwesenheit ist kein Fehler).
    Q_INVOKABLE void readSecret(const QString &keyRef, const QJSValue &callback);
    Q_INVOKABLE void writeSecret(const QString &keyRef, const QString &secret,
                                 const QJSValue &callback);
    Q_INVOKABLE void removeSecret(const QString &keyRef, const QJSValue &callback);

    // std::function-Overloads: gleiche Logik ohne QJSEngine — benutzen die
    // C++-Tests, damit KeyRing auch ohne QML-Engine vollständig prüfbar ist.
    void readSecret(const QString &keyRef, std::function<void(const QVariantMap &)> callback);
    void writeSecret(const QString &keyRef, const QString &secret,
                     std::function<void(const QVariantMap &)> callback);
    void removeSecret(const QString &keyRef, std::function<void(const QVariantMap &)> callback);

    // Nur Tests: ersetzt die Session-Bus-Verbindung durch eine private
    // (dbus-daemon-Subprozess + Fake-kwalletd) und erlaubt einen anderen
    // Dienstnamen (Fehlpfad-Test). Kein Q_INVOKABLE — die Produktion
    // nutzt immer den Session-Bus.
    void setConnectionForTesting(const QDBusConnection &connection,
                                 const QString &serviceName = QString());

Q_SIGNALS:
    void walletNameChanged();
    void folderChanged();

private Q_SLOTS:
    void onWalletClosed();          // KWallet entlässt den Handle — Cache leeren

private:
    struct Pending {
        std::function<void(const QVariantMap &)> callback;
        QString key;
        QString value;
        bool isWrite = false;
        bool isRemove = false;
    };

    static QString envKey(const QString &keyRef);
    QString appId() const;
    QDBusConnection connection() const { return m_connection; }
    void invoke(const QJSValue &callback, const QVariantMap &result);
    void drainError(const QString &error);          // alle offenen Anfragen fehlschlagen lassen
    void flush();                                   // wartende Anfragen, wenn Wallet bereit
    void ensureOpen();                              // einmal öffnen, Ergebnis flusht die Queue
    void ensureFolder();                            // createFolder (kwalletd legt sonst nichts an)
    void dispatch(const Pending &op);               // read/write/remove an den Daemon
    void connectWalletClosed();

    QDBusConnection m_connection;
    QString m_service = QStringLiteral("org.kde.kwalletd6");
    QString m_walletName = QStringLiteral("kdewallet");
    QString m_folder = QStringLiteral("net.niuton.aurora");
    QList<Pending> m_queue;
    int m_handle = -1;              // geöffneter Wallet-Handle; <= 0 = zu
    bool m_opening = false;
    bool m_folderReady = false;
    qlonglong m_txId = 0;           // wId an kwalletd6 (nur Korrelation)
};