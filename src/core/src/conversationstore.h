#pragma once

#include <QObject>
#include <QQmlEngine>
#include <QThread>
#include <QVariantList>
#include <QVariantMap>

class StoreWorker;

// SQLite-Persistenz für Konversationen (Schema v1, Spec Abschnitt 4).
// Domänen-API, bewusst KEIN generischer SQL-Executor. Reads: synchron über
// eine GUI-Thread-Verbindung (WAL erlaubt paralleles Lesen). Writes: asynchron
// über einen Worker-Thread mit eigener Verbindung (BEGIN IMMEDIATE,
// busy_timeout 500 ms) — plasmashell friert bei Lock-Kontention nie ein.
class ConversationStore : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    Q_PROPERTY(bool ready READ ready NOTIFY readyChanged)

public:
    explicit ConversationStore(QObject *parent = nullptr);
    ~ConversationStore() override;

    bool ready() const;

    Q_INVOKABLE QVariantMap open();
    Q_INVOKABLE QString dbPath() const;
    Q_INVOKABLE QString newUuid() const;

    // Reads (synchron)
    Q_INVOKABLE QVariantList listConversations(int limit = 100) const;
    Q_INVOKABLE QVariantList messages(const QString &conversationId) const;
    Q_INVOKABLE QString latestConversationId() const;
    Q_INVOKABLE QVariantMap conversation(const QString &id) const;
    Q_INVOKABLE QVariantList goodExamples() const;
    Q_INVOKABLE QString questionForAnswer(const QString &assistantId) const;
    Q_INVOKABLE QVariantList knowledgeEntries() const;

    // Writes (asynchron)
    Q_INVOKABLE void createConversation(const QString &id, const QString &title);
    Q_INVOKABLE void appendMessage(const QVariantMap &msg);
    Q_INVOKABLE void updateMessage(const QString &id, const QVariantMap &fields);
    Q_INVOKABLE void setEmbedding(const QString &id, const QVariantList &vec, const QString &model);
    Q_INVOKABLE void addKnowledge(const QVariantMap &fields);
    Q_INVOKABLE void updateKnowledge(const QString &id, const QVariantMap &fields);
    Q_INVOKABLE void setKnowledgeEmbedding(const QString &id, const QVariantList &vec, const QString &model);
    Q_INVOKABLE void deleteKnowledge(const QString &id);
    Q_INVOKABLE void deleteMessage(const QString &id);
    Q_INVOKABLE void touchConversation(const QString &id, const QString &title);
    Q_INVOKABLE void updateConversation(const QString &id, const QVariantMap &fields);
    Q_INVOKABLE void deleteConversation(const QString &id);
    Q_INVOKABLE void appendToolCall(const QVariantMap &toolCall);
    Q_INVOKABLE void updateToolCall(const QString &id, const QVariantMap &fields);
    Q_INVOKABLE void sweepNonFinal();

Q_SIGNALS:
    void readyChanged();
    void writeFailed(const QString &op, const QString &error);
    void writeCompleted(const QString &op);
    // intern: Auftrag an den Worker (queued über die Thread-Grenze)
    void opRequested(const QString &op, const QVariantMap &args);

private:
    void enqueue(const QString &op, const QVariantMap &args);

    QThread m_thread;
    StoreWorker *m_worker = nullptr;
    bool m_ready = false;
    QString m_readConn;   // Name der GUI-Lese-Verbindung
};
