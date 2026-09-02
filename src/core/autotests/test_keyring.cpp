#include <QtTest>

#include <QDBusAbstractAdaptor>
#include <QDBusConnection>
#include <QDBusConnectionInterface>
#include <QHash>
#include <QProcess>
#include <QVariantMap>

#include "keyring.h"

// Minimaler Fake fuer org.kde.kwalletd6: Methodennamen und Rueckgabetypen
// wie der echte Daemon (per `qdbus-qt6 org.kde.kwalletd6 /modules/kwalletd6`
// verifiziert). Nur die Passwort-Routinen, die KeyRing braucht. Als
// QDBusAbstractAdaptor, damit die D-Bus-Schnittstelle wirklich
// "org.kde.KWallet" heißt — ein plain QObject exportiert sonst nur
// "local.<Klassenname>".
class FakeWallet : public QDBusAbstractAdaptor
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.kde.KWallet")
public:
    explicit FakeWallet(QObject *parent)
        : QDBusAbstractAdaptor(parent)
    {
    }
    bool failOpen = false;
    int openCalls = 0;
    QHash<QString, QString> passwords;   // "folder/key" -> Secret

public Q_SLOTS:
    int open(const QString &wallet, qlonglong wId, const QString &appid)
    {
        Q_UNUSED(wallet);
        Q_UNUSED(wId);
        Q_UNUSED(appid);
        ++openCalls;
        return failOpen ? 0 : 7;
    }
    bool createFolder(int handle, const QString &folder, const QString &appid)
    {
        Q_UNUSED(handle);
        Q_UNUSED(folder);
        Q_UNUSED(appid);
        return true;
    }
    QString readPassword(int handle, const QString &folder, const QString &key,
                         const QString &appid)
    {
        Q_UNUSED(handle);
        Q_UNUSED(appid);
        return passwords.value(folder + QLatin1Char('/') + key);
    }
    int writePassword(int handle, const QString &folder, const QString &key,
                      const QString &value, const QString &appid)
    {
        Q_UNUSED(handle);
        Q_UNUSED(appid);
        passwords.insert(folder + QLatin1Char('/') + key, value);
        return 0;
    }
    int removeEntry(int handle, const QString &folder, const QString &key,
                    const QString &appid)
    {
        Q_UNUSED(handle);
        Q_UNUSED(appid);
        passwords.remove(folder + QLatin1Char('/') + key);
        return 0;
    }
};

class TestKeyRing : public QObject
{
    Q_OBJECT

public:
    TestKeyRing() = default;

private:
    void waitForResult() { QTRY_VERIFY_WITH_TIMEOUT(m_got, 5000); }
    void waitForBoth() { QTRY_VERIFY_WITH_TIMEOUT(m_gotA && m_gotB, 5000); }

    bool m_got = false;
    QVariantMap m_result;
    bool m_gotA = false;
    bool m_gotB = false;
    QVariantMap m_resultA;
    QVariantMap m_resultB;

    QProcess *m_daemon = nullptr;                  // privater dbus-daemon (Session-Ersatz)
    QString m_address;
    QDBusConnection m_fakeBus{QDBusConnection::sessionBus()};
    QDBusConnection m_clientBus{QDBusConnection::sessionBus()};
    QObject m_owner;                               // Besitzer des Fake-Adaptors
    FakeWallet *m_wallet = nullptr;
    KeyRing *m_ring = nullptr;

private Q_SLOTS:
    void initTestCase()
    {
        // Eigener dbus-daemon als Ersatz fuer die KDE-Session: Tests muessen
        // ohne Desktop und ohne echtes kwalletd laufen. Der Daemon beantwortet
        // Handshake und Namensregistrierung — ein QDBusServer (nur Router)
        // tut das nicht (connectToBus blockiert dort).
        m_daemon = new QProcess(this);
        m_daemon->start("dbus-daemon", { "--nofork", "--print-address=1", "--session" });
        QVERIFY(m_daemon->waitForStarted(5000));
        QTRY_VERIFY_WITH_TIMEOUT(m_daemon->canReadLine(), 5000);
        m_address = QString::fromLocal8Bit(m_daemon->readLine()).trimmed();
        if (m_address.isEmpty())
            QSKIP("dbus-daemon hat keine Adresse geliefert");

        m_wallet = new FakeWallet(&m_owner);
        m_fakeBus = QDBusConnection::connectToBus(m_address, "fake-kwallet");
        QVERIFY(m_fakeBus.isConnected());
        QVERIFY(m_fakeBus.registerService("org.kde.kwalletd6"));
        QVERIFY(m_fakeBus.registerObject("/modules/kwalletd6", &m_owner,
                                         QDBusConnection::ExportAdaptors));
        m_clientBus = QDBusConnection::connectToBus(m_address, "keyring-client");
        QVERIFY(m_clientBus.isConnected());
        // Dienst-Registrierung ist asynchron; warten, bis der Client ihn sieht.
        QTRY_VERIFY_WITH_TIMEOUT(
            m_clientBus.interface()->isServiceRegistered("org.kde.kwalletd6"), 5000);
    }

    void cleanupTestCase()
    {
        if (m_daemon) {
            m_daemon->kill();
            m_daemon->waitForFinished(3000);
        }
    }

