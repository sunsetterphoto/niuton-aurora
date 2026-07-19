#include <csignal>
#include <QFile>
#include <QSignalSpy>
#include <QtTest>

#include <unistd.h>   // kill(pid, 0) für Gruppen-Kill-Nachweis

#include "processrunner.h"

// Tot oder Zombie: kill(pid,0)!=0 ODER Prozesszustand 'Z' in /proc/<pid>/stat.
// (kill(pid,0) liefert für Zombies weiterhin 0 — wer den Enkel reapt, ist
// nicht unser Vertrag; wir messen nur, dass killpg ihn erwischt hat.)
static bool totOderZombie(qint64 pid)
{
    if (::kill(pid_t(pid), 0) != 0)
        return true;
    QFile f(QString("/proc/%1/stat").arg(pid));
    if (!f.open(QIODevice::ReadOnly))
        return true;
    const QByteArray stat = f.readAll();
    const int close = stat.lastIndexOf(')');
    return close >= 0 && stat.size() > close + 2 && stat[close + 2] == 'Z';
}

// Wartet, bis der Runner fertig ist (finished ODER failed), max. timeoutMs.
static bool warteAufEnde(ProcessRunner *pr, int timeoutMs = 5000)
{
    QSignalSpy fin(pr, &ProcessRunner::finished);
    QSignalSpy fail(pr, &ProcessRunner::failed);
    QElapsedTimer t;
    t.start();
    while (fin.isEmpty() && fail.isEmpty()) {
        if (t.elapsed() > timeoutMs)
            return false;
        QCoreApplication::processEvents(QEventLoop::AllEvents, 25);
    }
    return true;
}

// Haertungswelle Fund 4: faengt die QProcess-Dtor-Warnung ab, die der
// alte (blockierende) Teardown-Pfad im Timeout-Fall produzierte.
static bool g_destroyedWarning = false;
static void dtorWarnHandler(QtMsgType, const QMessageLogContext &, const QString &msg)
{
    if (msg.contains(QStringLiteral("Destroyed while process is still running")))
        g_destroyedWarning = true;
}

class TestProcessRunner : public QObject
{
    Q_OBJECT

private Q_SLOTS:
    void echo_liefertStdoutUndExitNull()
    {
        ProcessRunner pr;
        QSignalSpy fin(&pr, &ProcessRunner::finished);
        pr.start("echo", {"hallo welt"});
        QVERIFY(warteAufEnde(&pr));
        QCOMPARE(fin.count(), 1);
        QCOMPARE(fin.first().at(0).toInt(), 0);                       // exitCode
        QCOMPARE(fin.first().at(1).toString().trimmed(), QString("hallo welt")); // stdout
        QCOMPARE(fin.first().at(4).toBool(), false);                 // timedOut
        QCOMPARE(pr.running(), false);
    }

    void argsWerdenNichtVomShellInterpretiert()
    {
        // $HOME und ; würden im Shell expandiert/getrennt — als argv bleiben sie roh.
        ProcessRunner pr;
        QSignalSpy fin(&pr, &ProcessRunner::finished);
        pr.start("echo", {"$HOME; rm -rf /"});
        QVERIFY(warteAufEnde(&pr));
        QCOMPARE(fin.first().at(1).toString().trimmed(), QString("$HOME; rm -rf /"));
    }

    void programNichtGefunden_feuertFailed()
    {
        ProcessRunner pr;
        QSignalSpy fail(&pr, &ProcessRunner::failed);
        pr.start("/kein/solches/programm_xyz", {});
        QVERIFY(warteAufEnde(&pr));
        QCOMPARE(fail.count(), 1);
        QVERIFY(!fail.first().at(0).toString().isEmpty());
    }

    void stdinWirdGeschrieben()
    {
        ProcessRunner pr;
        QSignalSpy fin(&pr, &ProcessRunner::finished);
        pr.start("cat", {});
        pr.writeStdin(QByteArrayLiteral("aus stdin"));   // KEINE implizite QString->QByteArray-Konvertierung in Qt 6
        pr.closeStdin();
        QVERIFY(warteAufEnde(&pr));
        QCOMPARE(fin.first().at(1).toString(), QString("aus stdin"));
    }

