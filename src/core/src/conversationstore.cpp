#include "conversationstore.h"

#include <QCoreApplication>
#include <QDir>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>
#include <QSet>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>
#include <QStandardPaths>
#include <QUuid>
#include <QVector>

#include <algorithm>
#include <cmath>
#include <cstring>

namespace {

QString isoNow()
{
    return QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs);
}

QString resolvedDbPath()
{
    const QByteArray override = qgetenv("AURORA_DB_PATH");
    if (!override.isEmpty())
        return QString::fromUtf8(override);
    const QString base = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation)
        + QLatin1String("/aurora");
    QDir().mkpath(base);
    return base + QLatin1String("/aurora.db");
}

bool applyPragmas(QSqlDatabase &db, QString *error)
{
    QSqlQuery q(db);
    const QStringList pragmas = {
        QStringLiteral("PRAGMA journal_mode=WAL"),
        QStringLiteral("PRAGMA synchronous=NORMAL"),
        QStringLiteral("PRAGMA foreign_keys=ON"),
        QStringLiteral("PRAGMA busy_timeout=500"),
    };
    for (const QString &p : pragmas) {
        if (!q.exec(p)) {
            if (error) *error = q.lastError().text();
            return false;
        }
    }
    return true;
}

// QVariantMap::value(key, QString()).toString() liefert bei fehlendem Key eine
// NULL-QString (QString::isNull() == true, nicht bloß leer) — der QSQLITE-Treiber
// bindet eine solche NULL-QString als SQL-NULL statt als leeren Text, was die
// NOT-NULL-DEFAULT-''-Spalten (turn_id, thinking, tool_name, model, backend,
// media_path, media_type, ...) verletzt. Abwehr: NULL-Strings auf einen
// definitiv nicht-NULL leeren String normalisieren, bevor gebunden wird.
QString textOrEmpty(const QVariant &v)
{
    const QString s = v.toString();
    return s.isNull() ? QStringLiteral("") : s;
}

QString extraToJson(const QVariant &extra)
{
    if (extra.canConvert<QVariantMap>() && !extra.toMap().isEmpty())
        return QString::fromUtf8(
            QJsonDocument(QJsonObject::fromVariantMap(extra.toMap())).toJson(QJsonDocument::Compact));
    const QString s = extra.toString();
    return s.isEmpty() ? QStringLiteral("{}") : s;
}

QVariantMap jsonToMap(const QString &json)
{
    const QJsonDocument doc = QJsonDocument::fromJson(json.toUtf8());
    return doc.isObject() ? doc.object().toVariantMap() : QVariantMap();
}

// BLOB (float32, wie von setEmbedding/setKnowledgeEmbedding gepackt) -> QVector<float>.
// Leerer Vektor bei ungültiger Größe (kein Vielfaches von sizeof(float)).
QVector<float> unpackFloats(const QByteArray &blob)
{
    QVector<float> v;
    if (blob.isEmpty() || blob.size() % int(sizeof(float)) != 0)
        return v;
    v.resize(blob.size() / int(sizeof(float)));
    std::memcpy(v.data(), blob.constData(), size_t(blob.size()));
    return v;
}

// Cosinus-Ähnlichkeit Query x Kandidaten-BLOB. Rückgabe -2.0 (ungültig) bei
// Dimensions-Mismatch oder Nullnorm — unterhalb jeder denkbaren minScore-Schwelle.
double cosineScore(const QVector<float> &q, double qNorm, const QByteArray &blob)
{
    const QVector<float> c = unpackFloats(blob);
    if (c.isEmpty() || c.size() != q.size())
        return -2.0;
    double dot = 0.0, cNorm = 0.0;
    for (int i = 0; i < q.size(); ++i) {
        dot += double(q[i]) * double(c[i]);
        cNorm += double(c[i]) * double(c[i]);
    }
    if (cNorm <= 0.0)
        return -2.0;
    return dot / (qNorm * std::sqrt(cNorm));
}

// Schlichter Snippet-Bau für die Konversations-Suche: Fenster um den ersten
// (frühesten) Wort-Treffer, Zeilenumbrüche geglättet, Ellipsen an den Schnitten.
// (snippet() von FTS5 scheidet hier aus: auf External-Content-Tabellen wirft es
// im JOIN-Kontext "unable to use function snippet in the requested context".)
QString makeSnippet(const QString &content, const QStringList &words)
{
    const QString flat = QString(content).replace(QLatin1Char('\n'), QLatin1Char(' '));
    int pos = -1;
    for (const QString &w : words) {
        const int p = flat.indexOf(w, 0, Qt::CaseInsensitive);
        if (p >= 0 && (pos < 0 || p < pos))
            pos = p;
    }
    const int window = 120;
    if (pos < 0)
        return flat.left(window) + (flat.size() > window ? QStringLiteral("…") : QString());
    const int start = qMax(0, pos - 30);
    QString s = (start > 0 ? QStringLiteral("…") : QString()) + flat.mid(start, window);
    if (start + window < flat.size())
        s += QStringLiteral("…");
    return s;
}

