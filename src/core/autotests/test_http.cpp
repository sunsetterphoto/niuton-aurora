#include <QCoreApplication>
#include <QElapsedTimer>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>
#include <QQmlEngine>
#include <QTemporaryDir>
#include <QtTest>

#include "http.h"
#include "testhttpserver.h"

// Ein frisches Engine/Http-Paar pro Testfall. qjsEngine(http) funktioniert,
// weil newQObject() das Objekt mit der Engine assoziiert; CppOwnership
// verhindert, dass der GC das Http-Objekt einsammelt.
struct HttpFixture {
    QQmlEngine engine;
    Http *http = nullptr;
    QJSValue wrapper;   // haelt die JS-Seite am Leben

    HttpFixture()
    {
        http = new Http;
        QQmlEngine::setObjectOwnership(http, QQmlEngine::CppOwnership);
        wrapper = engine.newQObject(http);
        engine.evaluate("result = undefined; done = false;");
    }
    ~HttpFixture() { delete http; }

    QJSValue callback()
    {
        return engine.evaluate("(function(r) { result = r; done = true; })");
    }
    QVariantMap wait(int timeoutMs = 5000)
    {
        // QTRY_* geht nur in Testfunktionen; hier von Hand pollen
        QElapsedTimer t;
        t.start();
        while (!engine.globalObject().property("done").toBool()) {
            if (t.elapsed() > timeoutMs)
                return {};
            QCoreApplication::processEvents(QEventLoop::AllEvents, 25);
        }
        return engine.globalObject().property("result").toVariant().toMap();
    }
};

// Freien (gerade wieder geschlossenen) Port fuer Connection-Refused-Tests
static quint16 freierPort()
{
    QTcpServer tmp;
    tmp.listen(QHostAddress::LocalHost, 0);
    return tmp.serverPort();
}

class TestHttp : public QObject
{
    Q_OBJECT

private Q_SLOTS:
    void getJson_ok_liefertGeparsteDaten()
    {
        TestHttpServer server;
        server.setResponse(200, R"({"models":[{"name":"gemma4:e2b"}]})");
        HttpFixture f;
        f.http->getJson(server.baseUrl() + "/api/tags", f.callback());
        const QVariantMap r = f.wait();
        QCOMPARE(r.value("ok").toBool(), true);
        QCOMPARE(r.value("status").toInt(), 200);
        const QVariantList models = r.value("data").toMap().value("models").toList();
        QCOMPARE(models.first().toMap().value("name").toString(), QString("gemma4:e2b"));
    }

    void getJson_http404_liefertFehlerUndBody()
    {
        TestHttpServer server;
        server.setResponse(404, R"({"error":"model not found"})");
        HttpFixture f;
        f.http->getJson(server.baseUrl() + "/x", f.callback());
        const QVariantMap r = f.wait();
        QCOMPARE(r.value("ok").toBool(), false);
        QCOMPARE(r.value("status").toInt(), 404);
        QCOMPARE(r.value("error").toString(), QString("HTTP 404"));
        QCOMPARE(r.value("data").toMap().value("error").toString(), QString("model not found"));
    }

    void getJson_ungueltigesJson_liefertFehler()
    {
        TestHttpServer server;
        server.setResponse(200, "das ist kein json", "text/plain");
        HttpFixture f;
        f.http->getJson(server.baseUrl() + "/x", f.callback());
        const QVariantMap r = f.wait();
        QCOMPARE(r.value("ok").toBool(), false);
        QVERIFY(r.value("error").toString().contains("JSON"));
    }

    // Regressionstest fuer http.cpp:101 — ein leerer 2xx-Body (z.B. 204 No
    // Content) ist legitim und darf NICHT als "Ungueltiges JSON" gemeldet werden.
    void getJson_leererBody2xx_liefertErfolg()
    {
        TestHttpServer server;
        server.setResponse(200, "");
        HttpFixture f;
        f.http->getJson(server.baseUrl() + "/x", f.callback());
        const QVariantMap r = f.wait();
        QCOMPARE(r.value("ok").toBool(), true);
        QCOMPARE(r.value("status").toInt(), 200);
        QVERIFY(r.value("data").toMap().isEmpty());
        QVERIFY(r.value("error").toString().isEmpty());
    }

