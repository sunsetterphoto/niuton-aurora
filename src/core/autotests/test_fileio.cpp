#include <QtTest>
#include <QDir>
#include <QStandardPaths>
#include <QTemporaryDir>
#include <sys/stat.h>
#include "fileio.h"

class TestFileIO : public QObject
{
    Q_OBJECT

private Q_SLOTS:
    void initTestCase()
    {
        // ~/.qttest statt echtem ~/.local/share benutzen
        QStandardPaths::setTestModeEnabled(true);
    }

    void readText_fehlendeDatei()
    {
        FileIO io;
        const QVariantMap r = io.readText(QStringLiteral("/nonexistent/nowhere.txt"), 1024);
        QCOMPARE(r.value("ok").toBool(), false);
        QVERIFY(!r.value("error").toString().isEmpty());
    }

    void writeText_roundtrip_und_mkpath()
    {
        QTemporaryDir tmp;
        FileIO io;
        const QString path = tmp.path() + QStringLiteral("/a/b/c.txt");
        const QVariantMap w = io.writeText(path, QStringLiteral("Hallo Aurora"));
        QCOMPARE(w.value("ok").toBool(), true);
        const QVariantMap r = io.readText(path, 1024);
        QCOMPARE(r.value("ok").toBool(), true);
        QCOMPARE(r.value("text").toString(), QStringLiteral("Hallo Aurora"));
        QCOMPARE(r.value("truncated").toBool(), false);
    }

    void readText_kappt_bei_maxBytes()
    {
        QTemporaryDir tmp;
        FileIO io;
        const QString path = tmp.path() + QStringLiteral("/big.txt");
        QVERIFY(io.writeText(path, QString(1000, QLatin1Char('x'))).value("ok").toBool());
        const QVariantMap r = io.readText(path, 100);
        QCOMPARE(r.value("ok").toBool(), true);
        QCOMPARE(r.value("text").toString().size(), 100);
        QCOMPARE(r.value("truncated").toBool(), true);
    }

    void readBase64_dekodierbar_mit_mime()
    {
        QTemporaryDir tmp;
        FileIO io;
        const QString path = tmp.path() + QStringLiteral("/probe.txt");
        QVERIFY(io.writeText(path, QStringLiteral("abc")).value("ok").toBool());
        const QVariantMap r = io.readBase64(path, 1024);
        QCOMPARE(r.value("ok").toBool(), true);
        QCOMPARE(QByteArray::fromBase64(r.value("data").toString().toLatin1()),
                 QByteArrayLiteral("abc"));
        QCOMPARE(r.value("mime").toString(), QStringLiteral("text/plain"));
    }

    void listDir_liefert_eintraege()
    {
        QTemporaryDir tmp;
        FileIO io;
        QVERIFY(io.writeText(tmp.path() + QStringLiteral("/f.txt"), QStringLiteral("x")).value("ok").toBool());
        QVERIFY(io.mkpath(tmp.path() + QStringLiteral("/unterordner")));
        const QVariantMap r = io.listDir(tmp.path(), false);
        QCOMPARE(r.value("ok").toBool(), true);
        const QVariantList entries = r.value("entries").toList();
        QCOMPARE(entries.size(), 2);
        // DirsFirst: Ordner zuerst
        QCOMPARE(entries.at(0).toMap().value("isDir").toBool(), true);
        QCOMPARE(entries.at(1).toMap().value("name").toString(), QStringLiteral("f.txt"));

        const QVariantMap miss = io.listDir(QStringLiteral("/nonexistent/dir"), false);
        QCOMPARE(miss.value("ok").toBool(), false);
    }

    void fileInfo_und_exists()
    {
        QTemporaryDir tmp;
        FileIO io;
        const QString path = tmp.path() + QStringLiteral("/info.txt");
        QVERIFY(io.writeText(path, QStringLiteral("12345")).value("ok").toBool());
        QVERIFY(io.exists(path));
        const QVariantMap fi = io.fileInfo(path);
        QCOMPARE(fi.value("exists").toBool(), true);
        QCOMPARE(fi.value("isDir").toBool(), false);
        QCOMPARE(fi.value("size").toLongLong(), 5);
        QVERIFY(!fi.value("mtime").toString().isEmpty());
    }

    void maxBytes_nullOderNegativ_nutzt_default()
    {
        QTemporaryDir tmp;
        FileIO io;
        const QString path = tmp.path() + QStringLiteral("/klein.txt");
        QVERIFY(io.writeText(path, QStringLiteral("Aurora")).value("ok").toBool());

        // readText: maxBytes=0 → Default-Limit, Datei vollständig lesbar
        const QVariantMap r = io.readText(path, 0);
        QCOMPARE(r.value("ok").toBool(), true);
        QCOMPARE(r.value("text").toString(), QStringLiteral("Aurora"));
        QCOMPARE(r.value("truncated").toBool(), false);

        // readBase64: maxBytes=0 → Default-Limit statt Ablehnung
        const QVariantMap b = io.readBase64(path, 0);
        QCOMPARE(b.value("ok").toBool(), true);
        QCOMPARE(QByteArray::fromBase64(b.value("data").toString().toLatin1()),
                 QByteArrayLiteral("Aurora"));
    }

    void standardPath_appData()
    {
        FileIO io;
        const QString p = io.standardPath(QStringLiteral("appData"));
        QVERIFY(p.endsWith(QStringLiteral("/aurora")));
        QVERIFY(QDir(p).exists());   // wird angelegt
        QCOMPARE(io.standardPath(QStringLiteral("home")), QDir::homePath());
        QCOMPARE(io.standardPath(QStringLiteral("unbekannt")), QString());
    }

