#include <QQmlEngine>
#include <QSignalSpy>
#include <QTcpServer>
#include <QtTest>

#include "ndjsonstream.h"
#include "testhttpserver.h"

static quint16 freierPort()
{
    QTcpServer tmp;
    tmp.listen(QHostAddress::LocalHost, 0);
    return tmp.serverPort();
}

class TestNdjsonStream : public QObject
{
    Q_OBJECT

private Q_SLOTS:
    void kompletteZeilen_liefernObjekte()
    {
        TestHttpServer server;
        server.setResponse(200,
            "{\"message\":{\"content\":\"Hallo\"}}\n{\"done\":true}\n");
        NdjsonStream stream;
        QSignalSpy objects(&stream, &NdjsonStream::objectReceived);
        QSignalSpy finished(&stream, &NdjsonStream::finished);
        stream.post(server.baseUrl() + "/api/chat", QVariantMap());
        QVERIFY(finished.wait(5000));
        QCOMPARE(objects.count(), 2);
        QCOMPARE(objects.at(0).at(0).toMap()
                     .value("message").toMap().value("content").toString(),
                 QString("Hallo"));
        QCOMPARE(finished.first().at(0).toBool(), true);
        QCOMPARE(finished.first().at(1).toInt(), 200);
    }

    // DER Kernfall: Zeile ueber Chunk-Grenze gesplittet -> heute Token-Verlust,
    // ab jetzt konstruktiv unmoeglich.
    void gesplitteteZeile_wirdZusammengesetzt()
    {
        TestHttpServer server;
        server.setChunkedResponse(200,
            { "{\"message\":{\"content\":\"Hal",
              "lo Welt\"}}\n{\"done\":true}\n" }, 50);
        NdjsonStream stream;
        QSignalSpy objects(&stream, &NdjsonStream::objectReceived);
        QSignalSpy finished(&stream, &NdjsonStream::finished);
        stream.post(server.baseUrl() + "/api/chat", QVariantMap());
        QVERIFY(finished.wait(5000));
        QCOMPARE(objects.count(), 2);
        QCOMPARE(objects.at(0).at(0).toMap()
                     .value("message").toMap().value("content").toString(),
                 QString("Hallo Welt"));
    }

    void letzteZeileOhneNewline_wirdBeimEndeGeflusht()
    {
        TestHttpServer server;
        server.setResponse(200, "{\"a\":1}\n{\"done\":true}");   // kein \n am Ende
        NdjsonStream stream;
        QSignalSpy objects(&stream, &NdjsonStream::objectReceived);
        QSignalSpy finished(&stream, &NdjsonStream::finished);
        stream.post(server.baseUrl() + "/x", QVariantMap());
        QVERIFY(finished.wait(5000));
        QCOMPARE(objects.count(), 2);
        QCOMPARE(objects.at(1).at(0).toMap().value("done").toBool(), true);
    }

    void leereUndDefekteZeilen_werdenUebersprungen()
    {
        TestHttpServer server;
        server.setResponse(200, "\n{kaputt\n{\"ok\":1}\n\n");
        NdjsonStream stream;
        QSignalSpy objects(&stream, &NdjsonStream::objectReceived);
        QSignalSpy finished(&stream, &NdjsonStream::finished);
        stream.post(server.baseUrl() + "/x", QVariantMap());
        QVERIFY(finished.wait(5000));
        QCOMPARE(objects.count(), 1);
        QCOMPARE(objects.first().at(0).toMap().value("ok").toInt(), 1);
    }

    void errorObjekt_kommtAlsObjectReceivedDurch()
    {
        TestHttpServer server;
        server.setResponse(200, "{\"error\":\"model not found\"}\n");
        NdjsonStream stream;
        QSignalSpy objects(&stream, &NdjsonStream::objectReceived);
        QSignalSpy finished(&stream, &NdjsonStream::finished);
        stream.post(server.baseUrl() + "/x", QVariantMap());
        QVERIFY(finished.wait(5000));
        QCOMPARE(objects.count(), 1);
        QCOMPARE(objects.first().at(0).toMap().value("error").toString(),
                 QString("model not found"));
    }

    void httpFehlerstatus_liefertBodyUndError()
    {
        TestHttpServer server;
        server.setResponse(404, "{\"error\":\"nope\"}\n");
        NdjsonStream stream;
        QSignalSpy objects(&stream, &NdjsonStream::objectReceived);
        QSignalSpy finished(&stream, &NdjsonStream::finished);
        stream.post(server.baseUrl() + "/x", QVariantMap());
        QVERIFY(finished.wait(5000));
        QCOMPARE(objects.count(), 1);   // Error-Body kommt als Objekt durch
        QCOMPARE(finished.first().at(0).toBool(), false);
        QCOMPARE(finished.first().at(1).toInt(), 404);
        QCOMPARE(finished.first().at(2).toString(), QString("HTTP 404"));
    }