    // Whitespace-only Body zaehlt ebenso als leer (kuenstliche Server manchmal
    // ein einzelnes "\n" statt eines wirklich leeren Bodys).
    void getJson_whitespaceBody2xx_liefertErfolg()
    {
        TestHttpServer server;
        server.setResponse(200, "   \n\t  ");
        HttpFixture f;
        f.http->getJson(server.baseUrl() + "/x", f.callback());
        const QVariantMap r = f.wait();
        QCOMPARE(r.value("ok").toBool(), true);
        QVERIFY(r.value("data").toMap().isEmpty());
    }

    // 204-Antworten (z.B. Ollama /api/delete) muessen ebenso als Erfolg
    // durchgehen, ueber postJson genauso wie ueber getJson.
    void postJson_leererBody204_liefertErfolg()
    {
        TestHttpServer server;
        server.setResponse(204, "");
        HttpFixture f;
        f.http->postJson(server.baseUrl() + "/x", QVariantMap(), f.callback());
        const QVariantMap r = f.wait();
        QCOMPARE(r.value("ok").toBool(), true);
        QCOMPARE(r.value("status").toInt(), 204);
    }

    // Regressionsschutz: ein nicht-leerer, aber wirklich kaputter Body auf 2xx
    // muss weiterhin als Fehler gemeldet werden (nicht durch den Empty-Body-Fix
    // verschluckt werden).
    void getJson_nichtLeererMuellBody2xx_liefertWeiterhinFehler()
    {
        TestHttpServer server;
        server.setResponse(200, "{ kaputt", "text/plain");
        HttpFixture f;
        f.http->getJson(server.baseUrl() + "/x", f.callback());
        const QVariantMap r = f.wait();
        QCOMPARE(r.value("ok").toBool(), false);
        QVERIFY(r.value("error").toString().contains("Ungültiges JSON"));
    }

    void postJson_serialisiertBodyUndContentType()
    {
        TestHttpServer server;
        server.setResponse(200, R"({"capabilities":["tools"]})");
        HttpFixture f;
        QVariantMap body;
        body.insert("model", "qwen3.5:9b");
        f.http->postJson(server.baseUrl() + "/api/show", body, f.callback());
        const QVariantMap r = f.wait();
        QCOMPARE(r.value("ok").toBool(), true);
        QVERIFY(server.lastRequestHead.startsWith("POST /api/show"));
        QVERIFY(server.lastRequestHead.toLower().contains("content-type: application/json"));
        QCOMPARE(QJsonDocument::fromJson(server.lastRequestBody),
                 QJsonDocument::fromVariant(body));
        QCOMPARE(r.value("data").toMap().value("capabilities").toList().first().toString(),
                 QString("tools"));
    }

    // Regressionstest: Ruft QML tatsaechlich mit einem JS-Objektliteral auf
    // (nicht mit einer aus C++ gebauten QVariantMap), landet der Q_INVOKABLE-
    // Parameter als QVariant(QJSValue) — nicht als "flacher" QVariantMap.
    // QJsonDocument::fromVariant() kennt QJSValue nicht und serialisiert
    // stillschweigend zu {} (leerer Body). normalizeBody() muss das abfangen.
    void postJson_qmlJsObjektAlsBody_wirdKorrektSerialisiert()
    {
        TestHttpServer server;
        server.setResponse(200, R"({"ok":true})");
        HttpFixture f;
        const QJSValue jsBody = f.engine.evaluate("({model: 'qwen3.5:9b', messages: []})");
        QVERIFY(!jsBody.isError());
        f.http->postJson(server.baseUrl() + "/api/chat", QVariant::fromValue(jsBody), f.callback());
        const QVariantMap r = f.wait();
        QCOMPARE(r.value("ok").toBool(), true);
        QJsonParseError err;
        const QJsonDocument sentDoc = QJsonDocument::fromJson(server.lastRequestBody, &err);
        QCOMPARE(err.error, QJsonParseError::NoError);
        QCOMPARE(sentDoc.object().value("model").toString(), QString("qwen3.5:9b"));
    }

    void timeout_liefertTimeoutFehler()
    {
        TestHttpServer server;
        server.setStallingResponse(200);
        HttpFixture f;
        f.http->getJson(server.baseUrl() + "/haengt", f.callback(), 300);
        const QVariantMap r = f.wait();
        QCOMPARE(r.value("ok").toBool(), false);
        QCOMPARE(r.value("error").toString(), QString("timeout"));
    }