// Migrationsschritte, je in einer Transaktion (PRAGMA user_version).
// BEGIN IMMEDIATE + Versions-Check IN der Transaktion: zwei Prozesse, die
// gleichzeitig zum ersten Mal öffnen (Widget + spätere App), serialisieren
// sich am Schreib-Lock; der zweite sieht dann die bereits migrierte Version und tut nichts.
bool migrate(QSqlDatabase &db, QString *error)
{
    QSqlQuery q(db);
    if (!q.exec(QStringLiteral("BEGIN IMMEDIATE"))) {
        if (error) *error = q.lastError().text();
        return false;
    }
    if (!q.exec(QStringLiteral("PRAGMA user_version")) || !q.next()) {
        if (error) *error = q.lastError().text();
        q.exec(QStringLiteral("ROLLBACK"));
        return false;
    }
    const int version = q.value(0).toInt();
    if (version > 5) {
        if (error) *error = QStringLiteral("Datenbank hat Schema-Version %1 — diese Aurora-Version kennt nur 5 (DB von neuerer Version?)").arg(version);
        q.exec(QStringLiteral("ROLLBACK"));
        return false;
    }

    // Migration 0 -> 1: komplettes Schema v1 (DDL exakt aus der Spec, Abschnitt 4)
    if (version < 1) {
    const QStringList ddl = {
        QStringLiteral(
            "CREATE TABLE conversations ("
            " id          TEXT PRIMARY KEY,"
            " title       TEXT NOT NULL DEFAULT '',"
            " created_at  TEXT NOT NULL,"
            " updated_at  TEXT NOT NULL,"
            " archived    INTEGER NOT NULL DEFAULT 0,"
            " extra       TEXT NOT NULL DEFAULT '{}')"),
        QStringLiteral("CREATE INDEX idx_conv_updated ON conversations(updated_at DESC)"),
        QStringLiteral(
            "CREATE TABLE messages ("
            " id              TEXT PRIMARY KEY,"
            " conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,"
            " seq             INTEGER NOT NULL,"
            " turn_id         TEXT NOT NULL DEFAULT '',"
            " role            TEXT NOT NULL CHECK (role IN ('user','assistant','tool')),"
            " content         TEXT NOT NULL DEFAULT '',"
            " thinking        TEXT NOT NULL DEFAULT '',"
            " tool_name       TEXT NOT NULL DEFAULT '',"
            " model           TEXT NOT NULL DEFAULT '',"
            " backend         TEXT NOT NULL DEFAULT '',"
            " status          TEXT NOT NULL DEFAULT 'final' CHECK (status IN ('final','aborted','error')),"
            " created_at      TEXT NOT NULL,"
            " media_path      TEXT NOT NULL DEFAULT '',"
            " media_type      TEXT NOT NULL DEFAULT '',"
            " extra           TEXT NOT NULL DEFAULT '{}',"
            " UNIQUE (conversation_id, seq))"),
        QStringLiteral(
            "CREATE TABLE tool_calls ("
            " id                TEXT PRIMARY KEY,"
            " message_id        TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,"
            " call_index        INTEGER NOT NULL,"
            " tool_name         TEXT NOT NULL,"
            " arguments         TEXT NOT NULL DEFAULT '{}',"
            " status            TEXT NOT NULL DEFAULT 'pending'"
            "  CHECK (status IN ('pending','running','ok','error','denied','aborted')),"
            " started_at        TEXT,"
            " finished_at       TEXT,"
            " result_message_id TEXT,"
            " extra             TEXT NOT NULL DEFAULT '{}')"),
        QStringLiteral("CREATE INDEX idx_toolcalls_msg ON tool_calls(message_id, call_index)"),
        QStringLiteral("PRAGMA user_version = 1"),
    };
    for (const QString &stmt : ddl) {
        if (!q.exec(stmt)) {
            if (error) *error = q.lastError().text();
            q.exec(QStringLiteral("ROLLBACK"));
            return false;
        }
    }
    }  // Ende if (version < 1)

    // Migration 1 -> 2: rating-Spalte (Wissensbasis Scheibe A). ADD COLUMN mit
    // DEFAULT 0 ist billig und rückwärtskompatibel; alte Zeilen erhalten 0.
    if (version < 2) {
        const QStringList ddlV2 = {
            QStringLiteral("ALTER TABLE messages ADD COLUMN rating INTEGER NOT NULL DEFAULT 0"),
            QStringLiteral("PRAGMA user_version = 2"),
        };
        for (const QString &stmt : ddlV2) {
            if (!q.exec(stmt)) {
                if (error) *error = q.lastError().text();
                q.exec(QStringLiteral("ROLLBACK"));
                return false;
            }
        }
    }

    // Migration 2 -> 3: embedding-BLOB + embed_model (Wissensbasis Scheibe B).
    // Vektor der Nutzerfrage, gesetzt beim 👍 der Assistant-Zeile; NULLbar (alte/
    // ungeratete Zeilen haben keinen). idx_msg_rating beschleunigt goodExamples().
    if (version < 3) {
        const QStringList ddlV3 = {
            QStringLiteral("ALTER TABLE messages ADD COLUMN embedding BLOB"),
            QStringLiteral("ALTER TABLE messages ADD COLUMN embed_model TEXT NOT NULL DEFAULT ''"),
            QStringLiteral("CREATE INDEX IF NOT EXISTS idx_msg_rating ON messages(rating) WHERE rating <> 0"),
            QStringLiteral("PRAGMA user_version = 3"),
        };
        for (const QString &stmt : ddlV3) {
            if (!q.exec(stmt)) {
                if (error) *error = q.lastError().text();
                q.exec(QStringLiteral("ROLLBACK"));
                return false;
            }
        }
    }

    // Migration 3 -> 4: knowledge-Tabelle (manuelle Wissens-Einträge). Freistehend
    // (keine conversation_id), einbettbar (embedding-BLOB wie messages), Art-Enum
    // link/note/fact. Der RAG-Abruf über diese Einträge kommt in der Folge-Scheibe.
    if (version < 4) {
        const QStringList ddlV4 = {
            QStringLiteral(
                "CREATE TABLE knowledge ("
                " id          TEXT PRIMARY KEY,"
                " kind        TEXT NOT NULL CHECK (kind IN ('link','note','fact')),"
                " title       TEXT NOT NULL DEFAULT '',"
                " url         TEXT NOT NULL DEFAULT '',"
                " content     TEXT NOT NULL DEFAULT '',"
                " embedding   BLOB,"
                " embed_model TEXT NOT NULL DEFAULT '',"
                " created_at  TEXT NOT NULL,"
                " updated_at  TEXT NOT NULL,"
                " extra       TEXT NOT NULL DEFAULT '{}')"),
            QStringLiteral("CREATE INDEX idx_knowledge_created ON knowledge(created_at DESC)"),
            QStringLiteral("PRAGMA user_version = 4"),
        };
        for (const QString &stmt : ddlV4) {
            if (!q.exec(stmt)) {
                if (error) *error = q.lastError().text();
                q.exec(QStringLiteral("ROLLBACK"));
                return false;
            }
        }
    }

    // Migration 4 -> 5: FTS5-Volltextindex über user/assistant-Inhalte
    // (Konversations-Suche). External-Content-Tabelle auf messages.rowid +
    // drei Sync-Trigger (alle Writes laufen über diesen Store, der Index folgt
    // so automatisch) + einmaliger Backfill. Tool-Inhalte bleiben bewusst
    // außen vor (würden Index und Treffer verwässern).
    if (version < 5) {
        const QStringList ddlV5 = {
            QStringLiteral(
                "CREATE VIRTUAL TABLE messages_fts USING fts5("
                " content, content='messages', content_rowid='rowid')"),
            QStringLiteral(
                "CREATE TRIGGER messages_fts_ai AFTER INSERT ON messages"
                " WHEN new.role IN ('user','assistant') BEGIN"
                " INSERT INTO messages_fts(rowid, content) VALUES (new.rowid, new.content); END"),
            QStringLiteral(
                "CREATE TRIGGER messages_fts_ad AFTER DELETE ON messages"
                " WHEN old.role IN ('user','assistant') BEGIN"
                " INSERT INTO messages_fts(messages_fts, rowid, content)"
                " VALUES('delete', old.rowid, old.content); END"),
            QStringLiteral(
                "CREATE TRIGGER messages_fts_au AFTER UPDATE ON messages"
                " WHEN old.role IN ('user','assistant') BEGIN"
                " INSERT INTO messages_fts(messages_fts, rowid, content)"
                " VALUES('delete', old.rowid, old.content);"
                " INSERT INTO messages_fts(rowid, content) VALUES (new.rowid, new.content); END"),
            QStringLiteral(
                "INSERT INTO messages_fts(rowid, content)"
                " SELECT rowid, content FROM messages WHERE role IN ('user','assistant')"),
            QStringLiteral("PRAGMA user_version = 5"),
        };
        for (const QString &stmt : ddlV5) {
            if (!q.exec(stmt)) {
                if (error) *error = q.lastError().text();
                q.exec(QStringLiteral("ROLLBACK"));
                return false;
            }
        }
    }

    if (!q.exec(QStringLiteral("COMMIT"))) {
        if (error) *error = q.lastError().text();
        return false;
    }
    return true;
}

// Task 2: freistehender Helfer im anonymen Namespace, beim open() aufgerufen.
// Task 3 verdrahtet zusätzlich die Q_INVOKABLE-Variante (sweepNonFinal()).
bool sweepOnOpen(QSqlDatabase &db, QString *error)
{
    QSqlQuery q(db);
    if (!q.exec(QStringLiteral(
            "UPDATE tool_calls SET status='aborted' WHERE status IN ('pending','running')"))) {
        if (error) *error = q.lastError().text();
        return false;
    }
    return true;
}

} // namespace

// ---------------------------------------------------------------------------
// StoreWorker: lebt im Worker-Thread, besitzt die Schreib-Verbindung.
// ---------------------------------------------------------------------------
class StoreWorker : public QObject
{
    Q_OBJECT

public:
    explicit StoreWorker(const QString &dbPath)
        : m_dbPath(dbPath)
        // Verbindungsname pro Instanz eindeutig: QSql-Verbindungsnamen sind
        // prozessglobal — zwei Store-Instanzen (Tests!) dürfen sich nicht die
        // Verbindung mit dem jeweils anderen dbPath teilen.
        , m_connName(QStringLiteral("aurora_write_%1").arg(reinterpret_cast<quintptr>(this)))
    {
    }

