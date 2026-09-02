#include "keyring.h"

#include <QCoreApplication>
#include <QDBusConnectionInterface>
#include <QDBusMessage>
#include <QDBusPendingCall>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QJSEngine>

namespace {
// kwalletd6-Standardadresse (per `qdbus-qt6 org.kde.kwalletd6
// /modules/kwalletd6` verifiziert).
const QString kPath = QStringLiteral("/modules/kwalletd6");
const QString kIface = QStringLiteral("org.kde.KWallet");
} // namespace

KeyRing::KeyRing(QObject *parent)
    : QObject(parent)
    , m_connection(QDBusConnection::sessionBus())
{
    connectWalletClosed();
}

QString KeyRing::walletName() const { return m_walletName; }

void KeyRing::setWalletName(const QString &walletName)
{
    if (walletName == m_walletName)
        return;
    m_walletName = walletName;
    // Anderes Wallet = anderer Schlüsselraum: Verbindung zurücksetzen,
    // damit der nächste Zugriff neu öffnet.
    m_handle = -1;
    m_folderReady = false;
    Q_EMIT walletNameChanged();
}

QString KeyRing::folder() const { return m_folder; }

void KeyRing::setFolder(const QString &folder)
{
    if (folder == m_folder)
        return;
    m_folder = folder;
    m_folderReady = false;
    Q_EMIT folderChanged();
}

// Umgebungsvariable AURORA_<KEYREF>_KEY, z. B. AURORA_OPENROUTER_KEY für
// keyRef "openrouter" — kopf-loser Betrieb ohne Wallet-Prompt.
QString KeyRing::envKey(const QString &keyRef)
{
    const QString name = QStringLiteral("AURORA_%1_KEY").arg(keyRef.toUpper());
    return qEnvironmentVariable(qPrintable(name));
}

QString KeyRing::appId() const
{
    const QString app = QCoreApplication::applicationName();
    return app.isEmpty() ? QStringLiteral("net.niuton.aurora") : app;
}

void KeyRing::setConnectionForTesting(const QDBusConnection &connection,
                                      const QString &serviceName)
{
    m_connection = connection;
    if (!serviceName.isEmpty())
        m_service = serviceName;
    m_handle = -1;
    m_opening = false;
    m_folderReady = false;
    connectWalletClosed();
}

void KeyRing::connectWalletClosed()
{
    // Wallet während der Sitzung gesperrt/geschlossen: Cache zurücksetzen,
    // der nächste Zugriff öffnet automatisch neu. SLOT-basiert, weil der
    // Funktor-Overload diesen Signal-Namen nicht auflösen kann.
    m_connection.connect(m_service, kPath, kIface, QStringLiteral("walletClosed"),
                         this, SLOT(onWalletClosed()));
}

void KeyRing::onWalletClosed()
{
    m_handle = -1;
    m_folderReady = false;
}

void KeyRing::invoke(const QJSValue &callback, const QVariantMap &result)
{
    if (!callback.isCallable())
        return;
    QJSEngine *engine = qjsEngine(this);
    if (!engine)
        return; // Engine-Teardown: nie in eine tote Engine rufen
    if (engine->isInterrupted())
        return;
    callback.call({ engine->toScriptValue(result) });
}

void KeyRing::readSecret(const QString &keyRef, const QJSValue &callback)
{
    readSecret(keyRef, [this, callback](const QVariantMap &result) {
        invoke(callback, result);
    });
}

void KeyRing::writeSecret(const QString &keyRef, const QString &secret,
                          const QJSValue &callback)
{
    writeSecret(keyRef, secret, [this, callback](const QVariantMap &result) {
        invoke(callback, result);
    });
}

void KeyRing::removeSecret(const QString &keyRef, const QJSValue &callback)
{
    removeSecret(keyRef, [this, callback](const QVariantMap &result) {
        invoke(callback, result);
    });
}

void KeyRing::readSecret(const QString &keyRef,
                         std::function<void(const QVariantMap &)> callback)
{
    if (!callback)
        return;
    const QString env = envKey(keyRef);
    if (!env.isEmpty()) {
        QVariantMap result;
        result[QStringLiteral("ok")] = true;
        result[QStringLiteral("secret")] = env;
        result[QStringLiteral("source")] = QStringLiteral("env");
        callback(result);
        return;
    }
    Pending op;
    op.key = keyRef;
    op.callback = std::move(callback);
    m_queue.append(op);
    flush();
}

void KeyRing::writeSecret(const QString &keyRef, const QString &secret,
                          std::function<void(const QVariantMap &)> callback)
{
    if (!callback)
        return;
    Pending op;
    op.key = keyRef;
    op.value = secret;
    op.isWrite = true;
    op.callback = std::move(callback);
    m_queue.append(op);
    flush();
}

void KeyRing::removeSecret(const QString &keyRef,
                           std::function<void(const QVariantMap &)> callback)
{
    if (!callback)
        return;
    Pending op;
    op.key = keyRef;
    op.isRemove = true;
    op.callback = std::move(callback);
    m_queue.append(op);
    flush();
}