    void verbindungAbgelehnt_liefertFehlerMitStatus0()
    {
        HttpFixture f;
        f.http->getJson(QString("http://127.0.0.1:%1/x").arg(freierPort()), f.callback());
        const QVariantMap r = f.wait();
        QCOMPARE(r.value("ok").toBool(), false);
        QCOMPARE(r.value("status").toInt(), 0);
        QVERIFY(!r.value("error").toString().isEmpty());
    }

    void downloadToFile_schreibtDateiUndLegtOrdnerAn()
    {
        TestHttpServer server;
        server.setResponse(200, "PNGDATEN", "image/png");
        QTemporaryDir dir;
        const QString dest = dir.path() + "/unter/ordner/bild.png";
        HttpFixture f;
        f.http->downloadToFile(server.baseUrl() + "/view", dest, f.callback());
        const QVariantMap r = f.wait();
        QCOMPARE(r.value("ok").toBool(), true);
        QCOMPARE(r.value("path").toString(), dest);
        QFile file(dest);
        QVERIFY(file.open(QIODevice::ReadOnly));
        QCOMPARE(file.readAll(), QByteArray("PNGDATEN"));
    }

    void downloadToFile_http404_legtKeineDateiAn()
    {
        TestHttpServer server;
        server.setResponse(404, "not found", "text/plain");
        QTemporaryDir dir;
        const QString dest = dir.path() + "/bild.png";
        HttpFixture f;
        f.http->downloadToFile(server.baseUrl() + "/view", dest, f.callback());
        const QVariantMap r = f.wait();
        QCOMPARE(r.value("ok").toBool(), false);
        QCOMPARE(r.value("status").toInt(), 404);
        // Konsistent zu getJson/postJson: non-2xx meldet "HTTP <n>", nicht Qts
        // generischen Transfer-String (ContentNotFoundError setzt reply->error()).
        QCOMPARE(r.value("error").toString(), QString("HTTP 404"));
        QVERIFY(!QFile::exists(dest));
    }

    void downloadToFile_abbruchImBody_meldetNetzwerkfehler()
    {
        // Server verspricht Content-Length, schließt aber vorzeitig -> Transportfehler bei Status 200
        TestHttpServer server;
        server.setTruncatedBody(200, "erwartet-viel", 5);   // siehe Hinweis unten
        QTemporaryDir dir;
        const QString dest = dir.path() + "/x.bin";
        HttpFixture f;
        f.http->downloadToFile(server.baseUrl() + "/view", dest, f.callback());
        const QVariantMap r = f.wait();
        QCOMPARE(r.value("ok").toBool(), false);
        QVERIFY(r.value("error").toString() != QStringLiteral("HTTP 200"));
        QVERIFY(!QFile::exists(dest));
    }

    void cancelDownload_brichtLaufendenDownloadAb()
    {
        // Verzögerte Chunk-Antwort: der Download läuft noch, wenn cancelDownload
        // greift -> Callback mit ok:false, keine Datei (QSaveFile wird nie
        // erreicht), zweiter cancelDownload-Aufruf ist no-op.
        TestHttpServer server;
        server.setChunkedResponse(200, {"eins", "zwei", "drei"}, 300);
        QTemporaryDir dir;
        const QString dest = dir.path() + "/x.bin";
        HttpFixture f;
        const QString url = server.baseUrl() + "/view";
        f.http->downloadToFile(url, dest, f.callback());
        f.http->cancelDownload(url);
        const QVariantMap r = f.wait();
        QCOMPARE(r.value("ok").toBool(), false);
        QVERIFY(!QFile::exists(dest));
        f.http->cancelDownload(url);   // no-op ohne laufenden Download
        f.http->cancelDownload(QStringLiteral("http://ander.invalid/x"));   // fremde URL: no-op
    }

    // Ollama /api/delete: DELETE mit JSON-Body {"name": "..."}.
    void deleteJson_sendetMethodeBodyUndContentType()
    {
        TestHttpServer server;
        server.setResponse(200, "");
        HttpFixture f;
        QVariantMap body;
        body.insert("name", "qwen3.6:27b");
        f.http->deleteJson(server.baseUrl() + "/api/delete", body, f.callback());
        const QVariantMap r = f.wait();
        QCOMPARE(r.value("ok").toBool(), true);
        QCOMPARE(r.value("status").toInt(), 200);
        QVERIFY(server.lastRequestHead.startsWith("DELETE /api/delete"));
        QVERIFY(server.lastRequestHead.toLower().contains("content-type: application/json"));
        QCOMPARE(QJsonDocument::fromJson(server.lastRequestBody),
                 QJsonDocument::fromVariant(body));
    }