    ~StoreWorker() override
    {
        // Läuft im Worker-Thread (deleteLater nach QThread::finished wird beim
        // Thread-Cleanup abgearbeitet) — Verbindung im besitzenden Thread schließen.
        if (QSqlDatabase::contains(m_connName)) {
            QSqlDatabase::database(m_connName).close();
            QSqlDatabase::removeDatabase(m_connName);
        }
    }

public Q_SLOTS:
    void exec(const QString &op, const QVariantMap &args)
    {
        QString error;
        if (!ensureDb(&error)) {
            Q_EMIT failed(op, error);
            return;
        }
        QSqlDatabase db = QSqlDatabase::database(m_connName);
        QSqlQuery q(db);
        // BEGIN IMMEDIATE: Schreib-Lock sofort nehmen (Spec) — busy_timeout 500 ms greift
        if (!q.exec(QStringLiteral("BEGIN IMMEDIATE"))) {
            Q_EMIT failed(op, q.lastError().text());
            return;
        }
        const bool ok = execOp(db, op, args, &error);
        if (ok && q.exec(QStringLiteral("COMMIT"))) {
            // Dateisystem-Seiteneffekte (deleteConversation: Attachment-Ordner)
            // erst NACH erfolgreichem COMMIT und VOR completed(): ein ROLLBACK
            // stellt DB-Zeilen wieder her, gelöschte Dateien nicht.
            if (!m_pendingDirDelete.isEmpty()) {
                QDir d(m_pendingDirDelete);
                if (d.exists())
                    d.removeRecursively();
                m_pendingDirDelete.clear();
            }
            Q_EMIT completed(op);
        } else {
            if (error.isEmpty()) error = q.lastError().text();
            q.exec(QStringLiteral("ROLLBACK"));
            m_pendingDirDelete.clear();   // ROLLBACK: DB-Zeilen bleiben, also nichts löschen
            Q_EMIT failed(op, error);
        }
    }

Q_SIGNALS:
    void completed(const QString &op);
    void failed(const QString &op, const QString &error);

private:
    bool ensureDb(QString *error)
    {
        if (QSqlDatabase::contains(m_connName))
            return true;
        QSqlDatabase db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), m_connName);
        db.setDatabaseName(m_dbPath);
        if (!db.open()) {
            if (error) *error = db.lastError().text();
            return false;
        }
        return applyPragmas(db, error);
    }

    bool execOp(QSqlDatabase &db, const QString &op, const QVariantMap &a, QString *error);

    QString m_dbPath;
    const QString m_connName;
    // Von execOp (deleteConversation) vorgemerkter Attachment-Ordner; wird in
    // exec() erst nach erfolgreichem COMMIT gelöscht, bei ROLLBACK verworfen.
    QString m_pendingDirDelete;
};