    void urlToPath_strippt_schema_und_dekodiert()
    {
        FileIO io;
        QCOMPARE(io.urlToPath("file:///tmp/a%20b.txt"), QString("/tmp/a b.txt"));
        QCOMPARE(io.urlToPath("file:///etc/hostname"), QString("/etc/hostname"));
        // Ohne Schema unverändert (schon ein Pfad):
        QCOMPARE(io.urlToPath("/tmp/plain.txt"), QString("/tmp/plain.txt"));
    }

    void readText_kappt_an_utf8_zeichengrenze()
    {
        // "äää" = 6 Bytes (je 2). maxBytes=5 würde das 3. Zeichen mitten
        // durchschneiden -> es muss weggelassen werden, kein Ersatzzeichen.
        QTemporaryDir dir;
        const QString p = dir.path() + "/umlaut.txt";
        QFile f(p);
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write(QString("äää").toUtf8());
        f.close();
        FileIO io;
        const QVariantMap r = io.readText(p, 5);
        QCOMPARE(r.value("ok").toBool(), true);
        QCOMPARE(r.value("text").toString(), QString("ää"));   // nicht "ää<U+FFFD>"
        QCOMPARE(r.value("truncated").toBool(), true);
    }

    void readText_leereDatei_okLeererText()
    {
        QTemporaryDir dir;
        const QString p = dir.path() + "/leer.txt";
        QFile f(p);
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.close();
        FileIO io;
        const QVariantMap r = io.readText(p);
        QCOMPARE(r.value("ok").toBool(), true);
        QCOMPARE(r.value("text").toString(), QString());
        QCOMPARE(r.value("truncated").toBool(), false);
    }

    void readText_maxBytesMinusEins_nutzt_default()
    {
        QTemporaryDir dir;
        const QString p = dir.path() + "/klein.txt";
        QFile f(p);
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write("abc");
        f.close();
        FileIO io;
        const QVariantMap r = io.readText(p, -1);   // <=0 -> Default-Limit
        QCOMPARE(r.value("ok").toBool(), true);
        QCOMPARE(r.value("text").toString(), QString("abc"));
    }

    void standardPath_cache_endetAufAurora_undExistiert()
    {
        FileIO io;
        const QString c = io.standardPath("cache");
        QVERIFY(c.endsWith(QStringLiteral("/aurora")));
        QVERIFY(QDir(c).exists());
    }

    void readText_fifo_wirdAbgelehnt_stattZuBlockieren()
    {
        QTemporaryDir dir;
        const QString fifo = dir.path() + "/pipe";
        QCOMPARE(::mkfifo(fifo.toLocal8Bit().constData(), 0600), 0);
        FileIO io;
        const QVariantMap r = io.readText(fifo);   // darf NICHT blockieren
        QCOMPARE(r.value("ok").toBool(), false);
        QVERIFY(r.value("error").toString().contains("regul"));
    }

    void readBase64_fifo_wirdAbgelehnt_stattZuBlockieren()
    {
        QTemporaryDir dir;
        const QString fifo = dir.path() + "/pipe";
        QCOMPARE(::mkfifo(fifo.toLocal8Bit().constData(), 0600), 0);
        FileIO io;
        const QVariantMap r = io.readBase64(fifo);   // darf NICHT blockieren
        QCOMPARE(r.value("ok").toBool(), false);
        QVERIFY(r.value("error").toString().contains("regul"));
    }

    void readText_verzeichnis_wirdAbgelehnt()
    {
        // Vor dem Guard lieferte QFile::open() auf einem Verzeichnis unter Linux
        // "Is a directory" (kein Hänger, aber ein anderer, weniger sprechender
        // Fehler) - mit Guard kommt einheitlich "Keine reguläre Datei".
        QTemporaryDir dir;
        FileIO io;
        const QVariantMap r = io.readText(dir.path());
        QCOMPARE(r.value("ok").toBool(), false);
        QVERIFY(r.value("error").toString().contains("regul"));
    }

    void readText_procDatei_funktioniert()
    {
        // Regressionsschutz: /proc-Dateien sind reguläre Dateien im Sinne von
        // QFileInfo::isFile() - der FIFO-Guard darf gatherSystemContext nicht brechen.
        FileIO io;
        const QVariantMap r = io.readText(QStringLiteral("/proc/self/status"), 4096);
        QCOMPARE(r.value("ok").toBool(), true);
        QVERIFY(r.value("text").toString().contains(QStringLiteral("Name:")));
    }

    void readText_kappt_3byte_und_4byte_sequenzen_sauber()
    {
        QTemporaryDir dir;
        // "€" = 3 Bytes (E2 82 AC), "😀" = 4 Bytes (F0 9F 98 80)
        const QString p3 = dir.path() + "/euro.txt";
        QFile f3(p3);
        QVERIFY(f3.open(QIODevice::WriteOnly));
        f3.write(QString("€€").toUtf8());   // 6 Bytes
        f3.close();
        FileIO io;
        const QVariantMap r3 = io.readText(p3, 4);   // schneidet 2. € nach 1 Byte an
        QCOMPARE(r3.value("text").toString(), QString("€"));
        QCOMPARE(r3.value("truncated").toBool(), true);

        const QString p4 = dir.path() + "/emoji.txt";
        QFile f4(p4);
        QVERIFY(f4.open(QIODevice::WriteOnly));
        f4.write(QString("😀😀").toUtf8());   // 8 Bytes
        f4.close();
        const QVariantMap r4 = io.readText(p4, 6);   // schneidet 2. Emoji nach 2 Bytes an
        QCOMPARE(r4.value("text").toString(), QString("😀"));
        QCOMPARE(r4.value("truncated").toBool(), true);
    }
};

QTEST_GUILESS_MAIN(TestFileIO)
#include "test_fileio.moc"
