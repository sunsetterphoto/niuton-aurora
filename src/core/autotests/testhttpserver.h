#pragma once

#include <QList>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTimer>

#include <utility>

// Minimaler HTTP/1.1-Testserver: beantwortet Verbindungen sequenziell mit einer
// vorab konfigurierten Antwort. Chunks koennen zeitversetzt gesendet werden, um
// Chunk-Grenzen mitten in NDJSON-Zeilen zu erzwingen. Nur fuer Tests gedacht
// (eine Verbindung zur Zeit; Testbinaries laufen mit -UQT_NO_CAST_FROM_ASCII).
class TestHttpServer : public QObject
{
public:
    explicit TestHttpServer(QObject *parent = nullptr)
        : QObject(parent)
    {
        connect(&m_server, &QTcpServer::newConnection, this, [this]() {
            QTcpSocket *sock = m_server.nextPendingConnection();
            connect(sock, &QTcpSocket::readyRead, this, [this, sock]() { onData(sock); });
            connect(sock, &QTcpSocket::disconnected, sock, &QObject::deleteLater);
        });
        m_server.listen(QHostAddress::LocalHost, 0);
    }

    quint16 port() const { return m_server.serverPort(); }
    QString baseUrl() const { return QString("http://127.0.0.1:%1").arg(port()); }

    // Antwort in einem Stueck (mit Content-Length)
    void setResponse(int status, const QByteArray &body,
                     const QByteArray &contentType = "application/json")
    {
        m_status = status;
        m_chunks = {body};
        m_chunkDelayMs = 0;
        m_contentType = contentType;
        m_sendBody = true;
        m_truncateAfter = -1;
    }

    // Body in mehreren Stuecken mit Pause dazwischen (ohne Content-Length,
    // Connection: close -> Client liest bis zum Socketschluss)
    void setChunkedResponse(int status, const QList<QByteArray> &chunks, int delayMs)
    {
        m_status = status;
        m_chunks = chunks;
        m_chunkDelayMs = delayMs;
        m_contentType = "application/json";
        m_sendBody = true;
        m_truncateAfter = -1;
    }

    // Header senden, dann nichts mehr (fuer Timeout-Tests)
    void setStallingResponse(int status)
    {
        m_status = status;
        m_chunks.clear();
        m_chunkDelayMs = 0;
        m_sendBody = false;
        m_truncateAfter = -1;
    }

    // 200-Header mit Content-Length = body.size() senden, aber nur die ersten
    // sendOnlyBytes Bytes liefern und dann die Verbindung schließen ->
    // clientseitig Transportfehler (RemoteHostClosed) bei HTTP-Status 2xx.
    void setTruncatedBody(int status, const QByteArray &body, int sendOnlyBytes)
    {
        m_status = status;
        m_chunks = {body};
        m_chunkDelayMs = 0;
        m_contentType = "application/octet-stream";
        m_sendBody = true;
        m_truncateAfter = sendOnlyBytes;
    }

    QByteArray lastRequestHead;   // Request-Zeile + Header
    QByteArray lastRequestBody;

private:
    void onData(QTcpSocket *sock)
    {
        m_readBuffer.append(sock->readAll());
        const int headerEnd = m_readBuffer.indexOf("\r\n\r\n");
        if (headerEnd < 0)
            return;
        lastRequestHead = m_readBuffer.left(headerEnd);
        int contentLength = 0;
        const QList<QByteArray> lines = lastRequestHead.split('\n');
        for (const QByteArray &line : lines) {
            if (line.toLower().startsWith("content-length:"))
                contentLength = line.mid(15).trimmed().toInt();
        }
        if (m_readBuffer.size() < headerEnd + 4 + contentLength)
            return;
        lastRequestBody = m_readBuffer.mid(headerEnd + 4, contentLength);
        m_readBuffer.clear();
        respond(sock);
    }

    void respond(QTcpSocket *sock)
    {
        const bool delayed = m_chunkDelayMs > 0 && m_chunks.size() > 1;
        QByteArray head = "HTTP/1.1 " + QByteArray::number(m_status) + " Test\r\n"
                          "Content-Type: " + m_contentType + "\r\n"
                          "Connection: close\r\n";
        if (!delayed && m_sendBody) {
            qsizetype total = 0;
            for (const QByteArray &c : std::as_const(m_chunks))
                total += c.size();
            head += "Content-Length: " + QByteArray::number(total) + "\r\n";
        }
        head += "\r\n";
        sock->write(head);
        if (!m_sendBody)
            return;   // stallen: Body kommt nie, Socket bleibt offen
        if (!delayed) {
            if (m_truncateAfter >= 0) {
                sock->write(m_chunks.first().left(m_truncateAfter));
                sock->disconnectFromHost();
                return;
            }
            for (const QByteArray &c : std::as_const(m_chunks))
                sock->write(c);
            sock->disconnectFromHost();
            return;
        }
        sendChunk(sock, 0);
    }

    void sendChunk(QTcpSocket *sock, int index)
    {
        if (index >= m_chunks.size()) {
            sock->disconnectFromHost();
            return;
        }
        sock->write(m_chunks.at(index));
        sock->flush();
        QTimer::singleShot(m_chunkDelayMs, sock,
                           [this, sock, index]() { sendChunk(sock, index + 1); });
    }

    QTcpServer m_server;
    QByteArray m_readBuffer;
    int m_status = 200;
    QList<QByteArray> m_chunks;
    int m_chunkDelayMs = 0;
    QByteArray m_contentType = "application/json";
    bool m_sendBody = true;
    int m_truncateAfter = -1;
};