bool StoreWorker::execOp(QSqlDatabase &db, const QString &op, const QVariantMap &a, QString *error)
{
    QSqlQuery q(db);
    const QString now = isoNow();

    auto fail = [&](const QSqlQuery &fq) {
        if (error) *error = fq.lastError().text();
        return false;
    };

    // id-adressierte UPDATE/DELETE-Ops: 0 betroffene Zeilen heißt, die :id traf
    // nichts — bisher ein stiller No-op bei gemeldetem writeCompleted. Als Fehler
    // melden, damit writeFailed ihn sichtbar macht. Bewusst tolerante Ops
    // (createConversation, appendMessage, touchConversation, deleteConversation,
    // sweepNonFinal) nutzen diesen Pfad NICHT.
    auto execIdOp = [&]() -> bool {
        if (!q.exec())
            return fail(q);
        if (q.numRowsAffected() == 0) {
            if (error) *error = QStringLiteral("Keine Zeile mit dieser id (0 Zeilen betroffen)");
            return false;
        }
        return true;
    };

    if (op == QLatin1String("createConversation")) {
        q.prepare(QStringLiteral(
            "INSERT OR IGNORE INTO conversations(id, title, created_at, updated_at) "
            "VALUES(:id, :title, :now, :now)"));
        // textOrEmpty: null-QString-Titel (z.B. QString() aus QML) würde sonst als
        // SQL-NULL gebunden -> "title TEXT NOT NULL DEFAULT ''" verletzt, und
        // INSERT OR IGNORE würde die Zeile dann STILL überspringen (kein Fehler,
        // aber auch keine Konversation) statt mit '' zu persistieren.
        q.bindValue(QStringLiteral(":id"), textOrEmpty(a.value(QStringLiteral("id"))));
        q.bindValue(QStringLiteral(":title"), textOrEmpty(a.value(QStringLiteral("title"))));
        q.bindValue(QStringLiteral(":now"), now);
        return q.exec() ? true : fail(q);
    }

    if (op == QLatin1String("appendMessage")) {
        const QString cid = a.value(QStringLiteral("conversationId")).toString();
        if (cid.isEmpty()) {
            if (error) *error = QStringLiteral("conversationId fehlt");
            return false;
        }
        // Lazy Creation: Konversationszeile sicherstellen
        q.prepare(QStringLiteral(
            "INSERT OR IGNORE INTO conversations(id, title, created_at, updated_at) "
            "VALUES(:id, '', :now, :now)"));
        q.bindValue(QStringLiteral(":id"), cid);
        q.bindValue(QStringLiteral(":now"), now);
        if (!q.exec()) return fail(q);

        // seq im Worker vergeben (BEGIN IMMEDIATE serialisiert Schreiber)
        q.prepare(QStringLiteral(
            "SELECT COALESCE(MAX(seq) + 1, 0) FROM messages WHERE conversation_id = :cid"));
        q.bindValue(QStringLiteral(":cid"), cid);
        if (!q.exec() || !q.next()) return fail(q);
        const int seq = q.value(0).toInt();

        q.prepare(QStringLiteral(
            "INSERT INTO messages(id, conversation_id, seq, turn_id, role, content, thinking,"
            " tool_name, model, backend, status, created_at, media_path, media_type, extra) "
            "VALUES(:id, :cid, :seq, :turn, :role, :content, :thinking,"
            " :tool, :model, :backend, :status, :created, :mpath, :mtype, :extra)"));
        const QString mid = a.value(QStringLiteral("id")).toString();
        q.bindValue(QStringLiteral(":id"),
                    mid.isEmpty() ? QUuid::createUuid().toString(QUuid::WithoutBraces) : mid);
        q.bindValue(QStringLiteral(":cid"), cid);
        q.bindValue(QStringLiteral(":seq"), seq);
        q.bindValue(QStringLiteral(":turn"), textOrEmpty(a.value(QStringLiteral("turnId"))));
        q.bindValue(QStringLiteral(":role"), a.value(QStringLiteral("role")).toString());
        q.bindValue(QStringLiteral(":content"), textOrEmpty(a.value(QStringLiteral("content"))));
        q.bindValue(QStringLiteral(":thinking"), textOrEmpty(a.value(QStringLiteral("thinking"))));
        q.bindValue(QStringLiteral(":tool"), textOrEmpty(a.value(QStringLiteral("toolName"))));
        q.bindValue(QStringLiteral(":model"), textOrEmpty(a.value(QStringLiteral("model"))));
        q.bindValue(QStringLiteral(":backend"), textOrEmpty(a.value(QStringLiteral("backend"))));
        q.bindValue(QStringLiteral(":status"),
                    a.value(QStringLiteral("status"), QStringLiteral("final")).toString());
        q.bindValue(QStringLiteral(":created"), now);
        q.bindValue(QStringLiteral(":mpath"), textOrEmpty(a.value(QStringLiteral("mediaPath"))));
        q.bindValue(QStringLiteral(":mtype"), textOrEmpty(a.value(QStringLiteral("mediaType"))));
        q.bindValue(QStringLiteral(":extra"), extraToJson(a.value(QStringLiteral("extra"))));
        if (!q.exec()) return fail(q);

        // Aktivität: Sidebar sortiert auf updated_at
        q.prepare(QStringLiteral("UPDATE conversations SET updated_at = :now WHERE id = :cid"));
        q.bindValue(QStringLiteral(":now"), now);
        q.bindValue(QStringLiteral(":cid"), cid);
        return q.exec() ? true : fail(q);
    }

    if (op == QLatin1String("touchConversation")) {
        const QString title = a.value(QStringLiteral("title")).toString();
        if (title.isEmpty()) {
            q.prepare(QStringLiteral("UPDATE conversations SET updated_at = :now WHERE id = :id"));
        } else {
            q.prepare(QStringLiteral(
                "UPDATE conversations SET title = :title, updated_at = :now WHERE id = :id"));
            q.bindValue(QStringLiteral(":title"), title);
        }
        q.bindValue(QStringLiteral(":now"), now);
        // textOrEmpty auch hier: eine null-QString-id würde als SQL-NULL gebunden
        // und WHERE id = NULL trifft (SQL-Semantik) nie eine Zeile — stiller No-op
        // statt eines Fehlers. textOrEmpty macht daraus einen definierten Leerstring,
        // der ebenso konsequent keine Zeile trifft, aber ohne die NULL-Fallstricke.
        q.bindValue(QStringLiteral(":id"), textOrEmpty(a.value(QStringLiteral("id"))));
        return q.exec() ? true : fail(q);
    }

    if (op == QLatin1String("updateConversation")) {
        // Nur extra ist über diesen Weg änderbar (Whitelist).
        if (!a.contains(QStringLiteral("extra"))) {
            if (error) *error = QStringLiteral("updateConversation: kein erlaubtes Feld");
            return false;
        }
        q.prepare(QStringLiteral("UPDATE conversations SET extra = :extra WHERE id = :id"));
        q.bindValue(QStringLiteral(":extra"), extraToJson(a.value(QStringLiteral("extra"))));
        q.bindValue(QStringLiteral(":id"), textOrEmpty(a.value(QStringLiteral("id"))));
        return execIdOp();
    }

    if (op == QLatin1String("updateMessage")) {
        // Whitelist: nur content/thinking/status/extra/rating sind änderbar
        static const QStringList erlaubt = {QStringLiteral("content"), QStringLiteral("thinking"),
                                            QStringLiteral("status"), QStringLiteral("extra"),
                                            QStringLiteral("rating")};
        QStringList sets;
        for (const QString &k : erlaubt) {
            if (a.contains(k))
                sets << QString(k + QStringLiteral(" = :") + k);
        }
        if (sets.isEmpty()) {
            if (error) *error = QStringLiteral("updateMessage: keine erlaubten Felder");
            return false;
        }
        q.prepare(QStringLiteral("UPDATE messages SET ") + sets.join(QStringLiteral(", "))
                  + QStringLiteral(" WHERE id = :id"));
        for (const QString &k : erlaubt) {
            if (!a.contains(k)) continue;
            if (k == QLatin1String("extra"))
                q.bindValue(QStringLiteral(":extra"), extraToJson(a.value(k)));
            else if (k == QLatin1String("rating"))
                // rating ist INTEGER — als Ganzzahl binden, nicht als Text.
                q.bindValue(QStringLiteral(":rating"), a.value(k).toInt());
            else
                // textOrEmpty: content/thinking/status sind NOT-NULL-DEFAULT-''-Spalten;
                // ohne diese Absicherung würde eine null-QString den Write scheitern lassen.
                q.bindValue(QString(QStringLiteral(":") + k), textOrEmpty(a.value(k)));
        }
        q.bindValue(QStringLiteral(":id"), textOrEmpty(a.value(QStringLiteral("id"))));
        return execIdOp();
    }

    if (op == QLatin1String("setEmbedding")) {
        const QVariantList vec = a.value(QStringLiteral("vec")).toList();
        q.prepare(QStringLiteral(
            "UPDATE messages SET embedding = :emb, embed_model = :model WHERE id = :id"));
        if (vec.isEmpty()) {
            // Löschen: getypte NULL statt leerem Blob (embed_model bleibt NOT NULL '')
            q.bindValue(QStringLiteral(":emb"), QVariant(QMetaType(QMetaType::QByteArray)));
            q.bindValue(QStringLiteral(":model"), QStringLiteral(""));
        } else {
            QByteArray blob;
            blob.resize(int(vec.size() * sizeof(float)));
            float *fp = reinterpret_cast<float *>(blob.data());
            for (int i = 0; i < vec.size(); ++i)
                fp[i] = static_cast<float>(vec.at(i).toDouble());
            q.bindValue(QStringLiteral(":emb"), blob);
            q.bindValue(QStringLiteral(":model"), textOrEmpty(a.value(QStringLiteral("model"))));
        }
        q.bindValue(QStringLiteral(":id"), textOrEmpty(a.value(QStringLiteral("id"))));
        return execIdOp();
    }

    if (op == QLatin1String("addKnowledge")) {
        // kind wird per CHECK erzwungen; ein ungültiger Wert scheitert am INSERT
        // (wie appendMessage bei ungültiger role) -> writeFailed.
        q.prepare(QStringLiteral(
            "INSERT INTO knowledge(id, kind, title, url, content, created_at, updated_at) "
            "VALUES(:id, :kind, :title, :url, :content, :now, :now)"));
        q.bindValue(QStringLiteral(":id"), textOrEmpty(a.value(QStringLiteral("id"))));
        q.bindValue(QStringLiteral(":kind"), a.value(QStringLiteral("kind")).toString());
        q.bindValue(QStringLiteral(":title"), textOrEmpty(a.value(QStringLiteral("title"))));
        q.bindValue(QStringLiteral(":url"), textOrEmpty(a.value(QStringLiteral("url"))));
        q.bindValue(QStringLiteral(":content"), textOrEmpty(a.value(QStringLiteral("content"))));
        q.bindValue(QStringLiteral(":now"), now);
        return q.exec() ? true : fail(q);
    }

    if (op == QLatin1String("updateKnowledge")) {
        // Whitelist: nur kind/title/url/content; updated_at wird immer aktualisiert.
        static const QStringList erlaubt = {QStringLiteral("kind"), QStringLiteral("title"),
                                            QStringLiteral("url"), QStringLiteral("content")};
        QStringList sets;
        for (const QString &k : erlaubt) {
            if (a.contains(k))
                sets << QString(k + QStringLiteral(" = :") + k);
        }
        if (sets.isEmpty()) {
            if (error) *error = QStringLiteral("updateKnowledge: keine erlaubten Felder");
            return false;
        }
        sets << QStringLiteral("updated_at = :now");
        q.prepare(QStringLiteral("UPDATE knowledge SET ") + sets.join(QStringLiteral(", "))
                  + QStringLiteral(" WHERE id = :id"));
        for (const QString &k : erlaubt) {
            if (!a.contains(k)) continue;
            if (k == QLatin1String("kind"))
                q.bindValue(QStringLiteral(":kind"), a.value(k).toString());
            else
                q.bindValue(QString(QStringLiteral(":") + k), textOrEmpty(a.value(k)));
        }
        q.bindValue(QStringLiteral(":now"), now);
        q.bindValue(QStringLiteral(":id"), textOrEmpty(a.value(QStringLiteral("id"))));
        return execIdOp();
    }

    if (op == QLatin1String("setKnowledgeEmbedding")) {
        const QVariantList vec = a.value(QStringLiteral("vec")).toList();
        q.prepare(QStringLiteral(
            "UPDATE knowledge SET embedding = :emb, embed_model = :model WHERE id = :id"));
        if (vec.isEmpty()) {
            q.bindValue(QStringLiteral(":emb"), QVariant(QMetaType(QMetaType::QByteArray)));
            q.bindValue(QStringLiteral(":model"), QStringLiteral(""));
        } else {
            QByteArray blob;
            blob.resize(int(vec.size() * sizeof(float)));
            float *fp = reinterpret_cast<float *>(blob.data());
            for (int i = 0; i < vec.size(); ++i)
                fp[i] = static_cast<float>(vec.at(i).toDouble());
            q.bindValue(QStringLiteral(":emb"), blob);
            q.bindValue(QStringLiteral(":model"), textOrEmpty(a.value(QStringLiteral("model"))));
        }
        q.bindValue(QStringLiteral(":id"), textOrEmpty(a.value(QStringLiteral("id"))));
        return execIdOp();
    }

    if (op == QLatin1String("deleteKnowledge")) {
        q.prepare(QStringLiteral("DELETE FROM knowledge WHERE id = :id"));
        q.bindValue(QStringLiteral(":id"), textOrEmpty(a.value(QStringLiteral("id"))));
        return execIdOp();
    }

    if (op == QLatin1String("deleteMessage")) {
        q.prepare(QStringLiteral("DELETE FROM messages WHERE id = :id"));
        q.bindValue(QStringLiteral(":id"), textOrEmpty(a.value(QStringLiteral("id"))));
        return execIdOp();
    }

    if (op == QLatin1String("deleteConversation")) {
        const QString cid = a.value(QStringLiteral("id")).toString();
        if (cid.isEmpty()) {
            if (error) *error = QStringLiteral("deleteConversation: leere Konversations-ID");
            return false;
        }
        q.prepare(QStringLiteral("DELETE FROM conversations WHERE id = :id"));
        q.bindValue(QStringLiteral(":id"), cid);
        if (!q.exec()) return fail(q);
        // Attachment-Ordner (Spec-Konvention) NICHT hier löschen — wir laufen noch
        // in der offenen Transaktion. Dateisystem-Seiteneffekt erst NACH
        // erfolgreichem COMMIT (exec()): ein ROLLBACK stellt DB-Zeilen wieder
        // her, gelöschte Dateien nicht. Fehlt der Ordner, ist das ok.
        m_pendingDirDelete = QFileInfo(m_dbPath).absolutePath()
            + QStringLiteral("/attachments/") + cid;
        return true;
    }

    if (op == QLatin1String("appendToolCall")) {
        q.prepare(QStringLiteral(
            "INSERT INTO tool_calls(id, message_id, call_index, tool_name, arguments, status, extra) "
            "VALUES(:id, :mid, :idx, :tool, :args, :status, :extra)"));
        const QString tid = a.value(QStringLiteral("id")).toString();
        q.bindValue(QStringLiteral(":id"),
                    tid.isEmpty() ? QUuid::createUuid().toString(QUuid::WithoutBraces) : tid);
        q.bindValue(QStringLiteral(":mid"), a.value(QStringLiteral("messageId")));
        q.bindValue(QStringLiteral(":idx"), a.value(QStringLiteral("callIndex"), 0).toInt());
        // textOrEmpty: tool_name ist NOT NULL (ohne DEFAULT) — eine null-QString
        // würde den INSERT an der Constraint scheitern lassen statt an fehlenden Daten.
        q.bindValue(QStringLiteral(":tool"), textOrEmpty(a.value(QStringLiteral("toolName"))));
        q.bindValue(QStringLiteral(":args"), extraToJson(a.value(QStringLiteral("arguments"))));
        q.bindValue(QStringLiteral(":status"),
                    textOrEmpty(a.value(QStringLiteral("status"), QStringLiteral("pending"))));
        q.bindValue(QStringLiteral(":extra"), extraToJson(a.value(QStringLiteral("extra"))));
        return q.exec() ? true : fail(q);
    }

    if (op == QLatin1String("updateToolCall")) {
        static const QStringList erlaubt = {QStringLiteral("status"), QStringLiteral("startedAt"),
                                            QStringLiteral("finishedAt"),
                                            QStringLiteral("resultMessageId"), QStringLiteral("extra")};
        static const QMap<QString, QString> spalte = {
            {QStringLiteral("status"), QStringLiteral("status")},
            {QStringLiteral("startedAt"), QStringLiteral("started_at")},
            {QStringLiteral("finishedAt"), QStringLiteral("finished_at")},
            {QStringLiteral("resultMessageId"), QStringLiteral("result_message_id")},
            {QStringLiteral("extra"), QStringLiteral("extra")},
        };
        QStringList sets;
        for (const QString &k : erlaubt) {
            if (a.contains(k))
                sets << QString(spalte.value(k) + QStringLiteral(" = :") + k);
        }
        if (sets.isEmpty()) {
            if (error) *error = QStringLiteral("updateToolCall: keine erlaubten Felder");
            return false;
        }
        q.prepare(QStringLiteral("UPDATE tool_calls SET ") + sets.join(QStringLiteral(", "))
                  + QStringLiteral(" WHERE id = :id"));
        for (const QString &k : erlaubt) {
            if (!a.contains(k)) continue;
            if (k == QLatin1String("extra"))
                q.bindValue(QStringLiteral(":extra"), extraToJson(a.value(k)));
            else
                // textOrEmpty: status/startedAt/finishedAt/resultMessageId sind
                // optionale Textfelder — null-QString darf den Write nicht kippen.
                q.bindValue(QString(QStringLiteral(":") + k), textOrEmpty(a.value(k)));
        }
        q.bindValue(QStringLiteral(":id"), textOrEmpty(a.value(QStringLiteral("id"))));
        return execIdOp();
    }

    if (op == QLatin1String("sweepNonFinal")) {
        return q.exec(QStringLiteral(
                   "UPDATE tool_calls SET status='aborted' WHERE status IN ('pending','running')"))
            ? true : fail(q);
    }

    if (error) *error = QStringLiteral("Unbekannte Operation: %1").arg(op);
    return false;
}

