#include <QQmlContext>
#include <QQmlEngine>
#include <QTcpServer>
#include <QTemporaryDir>
#include <QtQuickTest>

#include "testhttpserver.h"

// QML-Hülle um den TestHttpServer: tst_cloudboxclient_http.qml schickt den
// echten CloudBoxClient (mit echtem Http/NdjsonStream aus net.niuton.aurora.core)
// gegen einen lokalen HTTP-Server — kein Mock dazwischen.
class TestServerHandle : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString baseUrl READ baseUrl CONSTANT)
    Q_PROPERTY(QString tempDir READ tempDir CONSTANT)

public:
    explicit TestServerHandle(QObject *parent = nullptr)
        : QObject(parent)
    {
    }

    QString baseUrl() const { return m_server.baseUrl(); }
    QString tempDir() const { return m_tmp.path(); }

    Q_INVOKABLE void respond(int status, const QString &body,
                             const QString &contentType = QStringLiteral("application/json"))
    {
        m_server.setResponse(status, body.toUtf8(), contentType.toUtf8());
    }
    Q_INVOKABLE void respondHex(int status, const QString &hex, const QString &contentType)
    {
        m_server.setResponse(status, QByteArray::fromHex(hex.toLatin1()), contentType.toUtf8());
    }
    Q_INVOKABLE void respondChunked(int status, const QStringList &chunks, int delayMs)
    {
        QList<QByteArray> list;
        for (const QString &c : chunks)
            list.append(c.toUtf8());
        m_server.setChunkedResponse(status, list, delayMs);
    }
    Q_INVOKABLE void stall(int status) { m_server.setStallingResponse(status); }
    Q_INVOKABLE QString lastHead() const { return QString::fromUtf8(m_server.lastRequestHead); }
    Q_INVOKABLE QString lastBody() const { return QString::fromUtf8(m_server.lastRequestBody); }

    // Freier, gerade wieder geschlossener Port (Verbindung abgelehnt)
    Q_INVOKABLE QString closedUrl() const
    {
        QTcpServer tmp;
        tmp.listen(QHostAddress::LocalHost, 0);
        return QStringLiteral("http://127.0.0.1:%1").arg(tmp.serverPort());
    }

private:
    TestHttpServer m_server;
    QTemporaryDir m_tmp;
};

class Setup : public QObject
{
    Q_OBJECT

public Q_SLOTS:
    void qmlEngineAvailable(QQmlEngine *engine)
    {
        engine->rootContext()->setContextProperty(QStringLiteral("testServer"),
                                                  new TestServerHandle(engine));
    }
};

QUICK_TEST_MAIN_WITH_SETUP(tst_cloudboxclient_http, Setup)

#include "tst_cloudboxclient_http.moc"
