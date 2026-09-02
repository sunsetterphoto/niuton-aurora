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

QNetworkReply *Http::start(const QString &url, const QByteArray &method,
                           const QByteArray &payload, int timeoutMs,
                           const QVariantMap &headers)
{
    QNetworkRequest req{QUrl(url)};
    req.setTransferTimeout(timeoutMs > 0 ? timeoutMs : m_defaultTimeoutMs);
    // POST und DELETE tragen einen JSON-Body (DELETE: Ollama /api/delete)
    if (method != "GET")
        req.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
    // Nach dem Content-Type gesetzt: ein gleichnamiger Eintrag gewinnt. Muss
    // vor JEDEM Versand stehen — auch vor dem GET-Zweig.
    for (auto it = headers.cbegin(); it != headers.cend(); ++it)
        req.setRawHeader(it.key().toUtf8(), it.value().toString().toUtf8());
    if (method == "GET")
        return m_nam.get(req);
    if (method == "POST")
        return m_nam.post(req, payload);
    return m_nam.sendCustomRequest(req, method, payload);
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

        if (status < 200 || status >= 300) {
            QJsonParseError parseError;
            const QJsonDocument doc = QJsonDocument::fromJson(raw, &parseError);
            result[QStringLiteral("ok")] = false;
            result[QStringLiteral("error")] = QStringLiteral("HTTP %1").arg(status);
            if (parseError.error == QJsonParseError::NoError)
                result[QStringLiteral("data")] = doc.toVariant(); // z.B. Ollama-Error-Body
            invoke(callback, result);
            return;
        }

        // 2xx mit leerem/whitespace-only Body (z.B. 204 No Content) ist ein
        // gueltiger Erfolg — kein Parse-Versuch, sonst meldet fromJson()
        // faelschlich "Ungueltiges JSON" fuer einen leeren Body.
        if (raw.trimmed().isEmpty()) {
            result[QStringLiteral("ok")] = true;
            result[QStringLiteral("data")] = QVariantMap();
            invoke(callback, result);
            return;
        }

        QJsonParseError parseError;
        const QJsonDocument doc = QJsonDocument::fromJson(raw, &parseError);

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

void Http::getJson(const QString &url, const QJSValue &callback, int timeoutMs,
                   const QVariantMap &headers)
{
    finishJson(start(url, "GET", {}, timeoutMs, headers), callback);
}

QVariant Http::normalizeBody(const QVariant &body)
{
    if (body.metaType() == QMetaType::fromType<QJSValue>())
        return body.value<QJSValue>().toVariant();
    return body;
}

void Http::postJson(const QString &url, const QVariant &body, const QJSValue &callback,
                    int timeoutMs, const QVariantMap &headers)
{
    const QByteArray payload = QJsonDocument::fromVariant(normalizeBody(body)).toJson(QJsonDocument::Compact);
    finishJson(start(url, "POST", payload, timeoutMs, headers), callback);
}

void Http::deleteJson(const QString &url, const QVariant &body, const QJSValue &callback, int timeoutMs)
{
    const QByteArray payload = QJsonDocument::fromVariant(normalizeBody(body)).toJson(QJsonDocument::Compact);
    finishJson(start(url, "DELETE", payload, timeoutMs), callback);
}

void Http::downloadToFile(const QString &url, const QString &destPath, const QJSValue &callback, int timeoutMs)
{
    QNetworkReply *reply = start(url, "GET", {}, timeoutMs);
    m_downloads.insert(url, reply);
    connect(reply, &QNetworkReply::finished, this, [this, reply, destPath, callback, url]() {
        m_downloads.remove(url);
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

void Http::cancelDownload(const QString &url)
{
    QNetworkReply *reply = m_downloads.take(url);
    if (reply) reply->abort();   // finished feuert danach mit OperationCanceledError
}