// ---------------------------------------------------------------------------
// ConversationStore (GUI-Thread)
// ---------------------------------------------------------------------------
ConversationStore::ConversationStore(QObject *parent)
    : QObject(parent)
{
}

ConversationStore::~ConversationStore()
{
    if (m_thread.isRunning()) {
        // Queue DRAINEN, bevor der Thread endet: quit() unterbricht den
        // Dispatcher und würde bereits enqueued Writes (z.B. die letzte
        // appendMessage beim Schließen) verwerfen. Der blockierende No-op
        // läuft FIFO NACH allen zuvor geposteten exec()-Aufrufen.
        if (m_worker)
            QMetaObject::invokeMethod(m_worker, []() {}, Qt::BlockingQueuedConnection);
        m_thread.quit();
        // Unbegrenzt warten: Ops sind endlich (busy_timeout 500 ms pro Statement);
        // ein wait(3000)-Timeout mit anschließender Zerstörung des laufenden
        // QThread wäre ein qFatal/Absturz im plasmashell-Prozess.
        m_thread.wait();
    }
    if (!m_readConn.isEmpty()) {
        {
            // Handle-Scope vor removeDatabase (sonst "still in use"-Warnung)
            QSqlDatabase db = QSqlDatabase::database(m_readConn, /*open=*/false);
            if (db.isOpen()) db.close();
        }
        QSqlDatabase::removeDatabase(m_readConn);
    }
}

bool ConversationStore::ready() const { return m_ready; }

QString ConversationStore::dbPath() const { return resolvedDbPath(); }

QString ConversationStore::newUuid() const
{
    return QUuid::createUuid().toString(QUuid::WithoutBraces);
}

