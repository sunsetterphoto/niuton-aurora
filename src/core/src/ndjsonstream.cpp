#include "ndjsonstream.h"

#include <QJSValue>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkReply>
#include <QNetworkRequest>

NdjsonStream::NdjsonStream(QObject *parent)
    : QObject(parent)
{
    m_idleTimer.setSingleShot(true);
    connect(&m_idleTimer, &QTimer::timeout, this, [this]() {
        if (!m_reply)
            return;
        m_timedOut = true;
        m_reply->abort(); // löst onFinished aus -> finished(false, ..., "timeout")
    });
}

bool NdjsonStream::active() const
{
    return m_reply != nullptr;
}

int NdjsonStream::idleTimeoutMs() const
{
    return m_idleTimeoutMs;
}

void NdjsonStream::setIdleTimeoutMs(int ms)
{
    if (ms == m_idleTimeoutMs)
        return;
    m_idleTimeoutMs = ms;
    Q_EMIT idleTimeoutMsChanged();
}

int NdjsonStream::maxLineBytes() const
{
    return m_maxLineBytes;
}

void NdjsonStream::setMaxLineBytes(int bytes)
{
    if (bytes == m_maxLineBytes)
        return;
    m_maxLineBytes = bytes;
    Q_EMIT maxLineBytesChanged();
}

QVariant NdjsonStream::normalizeBody(const QVariant &body)
{
    if (body.metaType() == QMetaType::fromType<QJSValue>())
        return body.value<QJSValue>().toVariant();
    return body;
}

void NdjsonStream::post(const QString &url, const QVariant &body, const QVariantMap &headers)
{
    abort(); // laufenden Stream still verwerfen

    QNetworkRequest req{QUrl(url)};
    req.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
    for (auto it = headers.constBegin(); it != headers.constEnd(); ++it)
        req.setRawHeader(it.key().toUtf8(), it.value().toString().toUtf8());

    m_timedOut = false;
    m_lineTooLong = false;
    m_buffer.clear();
    m_reply = m_nam.post(req, QJsonDocument::fromVariant(normalizeBody(body)).toJson(QJsonDocument::Compact));
    connect(m_reply, &QNetworkReply::readyRead, this, &NdjsonStream::onReadyRead);
    connect(m_reply, &QNetworkReply::finished, this, &NdjsonStream::onFinished);
    m_idleTimer.start(m_idleTimeoutMs);
    Q_EMIT activeChanged();
}

void NdjsonStream::abort()
{
    if (!m_reply)
        return;
    QNetworkReply *reply = m_reply;
    cleanup(); // m_reply zuerst nullen, dann Slots trennen: abort() darf nichts mehr auslösen
    reply->disconnect(this);
    reply->abort();
    reply->deleteLater();
}

void NdjsonStream::onReadyRead()
{
    m_idleTimer.start(m_idleTimeoutMs); // pro Chunk neu starten
    m_buffer.append(m_reply->readAll());
    drainBuffer(false);
    if (!m_reply)
        return; // ein Handler hat abort() gerufen
    if (m_buffer.size() > m_maxLineBytes) {
        // Newline-lose Riesenzeile: der Puffer würde bis zum Idle-Timeout
        // weiterwachsen — Stream wie beim Timeout hart abbrechen; die
        // angefangene Zeile wird verworfen (onFinished flusht sie nicht).
        m_lineTooLong = true;
        m_reply->abort(); // löst onFinished aus -> finished(false, ..., "line too long")
    }
}

void NdjsonStream::onFinished()
{
    QNetworkReply *reply = m_reply;
    // Nach Timeout-abort() ist das Device bereits geschlossen: readAll() wuerde
    // Qt-intern "device not open" warnen (s. Http::finishJson-Erkenntnis aus Task 2).
    // Bei m_lineTooLong gilt dasselbe — und die zu lange Zeile wird ohnehin verworfen.
    if (!m_timedOut && !m_lineTooLong)
        m_buffer.append(reply->readAll());
    if (!m_lineTooLong)
        drainBuffer(true);   // kein Flush: die übergroße Restzeile gehoert verworfen
    if (m_reply != reply)
        return; // ein Handler hat abort() ODER post() gerufen: alter Request ist
                // verworfen, still bleiben (abort() hat cleanup() + deleteLater()
                // des alten Replys erledigt; bei post() lebt bereits ein NEUES
                // m_reply, das hier nicht angefasst werden darf)

    const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    QString error;
    bool ok = false;
    if (m_timedOut)
        error = QStringLiteral("timeout");
    else if (m_lineTooLong)
        error = QStringLiteral("line too long");
    else if (status != 0 && (status < 200 || status >= 300))
        // HTTP-Statuscode hat Vorrang vor reply->error(): Qt klassifiziert
        // manche Statuscodes (z. B. 404) selbst als Transportfehler und würde
        // sonst dessen generische errorString() statt "HTTP <n>" liefern.
        error = QStringLiteral("HTTP %1").arg(status);
    else if (reply->error() != QNetworkReply::NoError)
        error = reply->errorString();
    else
        ok = true;

    cleanup();
    reply->deleteLater();
    Q_EMIT finished(ok, status, error);
}

void NdjsonStream::drainBuffer(bool flush)
{
    qsizetype nl = -1;
    while ((nl = m_buffer.indexOf('\n')) >= 0) {
        const QByteArray line = m_buffer.left(nl).trimmed();
        m_buffer.remove(0, nl + 1);
        emitLine(line);
        if (!m_reply)
            return; // ein Handler hat abort() gerufen
    }
    if (flush) {
        const QByteArray line = m_buffer.trimmed();
        m_buffer.clear();
        emitLine(line);
    }
}

void NdjsonStream::emitLine(const QByteArray &line)
{
    if (line.isEmpty())
        return;
    const QJsonDocument doc = QJsonDocument::fromJson(line);
    if (!doc.isObject())
        return; // defekte, aber vollständige Zeile: überspringen
    Q_EMIT objectReceived(doc.object().toVariantMap());
}

void NdjsonStream::cleanup()
{
    m_idleTimer.stop();
    m_buffer.clear();
    m_reply = nullptr;
    Q_EMIT activeChanged();
}
