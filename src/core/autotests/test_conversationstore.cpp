#include <QDir>
#include <QFileInfo>
#include <QSignalSpy>
#include <QSqlDatabase>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QtTest>

#include "conversationstore.h"

// Jeder Test bekommt eine frische DB über AURORA_DB_PATH (Global Constraint:
// dbPath() ist zentral gekapselt mit Env-Override).
class StoreFixture
{
public:
    StoreFixture()
    {
        dir = new QTemporaryDir;
        qputenv("AURORA_DB_PATH", (dir->path() + "/test.db").toUtf8());
        store = new ConversationStore;
    }
    ~StoreFixture()
    {
        delete store;              // stoppt Worker-Thread geordnet
        delete dir;
        qunsetenv("AURORA_DB_PATH");
    }
    QTemporaryDir *dir = nullptr;
    ConversationStore *store = nullptr;
};

class TestConversationStore : public QObject
{
    Q_OBJECT

private Q_SLOTS:
    void open_erzeugtSchema_undIstIdempotent()
    {
        StoreFixture f;
        const QVariantMap r = f.store->open();
        QCOMPARE(r.value("ok").toBool(), true);
        QCOMPARE(f.store->ready(), true);
        QVERIFY(QFile::exists(f.store->dbPath()));

        // Schema prüfen über eine eigene Testverbindung
        {
            QSqlDatabase db = QSqlDatabase::addDatabase("QSQLITE", "schemacheck");
            db.setDatabaseName(f.store->dbPath());
            QVERIFY(db.open());
            QSqlQuery q(db);
            QVERIFY(q.exec("PRAGMA user_version"));
            QVERIFY(q.next());
            QCOMPARE(q.value(0).toInt(), 4);
            QVERIFY(q.exec("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"));
            QStringList tables;
            while (q.next()) tables << q.value(0).toString();
            QVERIFY(tables.contains("conversations"));
            QVERIFY(tables.contains("messages"));
            QVERIFY(tables.contains("tool_calls"));
            QVERIFY(tables.contains("knowledge"));
            db.close();
        }
        QSqlDatabase::removeDatabase("schemacheck");

        // idempotent: zweites open ist ok
        const QVariantMap r2 = f.store->open();
        QCOMPARE(r2.value("ok").toBool(), true);
    }

    void open_lehntNeuereSchemaVersionAb()
    {
        StoreFixture f;
        // DB mit user_version=99 präparieren
        {
            QSqlDatabase db = QSqlDatabase::addDatabase("QSQLITE", "prep");
            db.setDatabaseName(qEnvironmentVariable("AURORA_DB_PATH"));
            QVERIFY(db.open());
            QSqlQuery q(db);
            QVERIFY(q.exec("PRAGMA user_version = 99"));
            db.close();
        }
        QSqlDatabase::removeDatabase("prep");
        const QVariantMap r = f.store->open();
        QCOMPARE(r.value("ok").toBool(), false);
        QVERIFY(r.value("error").toString().contains("99"));
        QCOMPARE(f.store->ready(), false);
    }

    void appendMessage_legtKonversationLazyAn_undVergibtSeq()
    {
        StoreFixture f;
        QVERIFY(f.store->open().value("ok").toBool());
        QSignalSpy done(f.store, &ConversationStore::writeCompleted);

        const QString cid = f.store->newUuid();
        QVERIFY(!cid.isEmpty());

        // KEIN createConversation — die Zeile muss lazy entstehen
        f.store->appendMessage({{"conversationId", cid}, {"role", "user"}, {"content", "hallo"}});
        f.store->appendMessage({{"conversationId", cid}, {"role", "assistant"},
                                {"content", "hi"}, {"thinking", "kurz nachgedacht"},
                                {"model", "gemma4:e2b"}, {"backend", "local"}});
        QTRY_COMPARE(done.count(), 2);

        const QVariantList msgs = f.store->messages(cid);
        QCOMPARE(msgs.size(), 2);
        QCOMPARE(msgs.at(0).toMap().value("seq").toInt(), 0);
        QCOMPARE(msgs.at(1).toMap().value("seq").toInt(), 1);
        QCOMPARE(msgs.at(0).toMap().value("role").toString(), QString("user"));
        QCOMPARE(msgs.at(1).toMap().value("thinking").toString(), QString("kurz nachgedacht"));
        QCOMPARE(msgs.at(1).toMap().value("status").toString(), QString("final"));

        const QVariantList convs = f.store->listConversations();
        QCOMPARE(convs.size(), 1);
        QCOMPARE(convs.first().toMap().value("id").toString(), cid);
    }