    void binaerStdout_bleibtUnverfaelscht()
    {
        // 32 zufällige Bytes über stdoutChunk einsammeln (ArrayBuffer/QByteArray)
        ProcessRunner pr;
        QByteArray gesammelt;
        connect(&pr, &ProcessRunner::stdoutChunk, this,
                [&gesammelt](const QByteArray &c) { gesammelt.append(c); });
        pr.start("head", {"-c", "32", "/dev/urandom"});
        QVERIFY(warteAufEnde(&pr));
        QCOMPARE(gesammelt.size(), 32);
    }

    void maxOutputBytes_kappt_und_setztTruncated()
    {
        ProcessRunner pr;
        pr.setMaxOutputBytes(100);
        QSignalSpy fin(&pr, &ProcessRunner::finished);
        pr.start("seq", {"1", "100000"});           // weit über 100 Bytes
        QVERIFY(warteAufEnde(&pr));
        QVERIFY(fin.first().at(1).toString().toUtf8().size() <= 100);
        QCOMPARE(fin.first().at(3).toBool(), true);  // truncated
    }

    void mergeStderr_mischtInStdout()
    {
        ProcessRunner pr;
        pr.setMergeStderr(true);
        QSignalSpy fin(&pr, &ProcessRunner::finished);
        pr.start("ls", {"/gibt_es_nicht_aurora_xyz"});   // schreibt auf stderr, exit != 0
        QVERIFY(warteAufEnde(&pr));
        QVERIFY(fin.first().at(1).toString().contains(QStringLiteral("gibt_es_nicht_aurora_xyz"))); // stdout
        QCOMPARE(fin.first().at(2).toString(), QString());                                          // stderr leer
    }

    void timeout_killt_und_meldetTimedOut()
    {
        ProcessRunner pr;
        pr.setTimeoutMs(300);
        QSignalSpy fin(&pr, &ProcessRunner::finished);
        pr.start("sleep", {"5"});
        QVERIFY(warteAufEnde(&pr, 3000));
        QCOMPARE(fin.count(), 1);
        QCOMPARE(fin.first().at(4).toBool(), true);   // timedOut
        QCOMPARE(pr.running(), false);
    }

    void terminate_beendetLaufendenProzess()
    {
        ProcessRunner pr;
        QSignalSpy started(&pr, &ProcessRunner::started);
        QSignalSpy fin(&pr, &ProcessRunner::finished);
        pr.start("sleep", {"30"});
        // running() ist sofort nach start() true (m_process gesetzt) — auf das
        // started()-Signal warten, das erst NACH exec (und damit setsid) feuert.
        // Sonst kann killpg das Kind vor setsid verfehlen.
        QVERIFY(started.wait(3000));
        pr.terminate();
        QVERIFY(warteAufEnde(&pr, 3000));
        QCOMPARE(fin.count(), 1);
        QCOMPARE(pr.running(), false);
    }

    void restartNachFinished_setztZustandZurueck()
    {
        // Vertrag: nach finished ist der Runner wieder startbar; Flags/Puffer/
        // Timer sind zurückgesetzt (Produktions-Hauptpfad: Speaker reused Runner).
        ProcessRunner pr;
        pr.setTimeoutMs(150);
        QSignalSpy fin(&pr, &ProcessRunner::finished);
        pr.start("sleep", {"5"});
        QVERIFY(warteAufEnde(&pr, 3000));
        QCOMPARE(fin.count(), 1);
        QCOMPARE(fin.at(0).at(4).toBool(), true);    // timedOut

        pr.setTimeoutMs(0);
        pr.start("echo", {"zweiter"});
        QVERIFY(warteAufEnde(&pr, 3000));
        QCOMPARE(fin.count(), 2);
        QCOMPARE(fin.at(1).at(0).toInt(), 0);
        QCOMPARE(fin.at(1).at(1).toString().trimmed(), QString("zweiter"));
        QCOMPARE(fin.at(1).at(3).toBool(), false);   // truncated zurückgesetzt
        QCOMPARE(fin.at(1).at(4).toBool(), false);   // timedOut zurückgesetzt
    }