    void init()
    {
        m_got = false;
        m_gotA = false;
        m_gotB = false;
        m_result.clear();
        m_resultA.clear();
        m_resultB.clear();
        m_wallet->passwords.clear();
        m_wallet->failOpen = false;
        m_wallet->openCalls = 0;
        unsetenv("AURORA_OPENROUTER_KEY");
        m_ring = new KeyRing(this);
        m_ring->setConnectionForTesting(m_clientBus);
    }

    void cleanup() { delete m_ring; m_ring = nullptr; }

    // Lesen ohne Eintrag: ok, aber leer — FALSCH waere persistiert oder error.
    void test_readLeerOhneEintrag()
    {
        m_ring->readSecret("openrouter",
                           [this](const QVariantMap &r) { m_got = true; m_result = r; });
        waitForResult();
        QCOMPARE(m_result.value("ok").toBool(), true);
        QCOMPARE(m_result.value("secret").toString(), QString());
        QCOMPARE(m_result.value("source").toString(), "wallet");
    }

    // write -> read Round-Trip ueber den Fake-Daemon.
    void test_writeReadRoundTrip()
    {
        m_ring->writeSecret("openrouter", "geheim-123",
                            [this](const QVariantMap &r) { m_got = true; m_result = r; });
        waitForResult();
        QCOMPARE(m_result.value("ok").toBool(), true);

        m_got = false;
        m_ring->readSecret("openrouter",
                           [this](const QVariantMap &r) { m_got = true; m_result = r; });
        waitForResult();
        QCOMPARE(m_result.value("secret").toString(), "geheim-123");
        // Es liegt wirklich im Wallet (Env-Variable ist leer).
        QCOMPARE(m_wallet->passwords.value("net.niuton.aurora/openrouter"),
                 QStringLiteral("geheim-123"));
    }

    // Env-Rueckfall (kopf-loser Betrieb): greift, ohne den Bus zu beruehren.
    void test_envFallbackGreiftOhneBus()
    {
        setenv("AURORA_OPENROUTER_KEY", "sk-aus-umgebung", 1);
        m_ring->readSecret("openrouter",
                           [this](const QVariantMap &r) { m_got = true; m_result = r; });
        waitForResult();
        QCOMPARE(m_result.value("ok").toBool(), true);
        QCOMPARE(m_result.value("secret").toString(), "sk-aus-umgebung");
        QCOMPARE(m_result.value("source").toString(), "env");
        QCOMPARE(m_wallet->openCalls, 0);   // der Bus wurde nie gefragt
    }

    // removeSecret entfernt den Eintrag wieder.
    void test_removeEntferntEintrag()
    {
        m_ring->writeSecret("openrouter", "wegwerf",
                            [this](const QVariantMap &r) { m_got = true; m_result = r; });
        waitForResult();
        QCOMPARE(m_wallet->passwords.size(), 1);

        m_got = false;
        m_ring->removeSecret("openrouter",
                             [this](const QVariantMap &r) { m_got = true; m_result = r; });
        waitForResult();
        QCOMPARE(m_result.value("ok").toBool(), true);
        QCOMPARE(m_wallet->passwords.size(), 0);
    }

    // Schlagen Open fehl (Wallet abgelehnt), kommt ein Fehler, kein Erfolg.
    void test_openFehlschlagMeldetFehler()
    {
        m_wallet->failOpen = true;
        m_ring->readSecret("openrouter",
                           [this](const QVariantMap &r) { m_got = true; m_result = r; });
        waitForResult();
        QCOMPARE(m_result.value("ok").toBool(), false);
        QVERIFY(!m_result.value("error").toString().isEmpty());
    }

    // Zwei parallele Instanzen: jede stößt ihr eigenes open an, keine Anfrage
    // geht verloren. Gewartet wird auf BEIDE Ergebnisse — nur eins abzuwarten
    // würde eine verlorene Anfrage nicht aufdecken.
    void test_paralleleAnfragenGehenNichtVerloren()
    {
        m_wallet->passwords.insert("net.niuton.aurora/openrouter", "doppelt");
        m_ring->readSecret("openrouter",
                           [this](const QVariantMap &r) { m_gotA = true; m_resultA = r; });
        KeyRing ring2;
        ring2.setConnectionForTesting(m_clientBus);
        ring2.readSecret("openrouter",
                         [this](const QVariantMap &r) { m_gotB = true; m_resultB = r; });
        waitForBoth();
        QCOMPARE(m_resultA.value("secret").toString(), "doppelt");
        QCOMPARE(m_resultB.value("secret").toString(), "doppelt");
        QCOMPARE(m_wallet->openCalls, 2);   // je Instanz genau ein open
    }

    // Ohne erreichbaren Dienst: sofortiger Fehler statt Haenger.
    void test_ohneDienstFehler()
    {
        KeyRing ring;
        ring.setConnectionForTesting(m_clientBus, "org.kde.kwalletd6.gibt.es.nicht");
        m_got = false;
        ring.readSecret("openrouter",
                        [this](const QVariantMap &r) { m_got = true; m_result = r; });
        waitForResult();
        QCOMPARE(m_result.value("ok").toBool(), false);
    }
};

QTEST_GUILESS_MAIN(TestKeyRing)
#include "test_keyring.moc"