    void listConversations_sortiertNachAktivitaet()
    {
        StoreFixture f;
        QVERIFY(f.store->open().value("ok").toBool());
        QSignalSpy done(f.store, &ConversationStore::writeCompleted);

        const QString alt = f.store->newUuid();
        const QString neu = f.store->newUuid();
        f.store->appendMessage({{"conversationId", alt}, {"role", "user"}, {"content", "erste"}});
        QTRY_COMPARE(done.count(), 1);
        QTest::qWait(5);   // getrennte Timestamps (ms-Auflösung)
        f.store->appendMessage({{"conversationId", neu}, {"role", "user"}, {"content", "zweite"}});
        QTRY_COMPARE(done.count(), 2);
        QTest::qWait(5);
        // Aktivität in der ÄLTEREN Konversation -> sie muss nach vorn
        f.store->appendMessage({{"conversationId", alt}, {"role", "assistant"}, {"content", "antwort"}});
        QTRY_COMPARE(done.count(), 3);

        const QVariantList convs = f.store->listConversations();
        QCOMPARE(convs.size(), 2);
        QCOMPARE(convs.first().toMap().value("id").toString(), alt);
        QCOMPARE(f.store->latestConversationId(), alt);
    }

    void messages_unbekannteKonversation_istLeer_undLatestOhneDaten()
    {
        StoreFixture f;
        QVERIFY(f.store->open().value("ok").toBool());
        QCOMPARE(f.store->messages(QString("gibt-es-nicht")).size(), 0);
        QCOMPARE(f.store->latestConversationId(), QString());
    }

    void appendMessage_mitExtraMap_wirdAlsJsonPersistiertUndGelesen()
    {
        StoreFixture f;
        QVERIFY(f.store->open().value("ok").toBool());
        QSignalSpy done(f.store, &ConversationStore::writeCompleted);
        const QString cid = f.store->newUuid();
        f.store->appendMessage({{"conversationId", cid}, {"role", "user"}, {"content", "mit anhang"},
                                {"extra", QVariantMap{{"attachments",
                                    QVariantList{QVariantMap{{"path", "/tmp/a.png"}, {"mime", "image/png"}}}}}}});
        QTRY_COMPARE(done.count(), 1);
        const QVariantMap m = f.store->messages(cid).first().toMap();
        const QVariantMap extra = m.value("extra").toMap();
        const QVariantList atts = extra.value("attachments").toList();
        QCOMPARE(atts.size(), 1);
        QCOMPARE(atts.first().toMap().value("path").toString(), QString("/tmp/a.png"));
    }

    void vorOpen_readsLeer_undWritesMeldenFailed()
    {
        // Interfaces-Vertrag: vor open() liefern Reads leere Ergebnisse und
        // Writes melden writeFailed — nichts crasht.
        StoreFixture f;
        QCOMPARE(f.store->listConversations().size(), 0);
        QCOMPARE(f.store->messages(QString("x")).size(), 0);
        QCOMPARE(f.store->latestConversationId(), QString());
        QSignalSpy failed(f.store, &ConversationStore::writeFailed);
        f.store->appendMessage({{"conversationId", "x"}, {"role", "user"}, {"content", "y"}});
        QCOMPARE(failed.count(), 1);   // synchron emittiert (enqueue-Guard)
        QVERIFY(failed.first().at(1).toString().contains(QStringLiteral("open")));
    }

