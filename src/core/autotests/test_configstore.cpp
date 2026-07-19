#include <QtTest>
#include <QTemporaryDir>
#include <QSignalSpy>
#include <QFile>
#include <QTextStream>
#include "configstore.h"

class TestConfigStore : public QObject
{
    Q_OBJECT

    QTemporaryDir *m_dir = nullptr;
    QString m_path;

private Q_SLOTS:
    void init() {
        m_dir = new QTemporaryDir();
        m_path = m_dir->path() + "/net.niuton.aurora.rc";
        qputenv("AURORA_CONFIG_PATH", m_path.toLocal8Bit());
    }
    void cleanup() {
        qunsetenv("AURORA_CONFIG_PATH");
        delete m_dir; m_dir = nullptr;
    }

    void defaultFallback() {
        ConfigStore s;
        QCOMPARE(s.value("modelLowPower").toString(), QStringLiteral("gemma4:e2b"));
        QCOMPARE(s.value("unloadSeconds").toInt(), 300);
        QCOMPARE(s.value("remoteEnabled").toBool(), true);
        QVERIFY(s.value("remoteEndpoint").toString().isEmpty());
    }

    void roundtripAndRevision() {
        ConfigStore s;
        QSignalSpy rev(&s, &ConfigStore::revisionChanged);
        QSignalSpy chg(&s, &ConfigStore::valueChanged);
        s.setValue("modelLowPower", QStringLiteral("qwen3.5:0.8b"));
        QCOMPARE(s.value("modelLowPower").toString(), QStringLiteral("qwen3.5:0.8b"));
        QVERIFY(rev.count() >= 1);      // >=1: der eigene Write kann via Watcher einen 2. idempotenten Bump ausloesen
        QVERIFY(chg.count() >= 1);
    }

    void idempotentSetNoBump() {
        ConfigStore s;
        s.setValue("unloadSeconds", 300);       // == Default -> kein Write, kein Bump
        QSignalSpy rev(&s, &ConfigStore::revisionChanged);
        s.setValue("unloadSeconds", 300);
        QCOMPARE(rev.count(), 0);
    }

    // KRITISCH: echter Cross-Process-Typ-Read. Eine roh geschriebene INI (nur
    // Text) muss von value() typrichtig als bool zurueckkommen — nicht als
    // QString (den QML zu true koerzieren wuerde). QFile-Write umgeht den
    // QConfFile-Cache, den ein Zwei-Instanzen-Read im selben Prozess teilt.
    void crossProcessBoolType() {
        {
            QFile f(m_path);
            QVERIFY(f.open(QIODevice::WriteOnly | QIODevice::Text));
            QTextStream(&f) << "[General]\nremoteEnabled=false\ntwoPhaseToolCalls=true\ntoolMaxRounds=9\n";
        }
        ConfigStore s;                          // liest die frisch geparste Datei
        const QVariant b = s.value("remoteEnabled");
        QCOMPARE(b.metaType().id(), QMetaType::Bool);
        QCOMPARE(b.toBool(), false);
        QCOMPARE(s.value("twoPhaseToolCalls").metaType().id(), QMetaType::Bool);
        QCOMPARE(s.value("twoPhaseToolCalls").toBool(), true);
        QCOMPARE(s.value("toolMaxRounds").metaType().id(), QMetaType::Int);
        QCOMPARE(s.value("toolMaxRounds").toInt(), 9);
    }

    // Haertungswelle Fund 6 (Nitpick): ein nicht konvertierbarer INI-Wert
    // (korrupt/hand-editiert) muss auf den SCHEMA-DEFAULT fallen — nicht auf
    // die Typ-Null des Zieltyps (toolMaxRounds->0 waere "keine Tool-Runden").
    void corruptIniValueFallsBackToSchemaDefault() {
        {
            QFile f(m_path);
            QVERIFY(f.open(QIODevice::WriteOnly | QIODevice::Text));
            QTextStream(&f) << "[General]\ntoolMaxRounds=keinezahl\nunloadSeconds=3.5.7\n"
                               "remoteEnabled=vielleicht\nragThreshold=xyz\n";
        }
        ConfigStore s;
        const QVariant rounds = s.value("toolMaxRounds");
        QCOMPARE(rounds.metaType().id(), QMetaType::Int);
        QCOMPARE(rounds.toInt(), 5);                       // Default, nicht 0
        QCOMPARE(s.value("unloadSeconds").toInt(), 300);   // Default, nicht 0
        QCOMPARE(s.value("remoteEnabled").toBool(), true); // Default, nicht false
        QCOMPARE(s.value("ragThreshold").toDouble(), 0.75);
    }

    void resetPreservesMarker() {
        ConfigStore s;
        s.setValue("_migratedFromAppletsrc", true);
        s.setValue("modelLowPower", QStringLiteral("x"));
        s.reset();
        QVERIFY(s.contains("_migratedFromAppletsrc"));        // Marker ueberlebt
        QCOMPARE(s.value("modelLowPower").toString(), QStringLiteral("gemma4:e2b"));   // Rest auf Default
    }

    void containsReflectsStore() {
        ConfigStore s;
        QVERIFY(!s.contains("ttsVoice"));
        s.setValue("ttsVoice", QStringLiteral("de_DE-kerstin-low"));
        QVERIFY(s.contains("ttsVoice"));
    }

    // Self-Write-Unterdrueckung (diskriminierend): setValue() bumpt die revision
    // synchron genau EINMAL. Der eigene Write loest asynchron ein
    // QFileSystemWatcher::fileChanged aus; der Handler erkennt es via Inhalts-
    // Snapshot als eigen und macht KEIN Re-Sync/Bump. Nach dem Draining muss die
    // revision daher immer noch bei genau 1 stehen. Der alte Handler (bedingungslos
    // sync()+bump bei jeder Aenderung) haette hier einen zweiten, asynchronen Bump
    // erzeugt -> count == 2. Dieser Test unterscheidet also alten von neuem Handler
    // (verifiziert per revert-test-restore).
    void selfWriteEmitsExactlyOneRevisionBump() {
        ConfigStore s;
        QSignalSpy rev(&s, &ConfigStore::revisionChanged);
        s.setValue("lastSelectedModel", QStringLiteral("local:x"));
        QCOMPARE(rev.count(), 1);                 // synchroner Bump aus setValue()
        for (int i = 0; i < 15; ++i) {            // ~300 ms: dem async fileChanged Zeit geben
            QTest::qWait(20);
            QCoreApplication::processEvents();
        }
        QCOMPARE(rev.count(), 1);                 // Fix: bleibt 1; alter Handler: 2
        QCOMPARE(s.value("lastSelectedModel").toString(), QStringLiteral("local:x"));
    }

    // Watcher: eine externe .rc-Aenderung (andere "Engine") bumpt die revision.
    void externalChangeBumpsRevision() {
        ConfigStore s;
        QSignalSpy rev(&s, &ConfigStore::revisionChanged);
        {
            QFile f(m_path);
            QVERIFY(f.open(QIODevice::WriteOnly | QIODevice::Text));
            QTextStream(&f) << "[General]\nmodelLowPower=extern\n";
        }
        QVERIFY(rev.wait(3000));                               // Watcher feuert asynchron
        QCOMPARE(s.value("modelLowPower").toString(), QStringLiteral("extern"));
    }
};

QTEST_MAIN(TestConfigStore)
#include "test_configstore.moc"