    void startAufLaufendemRunner_wirdIgnoriert()
    {
        // Vertrag: zweiter start() auf laufendem Runner ist ein No-Op.
        ProcessRunner pr;
        QSignalSpy started(&pr, &ProcessRunner::started);
        QSignalSpy fin(&pr, &ProcessRunner::finished);
        pr.start("sleep", {"30"});
        QVERIFY(started.wait(3000));
        pr.start("echo", {"verschluckt"});   // muss ignoriert werden
        pr.terminate();
        QVERIFY(warteAufEnde(&pr, 3000));
        QCOMPARE(fin.count(), 1);            // genau EIN Lauf, kein echo-Output
        QVERIFY(!fin.first().at(1).toString().contains(QStringLiteral("verschluckt")));
    }

    void stderrGetrennt_chunksUndFinished()
    {
        // Shell im Test erlaubt: stderr/stdout gezielt befüllen.
        ProcessRunner pr;
        QSignalSpy errChunks(&pr, &ProcessRunner::stderrChunk);
        QSignalSpy fin(&pr, &ProcessRunner::finished);
        pr.start("sh", {"-c", "echo raus; echo fehler >&2"});
        QVERIFY(warteAufEnde(&pr));
        QVERIFY(errChunks.count() >= 1);
        QVERIFY(fin.first().at(1).toString().contains(QStringLiteral("raus")));
        QVERIFY(fin.first().at(2).toString().contains(QStringLiteral("fehler")));
    }

    void environment_wirdUeberSystemEnvGemergt()
    {
        ProcessRunner pr;
        pr.setEnvironment({{QStringLiteral("AURORA_TESTVAR"), QStringLiteral("42")}});
        QSignalSpy fin(&pr, &ProcessRunner::finished);
        pr.start("sh", {"-c", "printf %s \"$AURORA_TESTVAR:$HOME\""});
        QVERIFY(warteAufEnde(&pr));
        const QString out = fin.first().at(1).toString();
        QVERIFY(out.startsWith(QStringLiteral("42:")));
        QVERIFY(out.length() > 4);   // $HOME aus System-Env vorhanden (Merge, kein Ersatz)
    }

    void workingDirectory_wirkt()
    {
        ProcessRunner pr;
        pr.setWorkingDirectory(QStringLiteral("/tmp"));
        QSignalSpy fin(&pr, &ProcessRunner::finished);
        pr.start("pwd", {});
        QVERIFY(warteAufEnde(&pr));
        QCOMPARE(fin.first().at(1).toString().trimmed(), QString("/tmp"));
    }

    void terminate_wirktAufGanzeProzessgruppe()
    {
        // sh startet ein Enkel-sleep, gibt dessen PID aus und wartet. terminate()
        // muss via killpg auch das Enkel-sleep beenden. (Shell nur im Test erlaubt.)
        ProcessRunner pr;
        qint64 enkelPid = 0;
        connect(&pr, &ProcessRunner::stdoutChunk, this, [&enkelPid](const QByteArray &c) {
            bool ok = false;
            const qint64 p = c.trimmed().toLongLong(&ok);
            if (ok && p > 0) enkelPid = p;
        });
        pr.start("sh", {"-c", "sleep 30 & echo $!; wait"});
        QTRY_VERIFY(enkelPid > 0);
        QVERIFY(!totOderZombie(enkelPid));   // Enkel lebt
        pr.terminate();
        QVERIFY(warteAufEnde(&pr, 3000));
        QTRY_VERIFY(totOderZombie(enkelPid));   // Gruppe gekillt (Zombie zählt als tot:
                                                // wer reapt, ist nicht unser Vertrag)
    }

    void sendSignal_SIGINT_beendetProzess()
    {
        ProcessRunner pr;
        QSignalSpy started(&pr, &ProcessRunner::started);
        QSignalSpy fin(&pr, &ProcessRunner::finished);
        pr.start("sleep", {"30"});
        QVERIFY(started.wait(3000));   // erst nach exec/setsid signalisieren
        pr.sendSignal(SIGINT);
        QVERIFY(warteAufEnde(&pr, 3000));
        QCOMPARE(fin.count(), 1);
    }