    void appendMessage_ungueltigeRole_meldetWriteFailed()
    {
        StoreFixture f;
        QVERIFY(f.store->open().value("ok").toBool());
        QSignalSpy failed(f.store, &ConversationStore::writeFailed);
        f.store->appendMessage({{"conversationId", f.store->newUuid()},
                                {"role", "system"}, {"content", "verboten"}});
        QTRY_COMPARE(failed.count(), 1);   // CHECK-Constraint (role IN user/assistant/tool)
        QCOMPARE(failed.first().at(0).toString(), QString("appendMessage"));
    }

    void createConversation_direkt_auchMitNullTitle()
    {
        StoreFixture f;
        QVERIFY(f.store->open().value("ok").toBool());
        QSignalSpy done(f.store, &ConversationStore::writeCompleted);
        const QString cid = f.store->newUuid();
        f.store->createConversation(cid, QString());   // null-QString-Titel darf nicht failen
        QTRY_COMPARE(done.count(), 1);
        const QVariantList convs = f.store->listConversations();
        QCOMPARE(convs.size(), 1);
        QCOMPARE(convs.first().toMap().value("id").toString(), cid);
        QCOMPARE(convs.first().toMap().value("title").toString(), QString());
    }

    void touchConversation_setztTitelUndAktivitaet()
    {
        StoreFixture f;
        QVERIFY(f.store->open().value("ok").toBool());
        QSignalSpy done(f.store, &ConversationStore::writeCompleted);
        const QString cid = f.store->newUuid();
        f.store->appendMessage({{"conversationId", cid}, {"role", "user"}, {"content", "x"}});
        QTRY_COMPARE(done.count(), 1);
        f.store->touchConversation(cid, QStringLiteral("Mein Titel"));
        QTRY_COMPARE(done.count(), 2);
        QCOMPARE(f.store->listConversations().first().toMap().value("title").toString(),
                 QString("Mein Titel"));
        // title "" = nur updated_at anfassen, Titel bleibt
        f.store->touchConversation(cid, QString());
        QTRY_COMPARE(done.count(), 3);
        QCOMPARE(f.store->listConversations().first().toMap().value("title").toString(),
                 QString("Mein Titel"));
    }

    void updateMessage_aendertNurErlaubteFelder()
    {
        StoreFixture f;
        QVERIFY(f.store->open().value("ok").toBool());
        QSignalSpy done(f.store, &ConversationStore::writeCompleted);
        const QString cid = f.store->newUuid();
        const QString mid = f.store->newUuid();
        f.store->appendMessage({{"conversationId", cid}, {"id", mid},
                                {"role", "assistant"}, {"content", "alt"}});
        QTRY_COMPARE(done.count(), 1);
        f.store->updateMessage(mid, {{"content", "neu"}, {"status", "aborted"}});
        QTRY_COMPARE(done.count(), 2);
        const QVariantMap m = f.store->messages(cid).first().toMap();
        QCOMPARE(m.value("content").toString(), QString("neu"));
        QCOMPARE(m.value("status").toString(), QString("aborted"));
        QCOMPARE(m.value("role").toString(), QString("assistant"));   // unangetastet
    }

    void deleteConversation_cascade_undAttachmentOrdner()
    {
        StoreFixture f;
        QVERIFY(f.store->open().value("ok").toBool());
        QSignalSpy done(f.store, &ConversationStore::writeCompleted);
        const QString cid = f.store->newUuid();
        f.store->appendMessage({{"conversationId", cid}, {"role", "user"}, {"content", "x"}});
        QTRY_COMPARE(done.count(), 1);

        // Attachment-Ordner simulieren: dirname(dbPath)/attachments/<cid>/
        const QString attDir = QFileInfo(f.store->dbPath()).absolutePath()
            + QStringLiteral("/attachments/") + cid;
        QVERIFY(QDir().mkpath(attDir));
        {
            QFile a(attDir + QStringLiteral("/bild.png"));
            QVERIFY(a.open(QIODevice::WriteOnly));
            a.write("x");
        }

        f.store->deleteConversation(cid);
        QTRY_COMPARE(done.count(), 2);
        QCOMPARE(f.store->listConversations().size(), 0);
        QCOMPARE(f.store->messages(cid).size(), 0);      // CASCADE
        QTRY_VERIFY(!QDir(attDir).exists());             // Ordner weg
    }