QVariantMap ConversationStore::open()
{
    if (m_ready)
        return {{QStringLiteral("ok"), true}, {QStringLiteral("error"), QString()}};

    const QString path = resolvedDbPath();
    QString error;

    // Migration synchron über eine temporäre Verbindung (einmalig, Millisekunden).
    // WICHTIG: das lokale QSqlDatabase-Handle muss VOR removeDatabase() aus dem
    // Scope sein, sonst warnt Qt "connection is still in use" bei jedem open().
    {
        const QString mig = QStringLiteral("aurora_migrate_%1").arg(reinterpret_cast<quintptr>(this));
        bool ok = false;
        {
            QSqlDatabase db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), mig);
            db.setDatabaseName(path);
            ok = db.open() && applyPragmas(db, &error) && migrate(db, &error)
                && sweepOnOpen(db, &error);
            if (db.isOpen()) db.close();
        }
        QSqlDatabase::removeDatabase(mig);
        if (!ok) {
            if (error.isEmpty()) error = QStringLiteral("Datenbank konnte nicht geöffnet werden: %1").arg(path);
            return {{QStringLiteral("ok"), false}, {QStringLiteral("error"), error}};
        }
    }

    // Lese-Verbindung (GUI-Thread); Name pro Instanz eindeutig (s. StoreWorker)
    m_readConn = QStringLiteral("aurora_read_%1").arg(reinterpret_cast<quintptr>(this));
    bool readOk = false;
    {
        QSqlDatabase rdb = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), m_readConn);
        rdb.setDatabaseName(path);
        readOk = rdb.open() && applyPragmas(rdb, &error);
        if (!readOk && error.isEmpty())
            error = rdb.lastError().text();
    }
    if (!readOk) {
        // Fehlpfad sauber: registrierte Verbindung entfernen, sonst warnt ein
        // erneutes open() mit "duplicate connection name"
        QSqlDatabase::removeDatabase(m_readConn);
        m_readConn.clear();
        return {{QStringLiteral("ok"), false}, {QStringLiteral("error"), error}};
    }

    // Write-Worker
    m_worker = new StoreWorker(path);
    m_worker->moveToThread(&m_thread);
    connect(&m_thread, &QThread::finished, m_worker, &QObject::deleteLater);
    connect(this, &ConversationStore::opRequested, m_worker, &StoreWorker::exec);
    connect(m_worker, &StoreWorker::completed, this, &ConversationStore::writeCompleted);
    connect(m_worker, &StoreWorker::failed, this, &ConversationStore::writeFailed);
    m_thread.start();

    m_ready = true;
    Q_EMIT readyChanged();
    return {{QStringLiteral("ok"), true}, {QStringLiteral("error"), QString()}};
}

QVariantList ConversationStore::listConversations(int limit) const
{
    QVariantList out;
    if (!m_ready) return out;
    QSqlQuery q(QSqlDatabase::database(m_readConn));
    q.prepare(QStringLiteral(
        "SELECT id, title, created_at, updated_at, archived, extra "
        "FROM conversations ORDER BY updated_at DESC LIMIT :n"));
    q.bindValue(QStringLiteral(":n"), limit);
    if (!q.exec()) {
        // Reads sind const, das Signal nicht — Emission daher über const_cast.
        Q_EMIT const_cast<ConversationStore *>(this)->readFailed(
            QStringLiteral("listConversations"), q.lastError().text());
        return out;
    }
    while (q.next()) {
        out.append(QVariantMap{
            {QStringLiteral("id"), q.value(0).toString()},
            {QStringLiteral("title"), q.value(1).toString()},
            {QStringLiteral("createdAt"), q.value(2).toString()},
            {QStringLiteral("updatedAt"), q.value(3).toString()},
            {QStringLiteral("archived"), q.value(4).toInt() != 0},
            {QStringLiteral("extra"), jsonToMap(q.value(5).toString())},
        });
    }
    return out;
}

QVariantList ConversationStore::messages(const QString &conversationId) const
{
    QVariantList out;
    if (!m_ready) return out;
    QSqlQuery q(QSqlDatabase::database(m_readConn));
    q.prepare(QStringLiteral(
        "SELECT id, seq, turn_id, role, content, thinking, tool_name, model, backend,"
        " status, created_at, media_path, media_type, extra, rating "
        "FROM messages WHERE conversation_id = :cid ORDER BY seq"));
    q.bindValue(QStringLiteral(":cid"), conversationId);
    if (!q.exec()) {
        Q_EMIT const_cast<ConversationStore *>(this)->readFailed(
            QStringLiteral("messages"), q.lastError().text());
        return out;
    }
    while (q.next()) {
        out.append(QVariantMap{
            {QStringLiteral("id"), q.value(0).toString()},
            {QStringLiteral("seq"), q.value(1).toInt()},
            {QStringLiteral("turnId"), q.value(2).toString()},
            {QStringLiteral("role"), q.value(3).toString()},
            {QStringLiteral("content"), q.value(4).toString()},
            {QStringLiteral("thinking"), q.value(5).toString()},
            {QStringLiteral("toolName"), q.value(6).toString()},
            {QStringLiteral("model"), q.value(7).toString()},
            {QStringLiteral("backend"), q.value(8).toString()},
            {QStringLiteral("status"), q.value(9).toString()},
            {QStringLiteral("createdAt"), q.value(10).toString()},
            {QStringLiteral("mediaPath"), q.value(11).toString()},
            {QStringLiteral("mediaType"), q.value(12).toString()},
            {QStringLiteral("extra"), jsonToMap(q.value(13).toString())},
            {QStringLiteral("rating"), q.value(14).toInt()},
        });
    }
    return out;
}

QVariantMap ConversationStore::conversation(const QString &id) const
{
    QVariantMap out;
    if (!m_ready) return out;
    QSqlQuery q(QSqlDatabase::database(m_readConn));
    q.prepare(QStringLiteral(
        "SELECT id, title, created_at, updated_at, archived, extra "
        "FROM conversations WHERE id = :id"));
    q.bindValue(QStringLiteral(":id"), id);
    if (!q.exec()) {
        Q_EMIT const_cast<ConversationStore *>(this)->readFailed(
            QStringLiteral("conversation"), q.lastError().text());
        return out;
    }
    if (!q.next()) return out;
    out = QVariantMap{
        {QStringLiteral("id"), q.value(0).toString()},
        {QStringLiteral("title"), q.value(1).toString()},
        {QStringLiteral("createdAt"), q.value(2).toString()},
        {QStringLiteral("updatedAt"), q.value(3).toString()},
        {QStringLiteral("archived"), q.value(4).toInt() != 0},
        {QStringLiteral("extra"), jsonToMap(q.value(5).toString())},
    };
    return out;
}

QVariantList ConversationStore::goodExamples() const
{
    QVariantList out;
    if (!m_ready) return out;
    QSqlQuery q(QSqlDatabase::database(m_readConn));
    q.prepare(QStringLiteral(
        "SELECT a.id, a.content, a.model, a.created_at,"
        " (a.embedding IS NOT NULL) AS has_emb,"
        " (SELECT u.content FROM messages u"
        "   WHERE u.conversation_id = a.conversation_id AND u.role = 'user'"
        "     AND u.seq < a.seq ORDER BY u.seq DESC LIMIT 1) AS question "
        "FROM messages a "
        "WHERE a.rating = 1 AND a.role = 'assistant' "
        "ORDER BY a.created_at DESC"));
    if (!q.exec()) {
        Q_EMIT const_cast<ConversationStore *>(this)->readFailed(
            QStringLiteral("goodExamples"), q.lastError().text());
        return out;
    }
    while (q.next()) {
        out.append(QVariantMap{
            {QStringLiteral("id"), q.value(0).toString()},
            {QStringLiteral("answer"), q.value(1).toString()},
            {QStringLiteral("model"), q.value(2).toString()},
            {QStringLiteral("createdAt"), q.value(3).toString()},
            {QStringLiteral("hasEmbedding"), q.value(4).toInt() != 0},
            {QStringLiteral("question"), q.value(5).toString()},
        });
    }
    return out;
}

