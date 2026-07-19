#pragma once

#include <QByteArray>
#include <QNetworkAccessManager>
#include <QObject>
#include <QQmlEngine>
#include <QTimer>
#include <QVariantMap>

class QNetworkReply;

// Streamender NDJSON-POST (Ollama /api/chat). Zeilenpufferung in C++:
// objectReceived feuert nur für vollständige, geparste JSON-Zeilen — über
// Chunk-Grenzen gesplittete Zeilen gehen konstruktiv nicht mehr verloren.
class NdjsonStream : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(bool active READ active NOTIFY activeChanged)
    Q_PROPERTY(int idleTimeoutMs READ idleTimeoutMs WRITE setIdleTimeoutMs NOTIFY idleTimeoutMsChanged)
    Q_PROPERTY(int maxLineBytes READ maxLineBytes WRITE setMaxLineBytes NOTIFY maxLineBytesChanged)

public:
    explicit NdjsonStream(QObject *parent = nullptr);

    bool active() const;
    int idleTimeoutMs() const;
    void setIdleTimeoutMs(int ms);
    int maxLineBytes() const;
    void setMaxLineBytes(int bytes);

    // Startet den Stream; ein bereits laufender wird vorher STILL verworfen.
    Q_INVOKABLE void post(const QString &url, const QVariant &body,
                          const QVariantMap &headers = QVariantMap());
    // Bricht still ab: KEIN finished-Signal (der Aufrufer hat abgebrochen).
    Q_INVOKABLE void abort();

Q_SIGNALS:
    void objectReceived(const QVariantMap &obj);
    // ok=true nur bei HTTP 2xx ohne Transportfehler; error: "timeout" | "line too long" | "HTTP <n>" | errorString()
    void finished(bool ok, int status, const QString &error);
    void activeChanged();
    void idleTimeoutMsChanged();
    void maxLineBytesChanged();

private:
    void onReadyRead();
    void onFinished();
    void drainBuffer(bool flush);
    void emitLine(const QByteArray &line);
    void cleanup();
    // QML reicht JS-Objekte als QVariant(QJSValue) durch (kein automatisches
    // Downcast auf QVariantMap bei Q_INVOKABLE-Parametertyp QVariant) —
    // QJsonDocument::fromVariant() kennt QJSValue nicht und liefert sonst {}.
    static QVariant normalizeBody(const QVariant &body);

    QNetworkAccessManager m_nam;
    QNetworkReply *m_reply = nullptr;
    QTimer m_idleTimer;
    QByteArray m_buffer;
    bool m_timedOut = false;
    bool m_lineTooLong = false;
    int m_idleTimeoutMs = 90000;
    // Harte Kappe für eine einzelne Zeile: ein newline-loser Stream ließe den
    // Puffer sonst bis zum Idle-Timeout unbegrenzt wachsen.
    int m_maxLineBytes = 1048576;   // 1 MiB
};