    void deleteConversation_leereId_meldetWriteFailed()
    {
        StoreFixture f;
        QVERIFY(f.store->open().value("ok").toBool());
        // Attachment-Root mit fremdem Inhalt darf NICHT angefasst werden
        const QString attRoot = QFileInfo(f.store->dbPath()).absolutePath()
            + QStringLiteral("/attachments");
        QVERIFY(QDir().mkpath(attRoot + QStringLiteral("/andere-konversation")));
        QSignalSpy failed(f.store, &ConversationStore::writeFailed);
        f.store->deleteConversation(QString());
        QTRY_COMPARE(failed.count(), 1);
        QCOMPARE(failed.first().at(0).toString(), QString("deleteConversation"));
        QVERIFY(QDir(attRoot + QStringLiteral("/andere-konversation")).exists());   // Root unangetastet
    }

    void toolCalls_roundtrip_undSweep()
    {
        StoreFixture f;
        QVERIFY(f.store->open().value("ok").toBool());
        QSignalSpy done(f.store, &ConversationStore::writeCompleted);
        const QString cid = f.store->newUuid();
        const QString mid = f.store->newUuid();
        f.store->appendMessage({{"conversationId", cid}, {"id", mid},
                                {"role", "assistant"}, {"content", ""}});
        QTRY_COMPARE(done.count(), 1);

        const QString tid = f.store->newUuid();
        f.store->appendToolCall({{"id", tid}, {"messageId", mid}, {"callIndex", 0},
                                 {"toolName", "web_search"},
                                 {"arguments", QVariantMap{{"query", "wetter"}}}});
        QTRY_COMPARE(done.count(), 2);

        f.store->updateToolCall(tid, {{"status", "running"}});
        QTRY_COMPARE(done.count(), 3);

        // sweepNonFinal: running -> aborted
        f.store->sweepNonFinal();
        QTRY_COMPARE(done.count(), 4);

        // Verifikation über eine Testverbindung (tool_calls hat keine Lese-API — Phase 5)
        {
            QSqlDatabase db = QSqlDatabase::addDatabase("QSQLITE", "tccheck");
            db.setDatabaseName(f.store->dbPath());
            QVERIFY(db.open());
            QSqlQuery q(db);
            QVERIFY(q.exec("SELECT status, tool_name, arguments FROM tool_calls"));
            QVERIFY(q.next());
            QCOMPARE(q.value(0).toString(), QString("aborted"));
            QCOMPARE(q.value(1).toString(), QString("web_search"));
            QVERIFY(q.value(2).toString().contains("wetter"));
            db.close();
        }
        QSqlDatabase::removeDatabase("tccheck");
    }

    void deleteMessage_entferntEinzelneZeile_seqVergabeBleibtMonoton()
    {
        StoreFixture f;
        QVERIFY(f.store->open().value("ok").toBool());
        QSignalSpy done(f.store, &ConversationStore::writeCompleted);
        const QString cid = f.store->newUuid();
        const QString m1 = f.store->newUuid();
        const QString m2 = f.store->newUuid();
        f.store->appendMessage({{"conversationId", cid}, {"id", m1}, {"role", "user"}, {"content", "frage"}});
        f.store->appendMessage({{"conversationId", cid}, {"id", m2}, {"role", "assistant"}, {"content", "antwort"}});
        QTRY_COMPARE(done.count(), 2);
        f.store->deleteMessage(m2);
        QTRY_COMPARE(done.count(), 3);
        QCOMPARE(f.store->messages(cid).size(), 1);
        // Regenerate-Muster: neue Antwort nach Delete — seq bleibt monoton (MAX+1)
        f.store->appendMessage({{"conversationId", cid}, {"role", "assistant"}, {"content", "neu"}});
        QTRY_COMPARE(done.count(), 4);
        const QVariantList msgs = f.store->messages(cid);
        QCOMPARE(msgs.size(), 2);
        QVERIFY(msgs.at(1).toMap().value("seq").toInt() > msgs.at(0).toMap().value("seq").toInt());
    }