    // Nicht vorhandenes Modell -> 404 mit Ollama-Error-Body (wie postJson-404).
    void deleteJson_http404_liefertFehlerUndBody()
    {
        TestHttpServer server;
        server.setResponse(404, R"({"error":"model 'qwen3.6:27b' not found"})");
        HttpFixture f;
        f.http->deleteJson(server.baseUrl() + "/api/delete", QVariantMap(), f.callback());
        const QVariantMap r = f.wait();
        QCOMPARE(r.value("ok").toBool(), false);
        QCOMPARE(r.value("status").toInt(), 404);
        QCOMPARE(r.value("error").toString(), QString("HTTP 404"));
        QVERIFY(r.value("data").toMap().value("error").toString().contains("not found"));
    }

    void callbackNull_stuerztNichtAb()
    {
        TestHttpServer server;
        server.setResponse(200, "{}");
        HttpFixture f;
        f.http->getJson(server.baseUrl() + "/x", QJSValue());
        QTest::qWait(300);   // Reply abarbeiten lassen — kein Crash = bestanden
        QVERIFY(true);
    }

    // Cloud-Backends brauchen einen Auth-Header (OpenRouter:
    // "Authorization: Bearer <key>"). Ohne den kommt man dort nicht einmal an
    // die Modell-Liste.
    void getJson_sendetZusaetzlicheHeader()
    {
        TestHttpServer server;
        server.setResponse(200, "{\"data\":[]}");
        HttpFixture f;
        QVariantMap headers;
        headers[QStringLiteral("Authorization")] = QStringLiteral("Bearer geheim-123");
        headers[QStringLiteral("HTTP-Referer")] = QStringLiteral("https://niuton.net");
        f.http->getJson(server.baseUrl() + QStringLiteral("/v1/models"),
                        f.callback(), 0, headers);
        const QVariantMap r = f.wait();
        QCOMPARE(r.value(QStringLiteral("ok")).toBool(), true);
        // Qt schreibt Header-Namen kanonisch ("HTTP-Referer" -> "Http-Referer").
        // Feldnamen sind laut RFC 9110 case-insensitiv, der Empfänger liest sie
        // also korrekt — der Test vergleicht deshalb ebenfalls case-insensitiv.
        const QByteArray head = server.lastRequestHead.toLower();
        QVERIFY(head.contains("authorization: bearer geheim-123"));
        QVERIFY(head.contains("http-referer: https://niuton.net"));
    }

    void postJson_sendetZusaetzlicheHeader()
    {
        TestHttpServer server;
        server.setResponse(200, "{\"ok\":1}");
        HttpFixture f;
        QVariantMap headers;
        headers[QStringLiteral("Authorization")] = QStringLiteral("Bearer geheim-456");
        f.http->postJson(server.baseUrl() + QStringLiteral("/v1/embeddings"),
                         QVariantMap{{QStringLiteral("input"), QStringLiteral("hi")}},
                         f.callback(), 0, headers);
        f.wait();
        QVERIFY(server.lastRequestHead.contains("Authorization: Bearer geheim-456"));
        // Content-Type darf dabei nicht verloren gehen
        QVERIFY(server.lastRequestHead.contains("Content-Type: application/json"));
    }

    // Ohne Header-Argument bleibt alles wie bisher.
    void ohneHeader_unveraendert()
    {
        TestHttpServer server;
        server.setResponse(200, "{\"ok\":1}");
        HttpFixture f;
        f.http->getJson(server.baseUrl() + QStringLiteral("/x"), f.callback());
        QCOMPARE(f.wait().value(QStringLiteral("ok")).toBool(), true);
        QVERIFY(!server.lastRequestHead.contains("Authorization"));
    }
    // ---------- request(): generischer Aufruf (Cloud-Rechner-App-API) ----------

