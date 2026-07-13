#include "http.h"

#include <QDir>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonParseError>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QSaveFile>

Http::Http(QObject *parent)
    : QObject(parent)
{
}

int Http::defaultTimeoutMs() const
{
    return m_defaultTimeoutMs;
}

void Http::setDefaultTimeoutMs(int ms)
{
    if (ms == m_defaultTimeoutMs)
        return;
    m_defaultTimeoutMs = ms;
    Q_EMIT defaultTimeoutMsChanged();
}

QNetworkReply *Http::start(const QString &url, bool post, const QByteArray &payload, int timeoutMs)
{
    QNetworkRequest req{QUrl(url)};
    req.setTransferTimeout(timeoutMs > 0 ? timeoutMs : m_defaultTimeoutMs);
    if (post) {
        req.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
        return m_nam.post(req, payload);
    }
    return m_nam.get(req);
}

int Http::statusOf(QNetworkReply *reply)
{
    return reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
}

QString Http::errorOf(QNetworkReply *reply)
{
    // setTransferTimeout() liefert bei ausgelöstem Inaktivitäts-Timeout
    // QNetworkReply::TimeoutError (empirisch mit Qt 6.11 verifiziert; ohne
    // öffentliches abort() ist das ansonsten nicht erreichbar).
    if (reply->error() == QNetworkReply::TimeoutError
        || reply->error() == QNetworkReply::OperationCanceledError)
        return QStringLiteral("timeout");
    return reply->errorString();
}

void Http::invoke(const QJSValue &callback, const QVariantMap &result)
{
    if (!callback.isCallable())
        return;
    QJSEngine *engine = qjsEngine(this);
    if (!engine)
        return; // Engine-Teardown: nie in eine tote Engine rufen
    QJSValue cb = callback;
    cb.call({engine->toScriptValue(result)});
}

void Http::finishJson(QNetworkReply *reply, const QJSValue &callback)
{
    connect(reply, &QNetworkReply::finished, this, [this, reply, callback]() {
        reply->deleteLater();
        QVariantMap result;
        const int status = statusOf(reply);
        result[QStringLiteral("status")] = status;

        // kein HTTP-Status (refused, DNS, ...) ODER Transfer-Timeout: Header koennen
        // bereits angekommen sein (status != 0), bevor der Inaktivitaets-Timeout den
        // Transfer abbricht -> Timeout-/OperationCanceled-Error explizit mitpruefen.
        // Vor dem Fehler-Check kein readAll(): auf einem bereits abgebrochenen
        // Transfer warnt Qt sonst intern ("device not open").
        if (status == 0 || reply->error() == QNetworkReply::TimeoutError
            || reply->error() == QNetworkReply::OperationCanceledError) {
            result[QStringLiteral("ok")] = false;
            result[QStringLiteral("error")] = errorOf(reply);
            invoke(callback, result);
            return;
        }

        const QByteArray raw = reply->readAll();
        QJsonParseError parseError;
        const QJsonDocument doc = QJsonDocument::fromJson(raw, &parseError);

        if (status < 200 || status >= 300) {
            result[QStringLiteral("ok")] = false;
            result[QStringLiteral("error")] = QStringLiteral("HTTP %1").arg(status);
            if (parseError.error == QJsonParseError::NoError)
                result[QStringLiteral("data")] = doc.toVariant(); // z.B. Ollama-Error-Body
            invoke(callback, result);
            return;
        }

        if (parseError.error != QJsonParseError::NoError) {
            result[QStringLiteral("ok")] = false;
            result[QStringLiteral("error")] =
                QString(QStringLiteral("Ungültiges JSON: ") + parseError.errorString());
            invoke(callback, result);
            return;
        }

        result[QStringLiteral("ok")] = true;
        result[QStringLiteral("data")] = doc.toVariant();
        invoke(callback, result);
    });
}

void Http::getJson(const QString &url, const QJSValue &callback, int timeoutMs)
{
    finishJson(start(url, false, {}, timeoutMs), callback);
}

QVariant Http::normalizeBody(const QVariant &body)
{
    if (body.metaType() == QMetaType::fromType<QJSValue>())
        return body.value<QJSValue>().toVariant();
    return body;
}

void Http::postJson(const QString &url, const QVariant &body, const QJSValue &callback, int timeoutMs)
{
    const QByteArray payload = QJsonDocument::fromVariant(normalizeBody(body)).toJson(QJsonDocument::Compact);
    finishJson(start(url, true, payload, timeoutMs), callback);
}

void Http::downloadToFile(const QString &url, const QString &destPath, const QJSValue &callback, int timeoutMs)
{
    QNetworkReply *reply = start(url, false, {}, timeoutMs);
    connect(reply, &QNetworkReply::finished, this, [this, reply, destPath, callback]() {
        reply->deleteLater();
        QVariantMap result;
        const int status = statusOf(reply);
        result[QStringLiteral("status")] = status;
        result[QStringLiteral("path")] = destPath;

        if (reply->error() != QNetworkReply::NoError || status < 200 || status >= 300) {
            result[QStringLiteral("ok")] = false;
            // Konsistent zu finishJson: non-2xx-Status meldet "HTTP <n>";
            // Transportfehler-Text nur ohne Status (refused/timeout) oder bei
            // Abbruch mitten im Body einer 2xx-Antwort.
            result[QStringLiteral("error")] = (status > 0 && (status < 200 || status >= 300))
                ? QString(QStringLiteral("HTTP %1").arg(status))
                : errorOf(reply);
            invoke(callback, result);
            return;
        }

        const QFileInfo info(destPath);
        if (!QDir().mkpath(info.absolutePath())) {
            result[QStringLiteral("ok")] = false;
            result[QStringLiteral("error")] =
                QString(QStringLiteral("Zielordner nicht anlegbar: ") + info.absolutePath());
            invoke(callback, result);
            return;
        }

        // Bewusst im Speicher gepuffert: Bilder liegen im MB-Bereich; für große
        // Downloads wäre readyRead-Streaming nötig (hier YAGNI).
        QSaveFile file(destPath);
        if (!file.open(QIODevice::WriteOnly)) {
            result[QStringLiteral("ok")] = false;
            result[QStringLiteral("error")] = file.errorString();
            invoke(callback, result);
            return;
        }
        file.write(reply->readAll());
        if (!file.commit()) {
            result[QStringLiteral("ok")] = false;
            result[QStringLiteral("error")] = file.errorString();
            invoke(callback, result);
            return;
        }

        result[QStringLiteral("ok")] = true;
        invoke(callback, result);
    });
}