    void updateMessage_rating_roundTrip()
    {
        StoreFixture f;
        QVERIFY(f.store->open().value("ok").toBool());
        QSignalSpy done(f.store, &ConversationStore::writeCompleted);
        const QString cid = f.store->newUuid();
        const QString aid = f.store->newUuid();
        f.store->appendMessage({{"id", f.store->newUuid()}, {"conversationId", cid},
                                {"role", "user"}, {"content", "frage"}});
        f.store->appendMessage({{"id", aid}, {"conversationId", cid},
                                {"role", "assistant"}, {"content", "antwort"}});
        QTRY_COMPARE(done.count(), 2);

        // Default ist 0 (neutral)
        QCOMPARE(f.store->messages(cid).at(1).toMap().value("rating").toInt(), 0);

        // 👍
        f.store->updateMessage(aid, {{"rating", 1}});
        QTRY_COMPARE(done.count(), 3);
        QCOMPARE(f.store->messages(cid).at(1).toMap().value("rating").toInt(), 1);

        // 👎
        f.store->updateMessage(aid, {{"rating", -1}});
        QTRY_COMPARE(done.count(), 4);
        QCOMPARE(f.store->messages(cid).at(1).toMap().value("rating").toInt(), -1);

        // zurück auf 0 (in-place-Entfernen)
        f.store->updateMessage(aid, {{"rating", 0}});
        QTRY_COMPARE(done.count(), 5);
        QCOMPARE(f.store->messages(cid).at(1).toMap().value("rating").toInt(), 0);
    }

    void appendToolCall_fremdeMessageId_meldetWriteFailed()
    {
        StoreFixture f;
        QVERIFY(f.store->open().value("ok").toBool());
        QSignalSpy failed(f.store, &ConversationStore::writeFailed);
        f.store->appendToolCall({{"messageId", "gibt-es-nicht"}, {"callIndex", 0},
                                 {"toolName", "x"}});
        QTRY_COMPARE(failed.count(), 1);
        // Scharfes Orakel: es muss die FK-Verletzung sein (foreign_keys=ON),
        // nicht irgendein Fehler (im RED-Zustand käme "Unbekannte Operation")
        QCOMPARE(failed.first().at(0).toString(), QString("appendToolCall"));
        QVERIFY(failed.first().at(1).toString().contains(QLatin1String("FOREIGN KEY"), Qt::CaseInsensitive));
    }

    void updateConversation_extra_roundTrip()
    {
        StoreFixture f;
        QVERIFY(f.store->open().value("ok").toBool());
        QSignalSpy done(f.store, &ConversationStore::writeCompleted);
        const QString cid = f.store->newUuid();
        f.store->createConversation(cid, "Titel");
        QTRY_COMPARE(done.count(), 1);

        // extra ist zunächst leer
        QCOMPARE(f.store->conversation(cid).value("extra").toMap().isEmpty(), true);

        f.store->updateConversation(cid, {{"extra", QVariantMap{{"contextSummary", "kurz"},
                                                                {"contextSummaryThroughMsgId", "m9"}}}});
        QTRY_COMPARE(done.count(), 2);
        const QVariantMap ex = f.store->conversation(cid).value("extra").toMap();
        QCOMPARE(ex.value("contextSummary").toString(), QString("kurz"));
        QCOMPARE(ex.value("contextSummaryThroughMsgId").toString(), QString("m9"));

        // unbekannte Konversation -> leere Map, kein Absturz
        QCOMPARE(f.store->conversation("gibt-es-nicht").isEmpty(), true);
    }