    void idleTimeout_beendetMitTimeout()
    {
        TestHttpServer server;
        server.setStallingResponse(200);
        NdjsonStream stream;
        stream.setIdleTimeoutMs(200);
        QSignalSpy finished(&stream, &NdjsonStream::finished);
        stream.post(server.baseUrl() + "/haengt", QVariantMap());
        QVERIFY(finished.wait(5000));
        QCOMPARE(finished.first().at(0).toBool(), false);
        QCOMPARE(finished.first().at(2).toString(), QString("timeout"));
        QCOMPARE(stream.active(), false);
    }

    void abort_istStill()
    {
        TestHttpServer server;
        server.setChunkedResponse(200, { "{\"a\":1}\n", "{\"b\":2}\n" }, 2000);
        NdjsonStream stream;
        QSignalSpy objects(&stream, &NdjsonStream::objectReceived);
        QSignalSpy finished(&stream, &NdjsonStream::finished);
        stream.post(server.baseUrl() + "/x", QVariantMap());
        QVERIFY(objects.wait(5000));   // erstes Objekt ist da
        QCOMPARE(stream.active(), true);
        stream.abort();
        QCOMPARE(stream.active(), false);
        QTest::qWait(300);
        QCOMPARE(finished.count(), 0);   // still: kein finished
    }

    // Regressionstest (Review-Fund): abort() aus einem objectReceived-Handler
    // waehrend des End-Flushs in onFinished() muss still bleiben — kein
    // finished-Signal, kein zweites cleanup(). Die done-Zeile kommt bewusst
    // OHNE Newline: nur so wird sie erst im Flush von onFinished() emittiert
    // (mit Newline draint sie schon in onReadyRead, wo der Abort-disconnect
    // onFinished ohnehin verhindert — der Bugpfad wuerde nie betreten).
    void abortAusHandlerWaehrendFlush_bleibtStill()
    {
        TestHttpServer server;
        server.setResponse(200, "{\"a\":1}\n{\"done\":true}");
        NdjsonStream stream;
        QSignalSpy objects(&stream, &NdjsonStream::objectReceived);
        QSignalSpy finished(&stream, &NdjsonStream::finished);
        connect(&stream, &NdjsonStream::objectReceived, &stream,
                [&stream](const QVariantMap &obj) {
                    if (obj.value("done").toBool())
                        stream.abort();
                });
        stream.post(server.baseUrl() + "/api/chat", QVariantMap());
        QTest::qWait(500);
        QCOMPARE(objects.count(), 2);
        QCOMPARE(stream.active(), false);
        QCOMPARE(finished.count(), 0);   // still: kein finished trotz Flush-Abort
    }

    // Regressionstest (Branch-Review-Fund): post() aus einem objectReceived-Handler
    // waehrend des End-Flushs (Restart-Muster) muss den ALTEN Request still
    // verwerfen und den NEUEN unversehrt lassen. Konstruktion: done-Zeile ohne
    // End-Newline erzwingt den Flush-Pfad in onFinished(); der Handler stellt
    // vor dem Re-Post eine UNTERSCHEIDBARE Server-Antwort ("zweite") ein, damit
    // eindeutig belegbar ist, dass das einzige finished zum zweiten Request
    // gehoert (drittes Objekt "zweite" wurde davor empfangen). Vor dem Fix:
    // finished feuerte fuer den alten Request, cleanup() nullte das NEUE
    // m_reply, und der verwaiste neue Reply dereferenzierte in onReadyRead
    // einen nullptr (Crash).
    void postAusHandlerWaehrendFlush_verwirftAltenStreamStill()
    {
        TestHttpServer server;
        server.setResponse(200, "{\"a\":1}\n{\"done\":true}");   // kein \n: Flush-Pfad
        NdjsonStream stream;
        QSignalSpy objects(&stream, &NdjsonStream::objectReceived);
        QSignalSpy finished(&stream, &NdjsonStream::finished);
        bool reposted = false;
        connect(&stream, &NdjsonStream::objectReceived, &stream,
                [&](const QVariantMap &obj) {
                    if (obj.value("done").toBool() && !reposted) {
                        reposted = true;
                        server.setResponse(200, "{\"zweite\":true}\n");
                        stream.post(server.baseUrl() + "/zweiter", QVariantMap());
                    }
                });
        stream.post(server.baseUrl() + "/api/chat", QVariantMap());
        QVERIFY(finished.wait(5000));   // finished des ZWEITEN Requests
        QTest::qWait(300);              // Nachlauf: kein weiteres finished
        QCOMPARE(finished.count(), 1);  // altes finished waere ein Kontraktbruch
        QCOMPARE(objects.count(), 3);
        QCOMPARE(objects.at(2).at(0).toMap().value("zweite").toBool(), true);
        QCOMPARE(finished.first().at(0).toBool(), true);
        QCOMPARE(finished.first().at(1).toInt(), 200);
        QCOMPARE(stream.active(), false);
    }

