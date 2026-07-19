#include "fileio.h"
#include "utf8trim.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QMimeDatabase>
#include <QSaveFile>
#include <QStandardPaths>
#include <QUrl>

namespace {
constexpr qint64 kDefaultTextLimit = 1048576;    // 1 MiB
constexpr qint64 kDefaultBase64Limit = 20971520; // 20 MiB

QVariantMap fehler(const QString &msg)
{
    return {{QStringLiteral("ok"), false}, {QStringLiteral("error"), msg}};
}
}

FileIO::FileIO(QObject *parent)
    : QObject(parent)
{
}

QVariantMap FileIO::readText(const QString &path, int maxBytes) const
{
    QFile f(path);
    if (!f.exists()) {
        return fehler(QStringLiteral("Datei nicht gefunden: %1").arg(path));
    }
    const QFileInfo info(path);
    if (!info.isFile()) {
        return fehler(QStringLiteral("Keine reguläre Datei: %1").arg(path));
    }
    if (!f.open(QIODevice::ReadOnly)) {
        return fehler(f.errorString());
    }
    const qint64 limit = maxBytes > 0 ? maxBytes : kDefaultTextLimit;
    // truncated über read(limit+1) statt f.size(): st_size ist bei /proc-Dateien 0
    // und bei /sys-Attributen konstant 4096 — beides würde die f.size()-Heuristik
    // in die Irre führen (Task 3/4 lesen genau solche Pfade).
    QByteArray raw = f.read(limit + 1);
    const bool truncated = raw.size() > limit;
    if (truncated)
        raw = aurora::trimAufUtf8Grenze(raw.left(limit));
    return {{QStringLiteral("ok"), true},
            {QStringLiteral("text"), QString::fromUtf8(raw)},
            {QStringLiteral("truncated"), truncated},
            {QStringLiteral("error"), QString()}};
}

QVariantMap FileIO::writeText(const QString &path, const QString &text) const
{
    const QFileInfo info(path);
    if (!QDir().mkpath(info.absolutePath())) {
        return fehler(QStringLiteral("Konnte Verzeichnis nicht anlegen: %1").arg(info.absolutePath()));
    }
    QSaveFile f(path);
    if (!f.open(QIODevice::WriteOnly)) {
        return fehler(f.errorString());
    }
    f.write(text.toUtf8());
    if (!f.commit()) {
        return fehler(f.errorString());
    }
    return {{QStringLiteral("ok"), true}, {QStringLiteral("error"), QString()}};
}

QVariantMap FileIO::readBase64(const QString &path, int maxBytes) const
{
    QFile f(path);
    if (!f.exists()) {
        return fehler(QStringLiteral("Datei nicht gefunden: %1").arg(path));
    }
    const QFileInfo info(path);
    if (!info.isFile()) {
        return fehler(QStringLiteral("Keine reguläre Datei: %1").arg(path));
    }
    const qint64 limit = maxBytes > 0 ? maxBytes : kDefaultBase64Limit;
    if (!f.open(QIODevice::ReadOnly)) {
        return fehler(f.errorString());
    }
    // Limit erst NACH dem open via read(limit+1) durchsetzen (Muster readText):
    // st_size ist bei /proc-Dateien 0 und bei /sys-Attributen konstant 4096 —
    // eine size()-Prüfung vor dem open würde das Limit dort unterlaufen (TOCTOU).
    const QByteArray raw = f.read(limit + 1);
    if (raw.size() > limit) {
        return fehler(QStringLiteral("Datei zu groß (Limit %1 Bytes)").arg(limit));
    }
    const QMimeDatabase mimeDb;
    return {{QStringLiteral("ok"), true},
            {QStringLiteral("data"), QString::fromLatin1(raw.toBase64())},
            {QStringLiteral("mime"), mimeDb.mimeTypeForFileNameAndData(path, raw).name()},
            {QStringLiteral("error"), QString()}};
}

bool FileIO::exists(const QString &path) const
{
    return QFileInfo::exists(path);
}

QVariantMap FileIO::fileInfo(const QString &path) const
{
    const QFileInfo fi(path);
    const QMimeDatabase mimeDb;
    return {{QStringLiteral("exists"), fi.exists()},
            {QStringLiteral("isDir"), fi.isDir()},
            {QStringLiteral("size"), fi.size()},
            {QStringLiteral("mtime"), fi.lastModified().toString(Qt::ISODate)},
            {QStringLiteral("mime"), fi.exists() && !fi.isDir()
                                         ? mimeDb.mimeTypeForFile(fi).name()
                                         : QString()}};
}

QVariantMap FileIO::listDir(const QString &path, bool showHidden) const
{
    const QDir dir(path);
    if (!dir.exists()) {
        return fehler(QStringLiteral("Verzeichnis nicht gefunden: %1").arg(path));
    }
    QDir::Filters filters = QDir::AllEntries | QDir::NoDotAndDotDot;
    if (showHidden) {
        filters |= QDir::Hidden;
    }
    QVariantList entries;
    const QFileInfoList infos = dir.entryInfoList(filters, QDir::DirsFirst | QDir::Name);
    for (const QFileInfo &fi : infos) {
        entries.append(QVariantMap{{QStringLiteral("name"), fi.fileName()},
                                   {QStringLiteral("isDir"), fi.isDir()},
                                   {QStringLiteral("size"), fi.size()},
                                   {QStringLiteral("mtime"), fi.lastModified().toString(Qt::ISODate)}});
    }
    return {{QStringLiteral("ok"), true},
            {QStringLiteral("entries"), entries},
            {QStringLiteral("error"), QString()}};
}

bool FileIO::mkpath(const QString &path) const
{
    return QDir().mkpath(path);
}

QString FileIO::urlToPath(const QString &url) const
{
    const QUrl u(url);
    if (u.isLocalFile())
        return u.toLocalFile();   // strippt file://, dekodiert %20 etc.
    return url;                    // war schon ein reiner Pfad
}

QString FileIO::standardPath(const QString &kind) const
{
    if (kind == QLatin1String("home")) {
        return QStandardPaths::writableLocation(QStandardPaths::HomeLocation);
    }
    QString base;
    if (kind == QLatin1String("appData")) {
        base = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation);
    } else if (kind == QLatin1String("cache")) {
        base = QStandardPaths::writableLocation(QStandardPaths::GenericCacheLocation);
    } else {
        return QString();
    }
    const QString p = base + QLatin1String("/aurora");
    QDir().mkpath(p);
    return p;
}