    void embedding_setzenLesenUndLoeschen()
    {
        StoreFixture f;
        QVERIFY(f.store->open().value("ok").toBool());
        QSignalSpy done(f.store, &ConversationStore::writeCompleted);
        const QString cid = f.store->newUuid();
        const QString aid = f.store->newUuid();
        f.store->appendMessage({{"conversationId", cid}, {"role", "user"}, {"content", "Hauptstadt?"}});
        f.store->appendMessage({{"id", aid}, {"conversationId", cid}, {"role", "assistant"}, {"content", "Paris"}});
        QTRY_COMPARE(done.count(), 2);

        // Setzen: 3 floats + Modellname
        f.store->setEmbedding(aid, QVariantList{0.5, -0.25, 1.0}, QStringLiteral("nomic-embed-text"));
        QTRY_COMPARE(done.count(), 3);
        {
            QSqlDatabase db = QSqlDatabase::addDatabase("QSQLITE", "embcheck");
            db.setDatabaseName(f.store->dbPath());
            QVERIFY(db.open());
            QSqlQuery q(db);
            QVERIFY(q.exec("SELECT embedding, embed_model FROM messages WHERE id='" + aid + "'"));
            QVERIFY(q.next());
            QCOMPARE(q.value(0).toByteArray().size(), int(3 * sizeof(float)));
            QCOMPARE(q.value(1).toString(), QString("nomic-embed-text"));
            db.close();
        }
        QSqlDatabase::removeDatabase("embcheck");

        // Löschen: leerer Vektor -> NULL + leerer Modellname
        f.store->setEmbedding(aid, QVariantList{}, QString());
        QTRY_COMPARE(done.count(), 4);
        {
            QSqlDatabase db = QSqlDatabase::addDatabase("QSQLITE", "embcheck2");
            db.setDatabaseName(f.store->dbPath());
            QVERIFY(db.open());
            QSqlQuery q(db);
            QVERIFY(q.exec("SELECT embedding IS NULL, embed_model FROM messages WHERE id='" + aid + "'"));
            QVERIFY(q.next());
            QCOMPARE(q.value(0).toInt(), 1);
            QCOMPARE(q.value(1).toString(), QString());
            db.close();
        }
        QSqlDatabase::removeDatabase("embcheck2");
    }

    void goodExamples_nurRating1_mitFrageUeberToolZug()
    {
        StoreFixture f;
        QVERIFY(f.store->open().value("ok").toBool());
        QSignalSpy done(f.store, &ConversationStore::writeCompleted);
        const QString cid = f.store->newUuid();
        const QString aFinal = f.store->newUuid();
        // Tool-Zug: user, assistant(leer), tool, assistant(final)
        f.store->appendMessage({{"conversationId", cid}, {"role", "user"}, {"content", "Wetter morgen?"}});
        f.store->appendMessage({{"conversationId", cid}, {"role", "assistant"}, {"content", ""}});
        f.store->appendMessage({{"conversationId", cid}, {"role", "tool"}, {"toolName", "web_search"}, {"content", "sonnig"}});
        f.store->appendMessage({{"id", aFinal}, {"conversationId", cid}, {"role", "assistant"}, {"content", "Morgen wird es sonnig."}});
        // zweite, UNbewertete Antwort in anderer Konversation
        const QString cid2 = f.store->newUuid();
        f.store->appendMessage({{"conversationId", cid2}, {"role", "user"}, {"content", "egal"}});
        f.store->appendMessage({{"conversationId", cid2}, {"role", "assistant"}, {"content", "egal2"}});
        QTRY_COMPARE(done.count(), 6);

        f.store->updateMessage(aFinal, {{"rating", 1}});
        QTRY_COMPARE(done.count(), 7);

        const QVariantList ex = f.store->goodExamples();
        QCOMPARE(ex.size(), 1);
        const QVariantMap e = ex.first().toMap();
        QCOMPARE(e.value("id").toString(), aFinal);
        QCOMPARE(e.value("answer").toString(), QString("Morgen wird es sonnig."));
        // Frage = letzte User-Zeile DAVOR, NICHT seq-1 (das wäre die tool-Zeile)
        QCOMPARE(e.value("question").toString(), QString("Wetter morgen?"));
        QCOMPARE(e.value("hasEmbedding").toBool(), false);
    }