    // Haertungswelle Fund 3: eine newline-lose Riesenzeile wuerde den Puffer
    // bis zum Idle-Timeout (90 s) unbegrenzt wachsen lassen. maxLineBytes
    // bricht den Stream sofort mit Fehler ab; die angefangene Zeile wird
    // verworfen (der Body hier ist GUELTIGES JSON — ein Flush in onFinished
    // wuerde ihn sonst als Objekt emittieren).
    void zeilenLimit_ueberschritten_brichtMitFehlerAb_undVerwirftZeile()
    {
        TestHttpServer server;
        server.setResponse(200, "{\"x\":\"" + QByteArray(500, 'a') + "\"}");   // > Limit, kein \n
        NdjsonStream stream;
        QCOMPARE(stream.maxLineBytes(), 1048576);   // Default: 1 MiB
        stream.setMaxLineBytes(64);
        QSignalSpy objects(&stream, &NdjsonStream::objectReceived);
        QSignalSpy finished(&stream, &NdjsonStream::finished);
        stream.post(server.baseUrl() + "/x", QVariantMap());
        QVERIFY(finished.wait(5000));
        QCOMPARE(finished.count(), 1);
        QCOMPARE(finished.first().at(0).toBool(), false);
        QCOMPARE(finished.first().at(2).toString(), QString("line too long"));
        QCOMPARE(objects.count(), 0);   // Zeile verworfen, kein Flush
        QCOMPARE(stream.active(), false);
    }

    // Fund 3, Gegenprobe: Zeilen UNTER dem Limit laufen auch bei kleinem
    // Limit normal durch; erst die newline-lose Restzeile loest aus.
    void zeilenLimit_kurzeZeilenLaufenNormal()
    {
        TestHttpServer server;
        server.setResponse(200, "{\"a\":1}\n{\"done\":true}\n");
        NdjsonStream stream;
        stream.setMaxLineBytes(64);
        QSignalSpy objects(&stream, &NdjsonStream::objectReceived);
        QSignalSpy finished(&stream, &NdjsonStream::finished);
        stream.post(server.baseUrl() + "/x", QVariantMap());
        QVERIFY(finished.wait(5000));
        QCOMPARE(objects.count(), 2);
        QCOMPARE(finished.first().at(0).toBool(), true);
    }

    void verbindungAbgelehnt_liefertFehler()
    {
        NdjsonStream stream;
        QSignalSpy finished(&stream, &NdjsonStream::finished);
        stream.post(QString("http://127.0.0.1:%1/x").arg(freierPort()), QVariantMap());
        QVERIFY(finished.wait(5000));
        QCOMPARE(finished.first().at(0).toBool(), false);
        QCOMPARE(finished.first().at(1).toInt(), 0);
        QVERIFY(!finished.first().at(2).toString().isEmpty());
        QCOMPARE(stream.active(), false);
    }

    // Regressionstest: Ruft QML tatsaechlich mit einem JS-Objektliteral auf
    // (nicht mit einer aus C++ gebauten QVariantMap), landet der Q_INVOKABLE-
    // Parameter als QVariant(QJSValue) — nicht als "flacher" QVariantMap.
    // QJsonDocument::fromVariant() kennt QJSValue nicht und serialisiert
    // stillschweigend zu {} (leerer Body). normalizeBody() muss das abfangen.
    void post_qmlJsObjektAlsBody_wirdKorrektSerialisiert()
    {
        TestHttpServer server;
        server.setResponse(200, "{\"done\":true}\n");
        QQmlEngine engine;
        NdjsonStream stream;
        QSignalSpy finished(&stream, &NdjsonStream::finished);
        const QJSValue jsBody = engine.evaluate("({model: 'qwen3.5:0.8b', stream: true})");
        QVERIFY(!jsBody.isError());
        stream.post(server.baseUrl() + "/api/chat", QVariant::fromValue(jsBody));
        QVERIFY(finished.wait(5000));
        QVERIFY(server.lastRequestHead.startsWith("POST /api/chat"));
        QVERIFY(server.lastRequestBody.contains("\"model\":\"qwen3.5:0.8b\""));
    }

    void postSendetJsonBodyMitContentType()
    {
        TestHttpServer server;
        server.setResponse(200, "{\"done\":true}\n");
        NdjsonStream stream;
        QSignalSpy finished(&stream, &NdjsonStream::finished);
        QVariantMap body;
        body.insert("model", "qwen3.5:0.8b");
        body.insert("stream", true);
        stream.post(server.baseUrl() + "/api/chat", body);
        QVERIFY(finished.wait(5000));
        QVERIFY(server.lastRequestHead.startsWith("POST /api/chat"));
        QVERIFY(server.lastRequestHead.toLower().contains("content-type: application/json"));
        QVERIFY(server.lastRequestBody.contains("\"model\":\"qwen3.5:0.8b\""));
    }
};

QTEST_GUILESS_MAIN(TestNdjsonStream)
#include "test_ndjsonstream.moc"