    // PUT mit rohem Body: Datei-Upload braucht Content-Length (Server: 411 ohne)
    // und eigenen Content-Type; Header-Namen vergleicht der Test case-insensitiv
    // (Qt 6.8 schreibt sie klein, Qt 6.11 kanonisch).
    void request_put_sendetRohenBodyMitLaengeUndHeadern()
    {
        TestHttpServer server;
        server.setResponse(204, "");
        HttpFixture f;
        QVariantMap headers;
        headers["Authorization"] = "Bearer nk_test";
        f.http->request(QVariantMap{{"method", "PUT"},
                                    {"url", QString(server.baseUrl() + "/api/v1/box/file?path=a.txt")},
                                    {"body", QString::fromUtf8("hallo wält")},
                                    {"contentType", "application/octet-stream"},
                                    {"headers", headers}},
                        f.callback());
        const QVariantMap r = f.wait();
        QCOMPARE(r.value("ok").toBool(), true);
        QCOMPARE(r.value("status").toInt(), 204);
        const QByteArray head = server.lastRequestHead.toLower();
        QVERIFY(head.startsWith("put /api/v1/box/file?path=a.txt "));
        QVERIFY(head.contains("authorization: bearer nk_test"));
        QVERIFY(head.contains("content-type: application/octet-stream"));
        QVERIFY(head.contains("content-length: 11"));
        QCOMPARE(server.lastRequestBody, QString::fromUtf8("hallo wält").toUtf8());
    }

    void request_get_liefertTextGroesseUndKeinBinaer()
    {
        TestHttpServer server;
        server.setResponse(200, "zeile1\nzeile2", "application/octet-stream");
        HttpFixture f;
        f.http->request(QVariantMap{{"url", QString(server.baseUrl() + "/f")}}, f.callback());
        const QVariantMap r = f.wait();
        QCOMPARE(r.value("ok").toBool(), true);
        QCOMPARE(r.value("text").toString(), QString("zeile1\nzeile2"));
        QCOMPARE(r.value("size").toInt(), 13);
        QCOMPARE(r.value("binary").toBool(), false);
        QVERIFY(server.lastRequestHead.startsWith("GET /f "));
    }

    void request_get_binaerWirdErkannt()
    {
        TestHttpServer server;
        server.setResponse(200, QByteArray("ab\0cd", 5), "application/octet-stream");
        HttpFixture f;
        f.http->request(QVariantMap{{"url", QString(server.baseUrl() + "/f")}}, f.callback());
        const QVariantMap r = f.wait();
        QCOMPARE(r.value("ok").toBool(), true);
        QCOMPARE(r.value("binary").toBool(), true);
        QCOMPARE(r.value("size").toInt(), 5);
        QVERIFY(r.value("text").toString().isEmpty());
    }

    void request_jsonAntwort_wirdGeparst()
    {
        TestHttpServer server;
        server.setResponse(200, R"({"path":"","entries":[{"name":"a","type":"dir"}]})");
        HttpFixture f;
        f.http->request(QVariantMap{{"url", QString(server.baseUrl() + "/files")}}, f.callback());
        const QVariantMap r = f.wait();
        QCOMPARE(r.value("ok").toBool(), true);
        QCOMPARE(r.value("data").toMap().value("entries").toList().first().toMap()
                     .value("name").toString(), QString("a"));
    }

    // Zu große Antworten werden abgebrochen statt komplett gepuffert.
    void request_maxBytes_ueberschritten_liefertTooLarge()
    {
        TestHttpServer server;
        server.setResponse(200, QByteArray(5000, 'x'), "application/octet-stream");
        HttpFixture f;
        f.http->request(QVariantMap{{"url", QString(server.baseUrl() + "/f")}, {"maxBytes", 100}},
                        f.callback());
        const QVariantMap r = f.wait();
        QCOMPARE(r.value("ok").toBool(), false);
        QCOMPARE(r.value("error").toString(), QString("too_large"));
    }

