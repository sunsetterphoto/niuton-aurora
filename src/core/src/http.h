#pragma once

#include <QJSValue>
#include <QNetworkAccessManager>
#include <QObject>
#include <QQmlEngine>
#include <QVariantMap>

class QNetworkReply;

// HTTP-Singleton für Request/Response-Verkehr der QML-Engine (JSON + Downloads).
// Callbacks sind an die Reply-Lebensdauer gebunden; nach Engine-Teardown wird
// nie mehr aufgerufen (qjsEngine(this)-Guard in invoke()).
class Http : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    Q_PROPERTY(int defaultTimeoutMs READ defaultTimeoutMs WRITE setDefaultTimeoutMs NOTIFY defaultTimeoutMsChanged)

public:
    explicit Http(QObject *parent = nullptr);

    int defaultTimeoutMs() const;
    void setDefaultTimeoutMs(int ms);

    // callback(result): { ok, status, data, error } — callback darf null sein.
    // timeoutMs 0 = defaultTimeoutMs (Inaktivitäts-Timeout via setTransferTimeout)
    Q_INVOKABLE void getJson(const QString &url, const QJSValue &callback, int timeoutMs = 0);
    Q_INVOKABLE void postJson(const QString &url, const QVariant &body, const QJSValue &callback, int timeoutMs = 0);
    // callback(result): { ok, status, path, error } — legt Zielordner an, schreibt atomar (QSaveFile)
    Q_INVOKABLE void downloadToFile(const QString &url, const QString &destPath, const QJSValue &callback, int timeoutMs = 0);

Q_SIGNALS:
    void defaultTimeoutMsChanged();

private:
    QNetworkReply *start(const QString &url, bool post, const QByteArray &payload, int timeoutMs);
    void finishJson(QNetworkReply *reply, const QJSValue &callback);
    void invoke(const QJSValue &callback, const QVariantMap &result);
    static int statusOf(QNetworkReply *reply);
    static QString errorOf(QNetworkReply *reply);
    // QML reicht JS-Objekte/Arrays als QVariant(QJSValue) durch (kein automatisches
    // Downcast auf QVariantMap/-List bei Q_INVOKABLE-Parametertyp QVariant) —
    // QJsonDocument::fromVariant() kennt QJSValue nicht und liefert sonst {}.
    static QVariant normalizeBody(const QVariant &body);

    QNetworkAccessManager m_nam;
    int m_defaultTimeoutMs = 15000;
};