    void questionForAnswer_letzteUserZeileDavor()
    {
        StoreFixture f;
        QVERIFY(f.store->open().value("ok").toBool());
        QSignalSpy done(f.store, &ConversationStore::writeCompleted);
        const QString cid = f.store->newUuid();
        const QString aid = f.store->newUuid();
        f.store->appendMessage({{"conversationId", cid}, {"role", "user"}, {"content", "erste frage"}});
        f.store->appendMessage({{"conversationId", cid}, {"role", "assistant"}, {"content", "erste antwort"}});
        f.store->appendMessage({{"conversationId", cid}, {"role", "user"}, {"content", "zweite frage"}});
        f.store->appendMessage({{"conversationId", cid}, {"role", "tool"}, {"toolName", "x"}, {"content", "t"}});
        f.store->appendMessage({{"id", aid}, {"conversationId", cid}, {"role", "assistant"}, {"content", "zweite antwort"}});
        QTRY_COMPARE(done.count(), 5);
        QCOMPARE(f.store->questionForAnswer(aid), QString("zweite frage"));
        QCOMPARE(f.store->questionForAnswer(QStringLiteral("gibt-es-nicht")), QString());
    }

    void knowledge_addLesen_roundTrip()
    {
        StoreFixture f;
        QVERIFY(f.store->open().value("ok").toBool());
        QSignalSpy done(f.store, &ConversationStore::writeCompleted);
        const QString id1 = f.store->newUuid();
        f.store->addKnowledge({{"id", id1}, {"kind", "link"}, {"title", "Fedora Downgrade"},
                               {"url", "https://example.org/k"}, {"content", "dnf downgrade kernel"}});
        QTRY_COMPARE(done.count(), 1);
        QTest::qWait(5);
        const QString id2 = f.store->newUuid();
        f.store->addKnowledge({{"id", id2}, {"kind", "note"}, {"title", "Piper-Pfad"},
                               {"url", ""}, {"content", "aurora/piper"}});
        QTRY_COMPARE(done.count(), 2);

        const QVariantList entries = f.store->knowledgeEntries();
        QCOMPARE(entries.size(), 2);
        const QVariantMap first = entries.at(0).toMap();   // created_at DESC -> zuletzt zuerst
        QCOMPARE(first.value("id").toString(), id2);
        QCOMPARE(first.value("kind").toString(), QString("note"));
        QCOMPARE(first.value("title").toString(), QString("Piper-Pfad"));
        QCOMPARE(first.value("hasEmbedding").toBool(), false);
        const QVariantMap second = entries.at(1).toMap();
        QCOMPARE(second.value("id").toString(), id1);
        QCOMPARE(second.value("url").toString(), QString("https://example.org/k"));
        QCOMPARE(second.value("content").toString(), QString("dnf downgrade kernel"));
    }

