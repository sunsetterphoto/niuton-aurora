#include <QDir>
#include <QFileInfo>
#include <QSignalSpy>
#include <QSqlDatabase>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QtTest>

#include <limits>

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
            QCOMPARE(q.value(0).toInt(), 5);
            QVERIFY(q.exec("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"));
            QStringList tables;
            while (q.next()) tables << q.value(0).toString();
            QVERIFY(tables.contains("conversations"));
            QVERIFY(tables.contains("messages"));
            QVERIFY(tables.contains("tool_calls"));
            QVERIFY(tables.contains("knowledge"));
            QVERIFY(tables.contains("messages_fts"));   // Schema v5: Volltextindex
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

    // Scheibe C: vereint bewertete Antworten (strikt rating=1) + knowledge-Eintraege;
    // filtert Orphan-Vektor (rating=0 mit Vektor), embed_model-Mismatch und Treffer
    // unter der Schwelle; sortiert absteigend; topK-Cap.
    void searchSimilar_vereintQuellen_filtertUndSortiert()
    {
        StoreFixture f;
        QVERIFY(f.store->open().value("ok").toBool());
        QSignalSpy done(f.store, &ConversationStore::writeCompleted);
        const QString cid = f.store->newUuid();
        const QString aid = f.store->newUuid();    // bewertete Antwort (Treffer)
        const QString oid = f.store->newUuid();    // Orphan: Vektor, aber rating=0
        const QString fmid = f.store->newUuid();   // bewertet, aber anderes embed_model
        f.store->appendMessage({{"conversationId", cid}, {"role", "user"}, {"content", "Wie boote ich ins BIOS?"}});
        f.store->appendMessage({{"id", aid}, {"conversationId", cid}, {"role", "assistant"}, {"content", "F2 beim Start druecken."}});
        f.store->appendMessage({{"id", oid}, {"conversationId", cid}, {"role", "assistant"}, {"content", "verwaist"}});
        f.store->appendMessage({{"id", fmid}, {"conversationId", cid}, {"role", "assistant"}, {"content", "fremdes Modell"}});
        f.store->updateMessage(aid, {{"rating", 1}});
        f.store->updateMessage(fmid, {{"rating", 1}});
        f.store->setEmbedding(aid, QVariantList{1.0, 0.0, 0.0}, QStringLiteral("nomic-embed-text"));
        f.store->setEmbedding(oid, QVariantList{1.0, 0.0, 0.0}, QStringLiteral("nomic-embed-text"));
        f.store->setEmbedding(fmid, QVariantList{1.0, 0.0, 0.0}, QStringLiteral("anderes-modell"));
        const QString kid = f.store->newUuid();
        f.store->addKnowledge({{"id", kid}, {"kind", "fact"}, {"title", "BIOS-Taste"},
                               {"url", ""}, {"content", "F2 oder Entf beim POST"}});
        f.store->setKnowledgeEmbedding(kid, QVariantList{0.9, 0.1, 0.0}, QStringLiteral("nomic-embed-text"));
        const QString kid2 = f.store->newUuid();
        f.store->addKnowledge({{"id", kid2}, {"kind", "note"}, {"title", "unpassend"}, {"content", "orthogonal"}});
        f.store->setKnowledgeEmbedding(kid2, QVariantList{0.0, 1.0, 0.0}, QStringLiteral("nomic-embed-text"));
        QTRY_COMPARE(done.count(), 13);
        // 👎 mit Vektor (rating=-1) darf ebenfalls nicht treffen — wie der Orphan
        const QString nid = f.store->newUuid();
        f.store->appendMessage({{"id", nid}, {"conversationId", cid}, {"role", "assistant"}, {"content", "schlecht"}});
        f.store->updateMessage(nid, {{"rating", -1}});
        f.store->setEmbedding(nid, QVariantList{1.0, 0.0, 0.0}, QStringLiteral("nomic-embed-text"));
        QTRY_COMPARE(done.count(), 16);

        const QVariantList hits = f.store->searchSimilar(QVariantList{1.0, 0.0, 0.0},
            QStringLiteral("nomic-embed-text"), 3, 0.75);
        QCOMPARE(hits.size(), 2);   // aid + kid; oid/fmid/kid2/nid ausgeschlossen
        const QVariantMap h0 = hits.at(0).toMap();
        QCOMPARE(h0.value("source").toString(), QString("rated"));
        QCOMPARE(h0.value("id").toString(), aid);
        QVERIFY(h0.value("score").toDouble() > 0.99);
        QCOMPARE(h0.value("question").toString(), QString("Wie boote ich ins BIOS?"));
        QCOMPARE(h0.value("answer").toString(), QString("F2 beim Start druecken."));
        const QVariantMap h1 = hits.at(1).toMap();
        QCOMPARE(h1.value("source").toString(), QString("knowledge"));
        QCOMPARE(h1.value("id").toString(), kid);
        QCOMPARE(h1.value("kind").toString(), QString("fact"));
        QCOMPARE(h1.value("title").toString(), QString("BIOS-Taste"));
        QVERIFY(h1.value("score").toDouble() > 0.98);
        QVERIFY(h1.value("score").toDouble() < h0.value("score").toDouble());

        // topK-Cap: nur der beste Treffer
        QCOMPARE(f.store->searchSimilar(QVariantList{1.0, 0.0, 0.0},
            QStringLiteral("nomic-embed-text"), 1, 0.75).size(), 1);
        // sehr hohe Schwelle: nur die identische Antwort (1.0), nicht der Eintrag (~0.994)
        const QVariantList strict = f.store->searchSimilar(QVariantList{1.0, 0.0, 0.0},
            QStringLiteral("nomic-embed-text"), 3, 0.9999);
        QCOMPARE(strict.size(), 1);
        QCOMPARE(strict.first().toMap().value("id").toString(), aid);
    }

    void searchSimilar_randfaelle()
    {
        StoreFixture f;
        // vor open(): leer, kein Absturz
        QCOMPARE(f.store->searchSimilar(QVariantList{1.0}, QStringLiteral("m"), 3, 0.5).size(), 0);
        QVERIFY(f.store->open().value("ok").toBool());
        // leerer Query-Vektor und Nullnorm-Query liefern leer
        QCOMPARE(f.store->searchSimilar(QVariantList{}, QStringLiteral("m"), 3, 0.5).size(), 0);
        QCOMPARE(f.store->searchSimilar(QVariantList{0.0, 0.0, 0.0}, QStringLiteral("m"), 3, 0.5).size(), 0);

        QSignalSpy done(f.store, &ConversationStore::writeCompleted);
        const QString kid = f.store->newUuid();
        f.store->addKnowledge({{"id", kid}, {"kind", "note"}, {"title", "t"}, {"content", "c"}});
        f.store->setKnowledgeEmbedding(kid, QVariantList{1.0, 0.0, 0.0}, QStringLiteral("m"));
        QTRY_COMPARE(done.count(), 2);

        // Dimensions-Mismatch (2-dim Query vs. 3-dim Kandidat) -> uebersprungen
        QCOMPARE(f.store->searchSimilar(QVariantList{1.0, 0.0}, QStringLiteral("m"), 3, 0.5).size(), 0);
        // passende Dimension trifft
        QCOMPARE(f.store->searchSimilar(QVariantList{1.0, 0.0, 0.0}, QStringLiteral("m"), 3, 0.5).size(), 1);
        // topK=0 -> leer; topK>20 -> geclamped (kein Fehler, der eine Kandidat kommt)
        QCOMPARE(f.store->searchSimilar(QVariantList{1.0, 0.0, 0.0}, QStringLiteral("m"), 0, 0.5).size(), 0);
        QCOMPARE(f.store->searchSimilar(QVariantList{1.0, 0.0, 0.0}, QStringLiteral("m"), 100, 0.5).size(), 1);
        // NaN/negative Schwelle -> wie 0.0 (Treffer bleibt), nicht „alles" oder „nichts"
        QCOMPARE(f.store->searchSimilar(QVariantList{1.0, 0.0, 0.0}, QStringLiteral("m"), 3, -5.0).size(), 1);
        // NaN im Query-Vektor -> leer (kein NaN-Trefferhagel)
        QCOMPARE(f.store->searchSimilar(QVariantList{1.0, 0.0, std::numeric_limits<double>::quiet_NaN()},
            QStringLiteral("m"), 3, 0.5).size(), 0);
    }

    // Haertungswelle Fund 1: jede id-adressierte UPDATE/DELETE-Op auf eine
    // nicht existierende id muss writeFailed melden (bisher: 0 Zeilen
    // betroffen, aber writeCompleted — stiller No-op als "Erfolg").
    void updateDeleteOps_unbekannteId_meldenWriteFailed()
    {
        StoreFixture f;
        QVERIFY(f.store->open().value("ok").toBool());
        QSignalSpy done(f.store, &ConversationStore::writeCompleted);
        QSignalSpy failed(f.store, &ConversationStore::writeFailed);
        const QString cid = f.store->newUuid();
        const QString mid = f.store->newUuid();
        f.store->appendMessage({{"conversationId", cid}, {"id", mid},
                                {"role", "assistant"}, {"content", "x"}});
        const QString kid = f.store->newUuid();
        f.store->addKnowledge({{"id", kid}, {"kind", "note"}, {"title", "t"}, {"content", "c"}});
        QTRY_COMPARE(done.count(), 2);

        f.store->updateMessage("gibt-es-nicht", {{"content", "y"}});
        f.store->setEmbedding("gibt-es-nicht", QVariantList{1.0}, QStringLiteral("m"));
        f.store->deleteMessage("gibt-es-nicht");
        f.store->updateConversation("gibt-es-nicht", {{"extra", QVariantMap{{"a", 1}}}});
        f.store->updateToolCall("gibt-es-nicht", {{"status", "ok"}});
        f.store->updateKnowledge("gibt-es-nicht", {{"title", "z"}});
        f.store->setKnowledgeEmbedding("gibt-es-nicht", QVariantList{1.0}, QStringLiteral("m"));
        f.store->deleteKnowledge("gibt-es-nicht");
        QTRY_COMPARE(failed.count(), 8);
        QCOMPARE(done.count(), 2);   // kein falscher Erfolg dazwischen

        QStringList ops;
        for (const auto &sig : failed)
            ops << sig.at(0).toString();
        QVERIFY(ops.contains("updateMessage"));
        QVERIFY(ops.contains("setEmbedding"));
        QVERIFY(ops.contains("deleteMessage"));
        QVERIFY(ops.contains("updateConversation"));
        QVERIFY(ops.contains("updateToolCall"));
        QVERIFY(ops.contains("updateKnowledge"));
        QVERIFY(ops.contains("setKnowledgeEmbedding"));
        QVERIFY(ops.contains("deleteKnowledge"));
        // verstaendliche Meldung statt leerem SQL-Fehlertext
        QVERIFY(!failed.first().at(1).toString().isEmpty());
    }

    // Fund 1, Bind-Seite: eine null-QString-id wurde als SQL-NULL gebunden ->
    // WHERE id = NULL trifft SQL-seitig NIE eine Zeile -> stiller No-op bei
    // gemeldetem Erfolg. textOrEmpty + 0-Zeilen-Check machen daraus writeFailed.
    void updateDeleteOps_nullId_meldenWriteFailed()
    {
        StoreFixture f;
        QVERIFY(f.store->open().value("ok").toBool());
        QSignalSpy done(f.store, &ConversationStore::writeCompleted);
        QSignalSpy failed(f.store, &ConversationStore::writeFailed);
        f.store->updateMessage(QString(), {{"content", "y"}});
        f.store->deleteMessage(QString());
        f.store->setEmbedding(QString(), QVariantList{1.0}, QStringLiteral("m"));
        f.store->updateToolCall(QString(), {{"status", "ok"}});
        f.store->updateKnowledge(QString(), {{"title", "z"}});
        f.store->setKnowledgeEmbedding(QString(), QVariantList{1.0}, QStringLiteral("m"));
        f.store->deleteKnowledge(QString());
        QTRY_COMPARE(failed.count(), 7);
        QCOMPARE(done.count(), 0);
    }

    // Fund 1, Gegenprobe: die bewusst toleranten Ops duerfen NICHT härten —
    // touchConversation auf eine unbekannte id bleibt ein erfolgreicher No-op.
    void touchConversation_unbekannteId_bleibtTolerant()
    {
        StoreFixture f;
        QVERIFY(f.store->open().value("ok").toBool());
        QSignalSpy done(f.store, &ConversationStore::writeCompleted);
        QSignalSpy failed(f.store, &ConversationStore::writeFailed);
        f.store->touchConversation("gibt-es-nicht", QStringLiteral("Titel"));
        QTRY_COMPARE(done.count(), 1);
        QCOMPARE(failed.count(), 0);
    }

    // Haertungswelle Fund 2: SQL-Fehler in den synchronen Reads muessen als
    // readFailed sichtbar werden statt als stille leere Ergebnisse (corrupt/
    // locked DB war von "keine Daten" nicht unterscheidbar).
    void reads_beiFehlendemSchema_meldenReadFailed_stattStillerLeere()
    {
        StoreFixture f;
        QVERIFY(f.store->open().value("ok").toBool());
        // Tabellen unter der Lese-Verbindung wegnehmen -> jede Lese-Query scheitert
        {
            QSqlDatabase db = QSqlDatabase::addDatabase("QSQLITE", "sabotage");
            db.setDatabaseName(f.store->dbPath());
            QVERIFY(db.open());
            QSqlQuery q(db);
            QVERIFY(q.exec("PRAGMA foreign_keys=OFF"));
            QVERIFY(q.exec("DROP TABLE messages"));
            QVERIFY(q.exec("DROP TABLE conversations"));
            QVERIFY(q.exec("DROP TABLE knowledge"));
            db.close();
        }
        QSqlDatabase::removeDatabase("sabotage");

        QSignalSpy failed(f.store, &ConversationStore::readFailed);
        QCOMPARE(f.store->listConversations().size(), 0);
        QCOMPARE(f.store->messages("x").size(), 0);
        QCOMPARE(f.store->conversation("x").isEmpty(), true);
        QCOMPARE(f.store->goodExamples().size(), 0);
        QCOMPARE(f.store->knowledgeEntries().size(), 0);
        QCOMPARE(f.store->questionForAnswer("x"), QString());
        QCOMPARE(f.store->latestConversationId(), QString());
        QCOMPARE(f.store->searchSimilar(QVariantList{1.0}, QStringLiteral("m"), 3, 0.5).size(), 0);
        // Rueckgaben bleiben leer, aber jeder Fehler wird gemeldet:
        // 7 Reads + searchSimilar 2x (messages- UND knowledge-Query)
        QCOMPARE(failed.count(), 9);
        QCOMPARE(failed.first().at(0).toString(), QString("listConversations"));
        QVERIFY(!failed.first().at(1).toString().isEmpty());
    }

    // Konversations-Suche (Schema v5, FTS5): Titel-LIKE + Inhalts-MATCH,
    // Trigger-Sync bei insert/update/delete, Rollen-Filter, AND-Semantik.
    void suche_findetInhaltUndTitel_triggerSync()
    {
        StoreFixture f;
        QVERIFY(f.store->open().value("ok").toBool());
        QSignalSpy done(f.store, &ConversationStore::writeCompleted);
        const QString cid1 = f.store->newUuid();
        f.store->createConversation(cid1, "Fedora Kernel Update");
        const QString cid2 = f.store->newUuid();
        const QString aid = f.store->newUuid();
        f.store->appendMessage({{"conversationId", cid2}, {"role", "user"}, {"content", "Wie boote ich ins BIOS?"}});
        f.store->appendMessage({{"id", aid}, {"conversationId", cid2}, {"role", "assistant"}, {"content", "Druecke F2 oder Entf beim Start."}});
        f.store->appendMessage({{"conversationId", cid2}, {"role", "tool"}, {"toolName", "web_search"}, {"content", "Geheimwort Xylophon"}});
        QTRY_COMPARE(done.count(), 4);

        // Inhalts-Treffer mit Snippet
        QVariantList hits = f.store->searchConversations("BIOS", 10);
        QCOMPARE(hits.size(), 1);
        QCOMPARE(hits.first().toMap().value("id").toString(), cid2);
        QCOMPARE(hits.first().toMap().value("titleMatch").toBool(), false);
        QVERIFY(!hits.first().toMap().value("snippet").toString().isEmpty());

        // Titel-Treffer (Snippet leer, titleMatch true)
        hits = f.store->searchConversations("Kernel", 10);
        QCOMPARE(hits.size(), 1);
        QCOMPARE(hits.first().toMap().value("id").toString(), cid1);
        QCOMPARE(hits.first().toMap().value("titleMatch").toBool(), true);
        QCOMPARE(hits.first().toMap().value("snippet").toString(), QString());

        // AND-Semantik: beide Woerter muessen vorkommen
        QCOMPARE(f.store->searchConversations("BIOS Kernel", 10).size(), 0);

        // tool-Inhalt ist NICHT indexiert
        QCOMPARE(f.store->searchConversations("Xylophon", 10).size(), 0);

        // Update-Sync: neuer Inhalt trifft, alter nicht mehr
        f.store->updateMessage(aid, {{"content", "Neuer Inhalt Quatschwort"}});
        QTRY_COMPARE(done.count(), 5);
        QCOMPARE(f.store->searchConversations("Quatschwort", 10).size(), 1);
        QCOMPARE(f.store->searchConversations("Entf", 10).size(), 0);

        // Delete-Sync
        f.store->deleteMessage(aid);
        QTRY_COMPARE(done.count(), 6);
        QCOMPARE(f.store->searchConversations("Quatschwort", 10).size(), 0);
    }

    void suche_sonderzeichenUndLeer_undVorOpen()
    {
        StoreFixture f;
        // vor open(): leer, kein Absturz
        QCOMPARE(f.store->searchConversations("x", 10).size(), 0);
        QVERIFY(f.store->open().value("ok").toBool());
        QSignalSpy done(f.store, &ConversationStore::writeCompleted);
        const QString cid = f.store->newUuid();
        f.store->appendMessage({{"conversationId", cid}, {"role", "user"}, {"content", "prozent % und _ unterstrich"}});
        QTRY_COMPARE(done.count(), 1);

        // leer/whitespace -> leer
        QCOMPARE(f.store->searchConversations("", 10).size(), 0);
        QCOMPARE(f.store->searchConversations("   ", 10).size(), 0);
        // nur Satzzeichen -> leer (leere FTS-Phrasen werden vorweg verworfen)
        QCOMPARE(f.store->searchConversations("% ( ) \"", 10).size(), 0);
        // FTS-Operatoren als Woerter sind inert (gequotet) -> kein Fehler
        QCOMPARE(f.store->searchConversations("\" AND ( OR )", 10).size(), 0);
        // % im Wort (LIKE-Escape + FTS-Quote) trifft korrekt
        QCOMPARE(f.store->searchConversations("prozent %", 10).size(), 1);
    }

    // Migration 4 -> 5 mit Bestandsdaten: FTS-Objekte weg + user_version=4 ist
    // exakt eine v4-DB (v5 ist rein additiv) -> open() muss migrieren und
    // bestehende Inhalte per Backfill suchbar machen.
    void suche_migrationV4aufV5_mitBestandsdaten()
    {
        QTemporaryDir dir;
        qputenv("AURORA_DB_PATH", (dir.path() + "/test.db").toUtf8());
        QString dbPath;
        {
            ConversationStore store;
            QVERIFY(store.open().value("ok").toBool());
            dbPath = store.dbPath();
            QSignalSpy done(&store, &ConversationStore::writeCompleted);
            const QString cid = store.newUuid();
            store.appendMessage({{"conversationId", cid}, {"role", "user"}, {"content", "Rhabarberkompott"}});
            QTRY_COMPARE(done.count(), 1);
        }   // Dtor: Worker-Drain + Verbindungen zu

        {
            QSqlDatabase db = QSqlDatabase::addDatabase("QSQLITE", "downgrade");
            db.setDatabaseName(dbPath);
            QVERIFY(db.open());
            QSqlQuery q(db);
            QVERIFY(q.exec("DROP TRIGGER messages_fts_ai"));
            QVERIFY(q.exec("DROP TRIGGER messages_fts_ad"));
            QVERIFY(q.exec("DROP TRIGGER messages_fts_au"));
            QVERIFY(q.exec("DROP TABLE messages_fts"));
            QVERIFY(q.exec("PRAGMA user_version = 4"));
            db.close();
        }
        QSqlDatabase::removeDatabase("downgrade");

        {
            ConversationStore store;
            QVERIFY(store.open().value("ok").toBool());
            const QVariantList hits = store.searchConversations("Rhabarber", 10);
            QCOMPARE(hits.size(), 1);
            QCOMPARE(hits.first().toMap().value("titleMatch").toBool(), false);
        }
        qunsetenv("AURORA_DB_PATH");
    }
};

QTEST_GUILESS_MAIN(TestConversationStore)
#include "test_conversationstore.moc"