QVariantList ConversationStore::knowledgeEntries() const
{
    QVariantList out;
    if (!m_ready) return out;
    QSqlQuery q(QSqlDatabase::database(m_readConn));
    q.prepare(QStringLiteral(
        "SELECT id, kind, title, url, content, (embedding IS NOT NULL) AS has_emb,"
        " created_at, updated_at "
        "FROM knowledge ORDER BY created_at DESC"));
    if (!q.exec()) {
        Q_EMIT const_cast<ConversationStore *>(this)->readFailed(
            QStringLiteral("knowledgeEntries"), q.lastError().text());
        return out;
    }
    while (q.next()) {
        out.append(QVariantMap{
            {QStringLiteral("id"), q.value(0).toString()},
            {QStringLiteral("kind"), q.value(1).toString()},
            {QStringLiteral("title"), q.value(2).toString()},
            {QStringLiteral("url"), q.value(3).toString()},
            {QStringLiteral("content"), q.value(4).toString()},
            {QStringLiteral("hasEmbedding"), q.value(5).toInt() != 0},
            {QStringLiteral("createdAt"), q.value(6).toString()},
            {QStringLiteral("updatedAt"), q.value(7).toString()},
        });
    }
    return out;
}

QVariantList ConversationStore::searchSimilar(const QVariantList &queryVec, const QString &embedModel,
                                              int topK, double minScore) const
{
    QVariantList out;
    if (!m_ready || queryVec.isEmpty())
        return out;
    // NaN/negative Schwelle (hand-editierte Config) auf 0 klemmen — sonst würde
    // der -2.0-Sentinel (Dimensions-Mismatch/Nullnorm) als Treffer durchrutschen
    // bzw. bei NaN jeder Vergleich s < minScore false (alle Kandidaten „Treffer").
    if (!(minScore >= 0.0))
        minScore = 0.0;

    QVector<float> q(queryVec.size());
    double qNorm = 0.0;
    for (int i = 0; i < queryVec.size(); ++i) {
        q[i] = float(queryVec.at(i).toDouble());
        qNorm += double(q[i]) * double(q[i]);
    }
    // !isfinite: NaN/Inf im Query-Vektor (defekte Embed-Antwort) — ohne diesen
    // Guard wären alle Scores NaN und alle Kandidaten „Treffer".
    if (!std::isfinite(qNorm) || qNorm <= 0.0)
        return out;
    qNorm = std::sqrt(qNorm);
    const int k = qBound(0, topK, 20);

    // Kandidaten aus BEIDEN Quellen (Scheibe C): bewertete Antworten — strikt
    // rating=1, nicht bloße Vektor-Präsenz (ein async-Orphan-Vektor auf einer
    // inzwischen un-bewerteten Zeile darf nie treffen) — und knowledge-Einträge.
    // embed_model muss zum Query-Modell passen (Vektoren verschiedener Modelle
    // sind nicht vergleichbar). SQL-Fehler -> betroffene Quelle liefert nichts,
    // der Fehler wird per readFailed gemeldet (Konvention der Lese-Methoden).
    QList<QPair<double, QVariantMap>> hits;
    {
        QSqlQuery qy(QSqlDatabase::database(m_readConn));
        qy.prepare(QStringLiteral(
            "SELECT a.id, a.content, a.embedding,"
            " (SELECT u.content FROM messages u"
            "   WHERE u.conversation_id = a.conversation_id AND u.role = 'user'"
            "     AND u.seq < a.seq ORDER BY u.seq DESC LIMIT 1) AS question "
            "FROM messages a "
            "WHERE a.rating = 1 AND a.role = 'assistant'"
            " AND a.embedding IS NOT NULL AND a.embed_model = :m"));
        qy.bindValue(QStringLiteral(":m"), embedModel);
        if (qy.exec()) {
            while (qy.next()) {
                const double s = cosineScore(q, qNorm, qy.value(2).toByteArray());
                if (!std::isfinite(s) || s < minScore)
                    continue;
                hits.append({s, QVariantMap{
                    {QStringLiteral("source"), QStringLiteral("rated")},
                    {QStringLiteral("id"), qy.value(0).toString()},
                    {QStringLiteral("score"), s},
                    {QStringLiteral("question"), qy.value(3).toString()},
                    {QStringLiteral("answer"), qy.value(1).toString()},
                }});
            }
        } else {
            Q_EMIT const_cast<ConversationStore *>(this)->readFailed(
                QStringLiteral("searchSimilar"), qy.lastError().text());
        }
    }
    {
        QSqlQuery qy(QSqlDatabase::database(m_readConn));
        qy.prepare(QStringLiteral(
            "SELECT id, kind, title, url, content, embedding FROM knowledge "
            "WHERE embedding IS NOT NULL AND embed_model = :m"));
        qy.bindValue(QStringLiteral(":m"), embedModel);
        if (qy.exec()) {
            while (qy.next()) {
                const double s = cosineScore(q, qNorm, qy.value(5).toByteArray());
                if (!std::isfinite(s) || s < minScore)
                    continue;
                hits.append({s, QVariantMap{
                    {QStringLiteral("source"), QStringLiteral("knowledge")},
                    {QStringLiteral("id"), qy.value(0).toString()},
                    {QStringLiteral("score"), s},
                    {QStringLiteral("kind"), qy.value(1).toString()},
                    {QStringLiteral("title"), qy.value(2).toString()},
                    {QStringLiteral("url"), qy.value(3).toString()},
                    {QStringLiteral("content"), qy.value(4).toString()},
                }});
            }
        } else {
            Q_EMIT const_cast<ConversationStore *>(this)->readFailed(
                QStringLiteral("searchSimilar"), qy.lastError().text());
        }
    }

    // stable_sort: bei Score-Gleichstand (z. B. identischer Vektor in messages UND
    // knowledge) bleibt die Quellen-Reihenfolge deterministisch — wichtig am topK-Cut.
    std::stable_sort(hits.begin(), hits.end(),
              [](const QPair<double, QVariantMap> &a, const QPair<double, QVariantMap> &b) {
                  return a.first > b.first;
              });
    for (int i = 0; i < hits.size() && i < k; ++i)
        out.append(hits.at(i).second);
    return out;
}