    void knowledge_updateNurWhitelist_undUpdatedAt()
    {
        StoreFixture f;
        QVERIFY(f.store->open().value("ok").toBool());
        QSignalSpy done(f.store, &ConversationStore::writeCompleted);
        const QString id = f.store->newUuid();
        f.store->addKnowledge({{"id", id}, {"kind", "fact"}, {"title", "alt"}, {"content", "alt-inhalt"}});
        QTRY_COMPARE(done.count(), 1);
        const QString createdAt = f.store->knowledgeEntries().at(0).toMap().value("createdAt").toString();
        QVERIFY(!createdAt.isEmpty());
        QTest::qWait(5);

        f.store->updateKnowledge(id, {{"kind", "note"}, {"title", "neu"}, {"content", "neu-inhalt"}});
        QTRY_COMPARE(done.count(), 2);
        const QVariantMap m = f.store->knowledgeEntries().at(0).toMap();
        QCOMPARE(m.value("kind").toString(), QString("note"));
        QCOMPARE(m.value("title").toString(), QString("neu"));
        QCOMPARE(m.value("content").toString(), QString("neu-inhalt"));
        QCOMPARE(m.value("createdAt").toString(), createdAt);           // unverändert
        QVERIFY(m.value("updatedAt").toString() > createdAt);           // gewachsen
    }

    void knowledge_embeddingSetzenUndLoeschen()
    {
        StoreFixture f;
        QVERIFY(f.store->open().value("ok").toBool());
        QSignalSpy done(f.store, &ConversationStore::writeCompleted);
        const QString id = f.store->newUuid();
        f.store->addKnowledge({{"id", id}, {"kind", "note"}, {"title", "t"}, {"content", "c"}});
        QTRY_COMPARE(done.count(), 1);
        QCOMPARE(f.store->knowledgeEntries().at(0).toMap().value("hasEmbedding").toBool(), false);

        f.store->setKnowledgeEmbedding(id, QVariantList{0.5, -0.25, 1.0}, QStringLiteral("nomic-embed-text"));
        QTRY_COMPARE(done.count(), 2);
        QCOMPARE(f.store->knowledgeEntries().at(0).toMap().value("hasEmbedding").toBool(), true);
        {
            QSqlDatabase db = QSqlDatabase::addDatabase("QSQLITE", "kembcheck");
            db.setDatabaseName(f.store->dbPath());
            QVERIFY(db.open());
            QSqlQuery q(db);
            QVERIFY(q.exec("SELECT embedding, embed_model FROM knowledge WHERE id='" + id + "'"));
            QVERIFY(q.next());
            QCOMPARE(q.value(0).toByteArray().size(), int(3 * sizeof(float)));
            QCOMPARE(q.value(1).toString(), QString("nomic-embed-text"));
            db.close();
        }
        QSqlDatabase::removeDatabase("kembcheck");

        f.store->setKnowledgeEmbedding(id, QVariantList{}, QString());   // Löschen
        QTRY_COMPARE(done.count(), 3);
        QCOMPARE(f.store->knowledgeEntries().at(0).toMap().value("hasEmbedding").toBool(), false);
    }

    void knowledge_deleteEntfernt()
    {
        StoreFixture f;
        QVERIFY(f.store->open().value("ok").toBool());
        QSignalSpy done(f.store, &ConversationStore::writeCompleted);
        const QString id = f.store->newUuid();
        f.store->addKnowledge({{"id", id}, {"kind", "link"}, {"title", "weg"}, {"url", "http://x"}});
        QTRY_COMPARE(done.count(), 1);
        QCOMPARE(f.store->knowledgeEntries().size(), 1);
        f.store->deleteKnowledge(id);
        QTRY_COMPARE(done.count(), 2);
        QCOMPARE(f.store->knowledgeEntries().size(), 0);
    }

    void knowledge_ungueltigeKind_meldetWriteFailed()
    {
        StoreFixture f;
        QVERIFY(f.store->open().value("ok").toBool());
        QSignalSpy failed(f.store, &ConversationStore::writeFailed);
        f.store->addKnowledge({{"id", f.store->newUuid()}, {"kind", "sonstiges"}, {"title", "x"}});
        QTRY_COMPARE(failed.count(), 1);   // CHECK (kind IN link/note/fact)
        QCOMPARE(failed.first().at(0).toString(), QString("addKnowledge"));
    }
};

QTEST_GUILESS_MAIN(TestConversationStore)
#include "test_conversationstore.moc"