void KeyRing::drainError(const QString &error)
{
    const QString message = error.isEmpty()
        ? QStringLiteral("KWallet nicht erreichbar")
        : error;
    while (!m_queue.isEmpty()) {
        const Pending op = m_queue.takeFirst();
        QVariantMap result;
        result[QStringLiteral("ok")] = false;
        result[QStringLiteral("error")] = message;
        op.callback(result);
    }
}

// Bearbeitet alles, was die Wallet-Verbindung braucht; schließt offene
// Zustände von selbst ab (öffnen -> Ordner -> Queue).
void KeyRing::flush()
{
    if (m_handle <= 0) {
        ensureOpen(); // ruft flush() nach dem Öffnen wieder auf
        return;
    }
    if (!m_folderReady) {
        ensureFolder();
        return;
    }
    while (!m_queue.isEmpty())
        dispatch(m_queue.takeFirst());
}

void KeyRing::ensureOpen()
{
    if (m_handle > 0 || m_opening)
        return;
    // Fail fast, wenn kein Daemon läuft: NameHasOwner ist ein synchroner
    // Call, aber billig — nur der erste Zugriff kommt hierher.
    if (!m_connection.interface()
            || !m_connection.interface()->isServiceRegistered(m_service)) {
        drainError(QString());
        return;
    }
    m_opening = true;
    QDBusMessage msg = QDBusMessage::createMethodCall(m_service, kPath, kIface,
                                                      QStringLiteral("open"));
    msg << m_walletName << ++m_txId << appId();
    QDBusPendingCall pending = m_connection.asyncCall(msg);
    auto *watcher = new QDBusPendingCallWatcher(pending, this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this,
            [this](QDBusPendingCallWatcher *w) {
                w->deleteLater();
                m_opening = false;
                QDBusPendingReply<int> reply(*w);
                if (reply.isError()) {
                    drainError(reply.error().message());
                    return;
                }
                // kwalletd liefert <= 0, wenn das Wallet abgelehnt wurde
                // (0 = vom Nutzer verneint, -1 = Fehler).
                const int handle = reply.value();
                if (handle <= 0) {
                    drainError(QStringLiteral("Wallet konnte nicht geöffnet werden"));
                    return;
                }
                m_handle = handle;
                m_folderReady = false;
                flush();
            });
}

void KeyRing::ensureFolder()
{
    if (m_handle <= 0 || m_opening || m_folderReady)
        return;
    m_opening = true; // Guard gegen Mehrfach-Erzeugung; flush() trägt nichts bei, solange false
    QDBusMessage msg = QDBusMessage::createMethodCall(m_service, kPath, kIface,
                                                      QStringLiteral("createFolder"));
    msg << m_handle << m_folder << appId();
    QDBusPendingCall pending = m_connection.asyncCall(msg);
    auto *watcher = new QDBusPendingCallWatcher(pending, this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this,
            [this](QDBusPendingCallWatcher *w) {
                w->deleteLater();
                m_opening = false;
                // Fehler hier sind tolerierbar — bei machen Daemon-Versionen
                // existiert der Ordner schon; die eigentliche Operation wird
                // trotzdem versucht und meldet ihr eigenes Ergebnis.
                m_folderReady = true;
                flush();
            });
}

void KeyRing::dispatch(const Pending &op)
{
    QDBusMessage msg;
    if (op.isWrite) {
        msg = QDBusMessage::createMethodCall(m_service, kPath, kIface,
                                             QStringLiteral("writePassword"));
        msg << m_handle << m_folder << op.key << op.value << appId();
    } else if (op.isRemove) {
        msg = QDBusMessage::createMethodCall(m_service, kPath, kIface,
                                             QStringLiteral("removeEntry"));
        msg << m_handle << m_folder << op.key << appId();
    } else {
        msg = QDBusMessage::createMethodCall(m_service, kPath, kIface,
                                             QStringLiteral("readPassword"));
        msg << m_handle << m_folder << op.key << appId();
    }
    QDBusPendingCall pending = m_connection.asyncCall(msg);
    auto *watcher = new QDBusPendingCallWatcher(pending, this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this,
            [this, op](QDBusPendingCallWatcher *w) {
                w->deleteLater();
                QVariantMap result;
                if (w->isError()) {
                    result[QStringLiteral("ok")] = false;
                    result[QStringLiteral("error")] = w->error().message();
                } else if (op.isWrite || op.isRemove) {
                    QDBusPendingReply<int> reply(*w);
                    const bool ok = !reply.isError() && reply.value() == 0;
                    result[QStringLiteral("ok")] = ok;
                    if (!ok)
                        result[QStringLiteral("error")] =
                            QStringLiteral("KWallet hat den Eintrag abgelehnt");
                } else {
                    QDBusPendingReply<QString> reply(*w);
                    if (reply.isError()) {
                        result[QStringLiteral("ok")] = false;
                        result[QStringLiteral("error")] = reply.error().message();
                    } else {
                        result[QStringLiteral("ok")] = true;
                        result[QStringLiteral("secret")] = reply.value();
                        result[QStringLiteral("source")] = QStringLiteral("wallet");
                    }
                }
                op.callback(result);
            });
}