QVariantList ConversationStore::searchConversations(const QString &text, int limit) const
{
    QVariantList out;
    if (!m_ready)
        return out;
    const QString trimmed = text.trimmed();
    if (trimmed.isEmpty())
        return out;
    const int k = qBound(1, limit, 100);

    // FTS-MATCH-String: jedes Wort einzeln in Anführungszeichen mit Präfix-*
    // (AND-Semantik der Wörter, Präfix je Wort — „rhab" findet „Rhabarberkompott",
    // Type-ahead-Üblichkeit). Quoting macht FTS-Operatoren/Sonderzeichen inert.
    // Wörter aus reinen Satzzeichen (z. B. "%") erzeugen beim FTS-Tokenizer
    // leere Phrasen (Syntaxfehler) — sie werden vorweg verworfen.
    const QStringList words = trimmed.split(QRegularExpression(QStringLiteral("\\s+")),
                                            Qt::SkipEmptyParts);
    QStringList quoted;
    for (const QString &w : words) {
        if (!w.contains(QRegularExpression(QStringLiteral("\\w"))))
            continue;
        quoted << QStringLiteral("\"") + QString(w).replace(QStringLiteral("\""),
                                                            QStringLiteral("\"\""))
               + QStringLiteral("\"*");
    }
    if (quoted.isEmpty())
        return out;
    const QString matchStr = quoted.join(QLatin1Char(' '));

    // LIKE-Muster fuer den Titel: %/_/\ escapen (ESCAPE '\').
    QString like = trimmed;
    like.replace(QStringLiteral("\\"), QStringLiteral("\\\\"))
        .replace(QStringLiteral("%"), QStringLiteral("\\%"))
        .replace(QStringLiteral("_"), QStringLiteral("\\_"));
    like = QStringLiteral("%") + like + QStringLiteral("%");

    QSet<QString> seen;
    QList<QVariantMap> merged;

    // Titel-Treffer zuerst (LIKE auf conversations.title)
    {
        QSqlQuery q(QSqlDatabase::database(m_readConn));
        q.prepare(QStringLiteral(
            "SELECT id, title, created_at, updated_at FROM conversations"
            " WHERE title LIKE :like ESCAPE '\\'"));
        q.bindValue(QStringLiteral(":like"), like);
        if (!q.exec()) {
            Q_EMIT const_cast<ConversationStore *>(this)->readFailed(
                QStringLiteral("searchConversations"), q.lastError().text());
            return out;
        }
        while (q.next()) {
            const QString id = q.value(0).toString();
            if (seen.contains(id))
                continue;
            seen.insert(id);
            merged.append(QVariantMap{
                {QStringLiteral("id"), id},
                {QStringLiteral("title"), q.value(1).toString()},
                {QStringLiteral("createdAt"), q.value(2).toString()},
                {QStringLiteral("updatedAt"), q.value(3).toString()},
                {QStringLiteral("snippet"), QString()},
                {QStringLiteral("titleMatch"), true},
            });
        }
    }

    // Inhalts-Treffer (FTS5 auf user/assistant). Zweistufig: MATCH liefert die
    // Zeilen (JOIN auf conversation_id/content), das Snippet baut C++ daraus.
    // Dedup pro Konversation (erste — älteste — Trefferzeile gewinnt).
    {
        QSqlQuery q(QSqlDatabase::database(m_readConn));
        q.prepare(QStringLiteral(
            "SELECT m.conversation_id, m.content"
            " FROM messages_fts JOIN messages m ON m.rowid = messages_fts.rowid"
            " WHERE messages_fts MATCH :m"
            " ORDER BY messages_fts.rowid LIMIT :n"));
        q.bindValue(QStringLiteral(":m"), matchStr);
        q.bindValue(QStringLiteral(":n"), k * 5);
        if (!q.exec()) {
            Q_EMIT const_cast<ConversationStore *>(this)->readFailed(
                QStringLiteral("searchConversations"), q.lastError().text());
            return out;
        }
        QSqlQuery hydra(QSqlDatabase::database(m_readConn));
        hydra.prepare(QStringLiteral(
            "SELECT title, created_at, updated_at FROM conversations WHERE id = :id"));
        while (q.next()) {
            const QString id = q.value(0).toString();
            if (seen.contains(id))
                continue;
            seen.insert(id);
            hydra.bindValue(QStringLiteral(":id"), id);
            if (!hydra.exec() || !hydra.next())
                continue;   // verwaiste Konversation: überspringen
            merged.append(QVariantMap{
                {QStringLiteral("id"), id},
                {QStringLiteral("title"), hydra.value(0).toString()},
                {QStringLiteral("createdAt"), hydra.value(1).toString()},
                {QStringLiteral("updatedAt"), hydra.value(2).toString()},
                {QStringLiteral("snippet"), makeSnippet(q.value(1).toString(), words)},
                {QStringLiteral("titleMatch"), false},
            });
        }
    }

    // Neueste Aktivität zuerst (ISO-Strings sortieren lexikografisch = chronologisch)
    std::sort(merged.begin(), merged.end(),
              [](const QVariantMap &a, const QVariantMap &b) {
                  return a.value(QStringLiteral("updatedAt")).toString()
                       > b.value(QStringLiteral("updatedAt")).toString();
              });
    for (int i = 0; i < merged.size() && i < k; ++i)
        out.append(merged.at(i));
    return out;
}

QString ConversationStore::questionForAnswer(const QString &assistantId) const
{
    if (!m_ready) return QString();
    QSqlQuery q(QSqlDatabase::database(m_readConn));
    q.prepare(QStringLiteral(
        "SELECT u.content FROM messages u "
        "JOIN messages a ON a.id = :id AND u.conversation_id = a.conversation_id "
        "WHERE u.role = 'user' AND u.seq < a.seq "
        "ORDER BY u.seq DESC LIMIT 1"));
    q.bindValue(QStringLiteral(":id"), assistantId);
    if (!q.exec()) {
        Q_EMIT const_cast<ConversationStore *>(this)->readFailed(
            QStringLiteral("questionForAnswer"), q.lastError().text());
        return QString();
    }
    if (!q.next()) return QString();
    return q.value(0).toString();
}

QString ConversationStore::latestConversationId() const
{
    if (!m_ready) return QString();
    QSqlQuery q(QSqlDatabase::database(m_readConn));
    q.prepare(QStringLiteral(
        "SELECT id FROM conversations ORDER BY updated_at DESC LIMIT 1"));
    if (!q.exec()) {
        Q_EMIT const_cast<ConversationStore *>(this)->readFailed(
            QStringLiteral("latestConversationId"), q.lastError().text());
        return QString();
    }
    if (!q.next())
        return QString();
    return q.value(0).toString();
}

void ConversationStore::enqueue(const QString &op, const QVariantMap &args)
{
    if (!m_ready) {
        Q_EMIT writeFailed(op, QStringLiteral("Store nicht geöffnet (open() fehlt oder schlug fehl)"));
        return;
    }
    Q_EMIT opRequested(op, args);
}

void ConversationStore::createConversation(const QString &id, const QString &title)
{
    enqueue(QStringLiteral("createConversation"),
            {{QStringLiteral("id"), id}, {QStringLiteral("title"), title}});
}

void ConversationStore::appendMessage(const QVariantMap &msg)
{
    enqueue(QStringLiteral("appendMessage"), msg);
}

// Task 3 implementiert die folgenden Ops im Worker; die Q_INVOKABLEs
// enqueuen bereits jetzt (unbekannte Op -> writeFailed, von Tests gedeckt):
void ConversationStore::updateMessage(const QString &id, const QVariantMap &fields)
{
    QVariantMap a = fields;
    a.insert(QStringLiteral("id"), id);
    enqueue(QStringLiteral("updateMessage"), a);
}

void ConversationStore::setEmbedding(const QString &id, const QVariantList &vec, const QString &model)
{
    enqueue(QStringLiteral("setEmbedding"),
            {{QStringLiteral("id"), id}, {QStringLiteral("vec"), vec}, {QStringLiteral("model"), model}});
}

void ConversationStore::addKnowledge(const QVariantMap &fields)
{
    enqueue(QStringLiteral("addKnowledge"), fields);
}

void ConversationStore::updateKnowledge(const QString &id, const QVariantMap &fields)
{
    QVariantMap a = fields;
    a.insert(QStringLiteral("id"), id);
    enqueue(QStringLiteral("updateKnowledge"), a);
}

void ConversationStore::setKnowledgeEmbedding(const QString &id, const QVariantList &vec, const QString &model)
{
    enqueue(QStringLiteral("setKnowledgeEmbedding"),
            {{QStringLiteral("id"), id}, {QStringLiteral("vec"), vec}, {QStringLiteral("model"), model}});
}

void ConversationStore::deleteKnowledge(const QString &id)
{
    enqueue(QStringLiteral("deleteKnowledge"), {{QStringLiteral("id"), id}});
}

void ConversationStore::deleteMessage(const QString &id)
{
    enqueue(QStringLiteral("deleteMessage"), {{QStringLiteral("id"), id}});
}

void ConversationStore::touchConversation(const QString &id, const QString &title)
{
    enqueue(QStringLiteral("touchConversation"),
            {{QStringLiteral("id"), id}, {QStringLiteral("title"), title}});
}

void ConversationStore::updateConversation(const QString &id, const QVariantMap &fields)
{
    QVariantMap a = fields;
    a.insert(QStringLiteral("id"), id);
    enqueue(QStringLiteral("updateConversation"), a);
}

void ConversationStore::deleteConversation(const QString &id)
{
    enqueue(QStringLiteral("deleteConversation"), {{QStringLiteral("id"), id}});
}

void ConversationStore::appendToolCall(const QVariantMap &toolCall)
{
    enqueue(QStringLiteral("appendToolCall"), toolCall);
}

void ConversationStore::updateToolCall(const QString &id, const QVariantMap &fields)
{
    QVariantMap a = fields;
    a.insert(QStringLiteral("id"), id);
    enqueue(QStringLiteral("updateToolCall"), a);
}

void ConversationStore::sweepNonFinal()
{
    enqueue(QStringLiteral("sweepNonFinal"), {});
}

#include "conversationstore.moc"
