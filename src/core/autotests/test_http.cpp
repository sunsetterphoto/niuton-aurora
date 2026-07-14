#include <QCoreApplication>
#include <QElapsedTimer>
#include <QFile>
#include <QJsonDocument>
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

    void callbackNull_stuerztNichtAb()
    {
        TestHttpServer server;
        server.setResponse(200, "{}");
        HttpFixture f;
        f.http->getJson(server.baseUrl() + "/x", QJSValue());
        QTest::qWait(300);   // Reply abarbeiten lassen — kein Crash = bestanden
        QVERIFY(true);
    }
};

QTEST_GUILESS_MAIN(TestHttp)
#include "test_http.moc"