    // Fehlerform der App-API ({"error":{code,message,retryAfterS}}) kommt als data durch.
    void request_fehlerstatus_liefertJsonFehlerkoerper()
    {
        TestHttpServer server;
        server.setResponse(429, R"({"error":{"code":"too_many_requests","message":"langsam","retryAfterS":7}})");
        HttpFixture f;
        f.http->request(QVariantMap{{"method", "POST"}, {"url", QString(server.baseUrl() + "/x")},
                                    {"body", QVariantMap{{"a", 1}}}},
                        f.callback());
        const QVariantMap r = f.wait();
        QCOMPARE(r.value("ok").toBool(), false);
        QCOMPARE(r.value("status").toInt(), 429);
        QCOMPARE(r.value("error").toString(), QString("HTTP 429"));
        const QVariantMap err = r.value("data").toMap().value("error").toMap();
        QCOMPARE(err.value("code").toString(), QString("too_many_requests"));
        QCOMPARE(err.value("retryAfterS").toInt(), 7);
    }

    // POST mit JSON-Objekt + saveTo: Body wird JSON, Antwort (PNG) landet atomar in
    // der Datei; head liefert die ersten Bytes als Hex (Signaturprüfung im Aufrufer).
    void request_saveTo_schreibtDateiUndHead()
    {
        QTemporaryDir dir;
        const QString dest = dir.path() + "/sub/shot.png";
        const QByteArray png = QByteArray::fromHex("89504e470d0a1a0a0000000d49484452");
        TestHttpServer server;
        server.setResponse(200, png, "image/png");
        HttpFixture f;
        f.http->request(QVariantMap{{"method", "POST"}, {"url", QString(server.baseUrl() + "/shot")},
                                    {"body", QVariantMap{{"url", "http://localhost:5173/"}}},
                                    {"saveTo", dest}},
                        f.callback());
        const QVariantMap r = f.wait();
        QCOMPARE(r.value("ok").toBool(), true);
        QCOMPARE(r.value("path").toString(), dest);
        QCOMPARE(r.value("contentType").toString(), QString("image/png"));
        QVERIFY(r.value("head").toString().startsWith("89504e47"));
        QFile file(dest);
        QVERIFY(file.open(QIODevice::ReadOnly));
        QCOMPARE(file.readAll(), png);
        QVERIFY(server.lastRequestHead.toLower().contains("content-type: application/json"));
        QCOMPARE(QJsonDocument::fromJson(server.lastRequestBody).object().value("url").toString(),
                 QString("http://localhost:5173/"));
    }

    void request_saveTo_beiFehlerKeineDatei()
    {
        QTemporaryDir dir;
        const QString dest = dir.path() + "/shot.png";
        TestHttpServer server;
        server.setResponse(502, R"({"error":{"code":"screenshot_failed","message":"x"}})");
        HttpFixture f;
        f.http->request(QVariantMap{{"method", "POST"}, {"url", QString(server.baseUrl() + "/shot")},
                                    {"saveTo", dest}},
                        f.callback());
        const QVariantMap r = f.wait();
        QCOMPARE(r.value("ok").toBool(), false);
        QCOMPARE(r.value("status").toInt(), 502);
        QCOMPARE(r.value("data").toMap().value("error").toMap().value("code").toString(),
                 QString("screenshot_failed"));
        QVERIFY(!QFile::exists(dest));
    }

    void request_delete_sendetMethode()
    {
        TestHttpServer server;
        server.setResponse(204, "");
        HttpFixture f;
        f.http->request(QVariantMap{{"method", "DELETE"}, {"url", QString(server.baseUrl() + "/p")}},
                        f.callback());
        QCOMPARE(f.wait().value("ok").toBool(), true);
        QVERIFY(server.lastRequestHead.startsWith("DELETE /p "));
    }

    void request_timeout_liefertTimeout()
    {
        TestHttpServer server;
        server.setStallingResponse(200);
        HttpFixture f;
        f.http->request(QVariantMap{{"url", QString(server.baseUrl() + "/x")}, {"timeoutMs", 200}},
                        f.callback());
        const QVariantMap r = f.wait();
        QCOMPARE(r.value("ok").toBool(), false);
        QCOMPARE(r.value("error").toString(), QString("timeout"));
    }

    void request_verbindungAbgelehnt_status0()
    {
        HttpFixture f;
        f.http->request(QVariantMap{{"url", QString("http://127.0.0.1:%1/x").arg(freierPort())}},
                        f.callback());
        const QVariantMap r = f.wait();
        QCOMPARE(r.value("ok").toBool(), false);
        QCOMPARE(r.value("status").toInt(), 0);
        QVERIFY(!r.value("error").toString().isEmpty());
    }
};

QTEST_GUILESS_MAIN(TestHttp)
#include "test_http.moc"