    void gekappterStdout_hatKeinErsatzzeichen()
    {
        // "äöü" wiederholt; Kappung bei 5 Bytes schneidet mitten in ein 2-Byte-Zeichen
        ProcessRunner pr;
        pr.setMaxOutputBytes(5);
        QSignalSpy fin(&pr, &ProcessRunner::finished);
        pr.start("printf", {"äöüäöü"});
        QVERIFY(warteAufEnde(&pr));
        const QString out = fin.first().at(1).toString();
        QVERIFY(!out.contains(QChar(0xFFFD)));      // kein Ersatzzeichen
        QCOMPARE(out, QString("äö"));               // 4 Bytes, an Zeichengrenze gekappt
        QCOMPARE(fin.first().at(3).toBool(), true); // truncated
    }

    void destruktor_killtProzessgruppe()
    {
        qint64 enkelPid = 0;
        auto *pr = new ProcessRunner;
        connect(pr, &ProcessRunner::stdoutChunk, this, [&enkelPid](const QByteArray &c) {
            bool ok = false;
            const qint64 p = c.trimmed().toLongLong(&ok);
            if (ok && p > 0) enkelPid = p;
        });
        pr->start("sh", {"-c", "sleep 30 & echo $!; wait"});
        QTRY_VERIFY(enkelPid > 0);
        QVERIFY(!totOderZombie(enkelPid));
        delete pr;                                   // Teardown mit laufendem Prozess
        QTRY_VERIFY(totOderZombie(enkelPid));        // Gruppe (inkl. Enkel) ist tot
    }

    // Haertungswelle Fund 4: der Dtor darf NIE blockieren (frueher
    // waitForFinished(1000) — timeoutet bei einem Kind im D-State) und darf
    // keine "Destroyed while process is still running"-Warnung hinterlassen:
    // das Kind wird gekillt und der QProcess reapt asynchron selbst.
    void destruktor_blockiertNicht_undWarntNicht()
    {
        g_destroyedWarning = false;
        QtMessageHandler alt = qInstallMessageHandler(dtorWarnHandler);
        auto *pr = new ProcessRunner;
        bool gestartet = false;
        connect(pr, &ProcessRunner::started, this, [&gestartet]() { gestartet = true; });
        pr->start("sleep", {"30"});
        QTRY_VERIFY(gestartet);             // erst nach exec/setsid: Gruppe existiert
        const qint64 pid = pr->pid();
        QVERIFY(pid > 0);
        QElapsedTimer t;
        t.start();
        delete pr;                          // darf nicht auf das Kind warten
        QVERIFY(t.elapsed() < 1000);        // alter Pfad konnte hier 1000 ms haengen
        QTest::qWait(300);                  // async reap (finished -> deleteLater)
        qInstallMessageHandler(alt);
        QVERIFY(!g_destroyedWarning);
        QTRY_VERIFY(totOderZombie(pid));    // Gruppe wurde trotzdem gekillt
    }

    void reentrantStartAusFailedHandler_einLaufKontext()
    {
        // Re-Entranz-Token: startet ein failed-Handler synchron neu, gehören
        // Timer/notify dem NEUEN Lauf — kein doppeltes runningChanged-Paar.
        ProcessRunner pr;
        QSignalSpy fin(&pr, &ProcessRunner::finished);
        QSignalSpy fail(&pr, &ProcessRunner::failed);
        connect(&pr, &ProcessRunner::failed, this, [&pr]() {
            pr.start("echo", {"zweiter lauf"});
        });
        pr.start("/kein/solches/programm_xyz", {});
        QVERIFY(warteAufEnde(&pr, 3000));
        QCOMPARE(fail.count(), 1);
        QTRY_COMPARE(fin.count(), 1);                // der Neustart läuft durch
        QCOMPARE(fin.first().at(1).toString().trimmed(), QString("zweiter lauf"));
        QCOMPARE(pr.running(), false);
    }
};

QTEST_GUILESS_MAIN(TestProcessRunner)
#include "test_processrunner.moc"
