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
    // headers: zusätzliche Request-Header (Cloud-Backends brauchen
    // "Authorization: Bearer <key>"). Content-Type setzt postJson selbst;
    // ein gleichnamiger Eintrag hier überschreibt ihn bewusst.
    Q_INVOKABLE void getJson(const QString &url, const QJSValue &callback, int timeoutMs = 0,
                             const QVariantMap &headers = QVariantMap());
    Q_INVOKABLE void postJson(const QString &url, const QVariant &body, const QJSValue &callback,
                              int timeoutMs = 0, const QVariantMap &headers = QVariantMap());
    // HTTP DELETE mit JSON-Body (Ollama /api/delete); gleiche Result-Form wie postJson
    Q_INVOKABLE void deleteJson(const QString &url, const QVariant &body, const QJSValue &callback, int timeoutMs = 0);
    // callback(result): { ok, status, path, error } — legt Zielordner an, schreibt atomar (QSaveFile)
    Q_INVOKABLE void downloadToFile(const QString &url, const QString &destPath, const QJSValue &callback, int timeoutMs = 0);
    // Bricht einen laufenden downloadToFile-Download derselben URL ab (no-op,
    // wenn keiner läuft). Der Callback feuert danach noch mit ok:false
    // (OperationCanceledError) — Aufrufer mit eigenem Lauf-Token (z. B.
    // ComfyClient._run) verwerfen ihn; geschrieben wird dank QSaveFile nie.
    Q_INVOKABLE void cancelDownload(const QString &url);

    // Generischer Aufruf für APIs jenseits von reinem JSON (Cloud-Rechner-App-API:
    // Datei-PUT mit rohem Body, Datei-GET als Text, PNG-Antwort in eine Datei).
    // options: { method ("GET"), url, headers {}, body (String = UTF-8-Rohdaten,
    //   Objekt/Array = JSON), contentType (Vorgabe: JSON bei Objekt, sonst
    //   application/octet-stream), timeoutMs (0 = Vorgabe), maxBytes (0 = ohne
    //   Kappe; mehr -> Abbruch mit error "too_large"), saveTo (Pfad: Antwort bei
    //   2xx atomar dorthin schreiben statt als Text liefern) }
    // callback(result): { ok, status, error, data (geparstes JSON, auch bei
    //   Fehlerstatus), text (UTF-8, nur ohne saveTo und wenn nicht binär), binary
    //   (NUL-Byte in den ersten 4 KiB), size, contentType, head (erste 16 Bytes
    //   hex), path (bei saveTo) }
    Q_INVOKABLE void request(const QVariantMap &options, const QJSValue &callback);

Q_SIGNALS:
    void defaultTimeoutMsChanged();

private:
    QNetworkReply *start(const QString &url, const QByteArray &method, const QByteArray &payload,
                         int timeoutMs, const QVariantMap &headers = QVariantMap());
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
    // Laufende downloadToFile-Downloads (URL -> reply) für cancelDownload().
    QHash<QString, QNetworkReply *> m_downloads;
};
