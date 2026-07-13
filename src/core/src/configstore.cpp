#include "configstore.h"

#include <QFile>
#include <QFileInfo>
#include <QStandardPaths>

// Default-Schema: die EINZIGE Default-Quelle (Spec 2c §9). Private Endpunkte
// bewusst LEER — keine echten IPs im Quellcode; die Migration uebernimmt
// bestehende Werte aus dem appletsrc.
const QVariantMap &ConfigStore::defaults()
{
    static const QVariantMap d = {
        { QStringLiteral("modelLowPower"),          QStringLiteral("gemma4:e2b") },
        { QStringLiteral("modelBalanced"),          QStringLiteral("gemma4:e4b") },
        { QStringLiteral("modelPerformance"),       QStringLiteral("qwen3.5:9b") },
        { QStringLiteral("lastSelectedModel"),      QStringLiteral("auto") },
        { QStringLiteral("remoteEnabled"),          true },
        { QStringLiteral("remoteEndpoint"),         QString() },
        { QStringLiteral("remoteEndpointFallback"), QString() },
        { QStringLiteral("unloadSeconds"),          300 },
        { QStringLiteral("twoPhaseToolCalls"),      false },
        { QStringLiteral("toolWebSearch"),          QStringLiteral("auto") },
        { QStringLiteral("toolReadFile"),           QStringLiteral("auto") },
        { QStringLiteral("toolListDir"),            QStringLiteral("auto") },
        { QStringLiteral("toolWebFetch"),           QStringLiteral("auto") },
        { QStringLiteral("toolWriteFile"),          QStringLiteral("confirm") },
        { QStringLiteral("toolRunCommand"),         QStringLiteral("confirm") },
        { QStringLiteral("toolMaxRounds"),          5 },
        { QStringLiteral("comfyEnabled"),           true },
        { QStringLiteral("comfyEndpoint"),          QString() },
        { QStringLiteral("comfyDefaultModel"),      QStringLiteral("z_image_turbo") },
        { QStringLiteral("ttsVoice"),               QStringLiteral("de_DE-thorsten-high") },
        { QStringLiteral("ttsAutoSpeak"),           false },
        { QStringLiteral("sttLanguage"),            QStringLiteral("auto") },
        { QStringLiteral("sttSource"),              QString() },
        { QStringLiteral("searchEndpoint"),         QStringLiteral("http://127.0.0.1:8888") },
        { QStringLiteral("modelParams"),            QStringLiteral("{}") },
        { QStringLiteral("embedModel"),             QStringLiteral("nomic-embed-text") },
    };
    return d;
}

QString ConfigStore::resolvedConfigPath()
{
    const QByteArray override = qgetenv("AURORA_CONFIG_PATH");
    if (!override.isEmpty())
        return QString::fromLocal8Bit(override);
    const QString base = QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation);
    return base + QStringLiteral("/net.niuton.aurora.rc");
}

ConfigStore::ConfigStore(QObject *parent)
    : QObject(parent)
    , m_settings(resolvedConfigPath(), QSettings::IniFormat)
{
    m_settings.sync();                 // legt die Datei an, falls noch nicht vorhanden
    ensureWatch();
    snapshotContent();                 // Ausgangszustand puffern (eigener Write oben)
    connect(&m_watcher, &QFileSystemWatcher::fileChanged, this, [this](const QString &) {
        QByteArray cur;
        {
            QFile f(m_settings.fileName());
            if (f.open(QIODevice::ReadOnly))
                cur = f.readAll();
        }
        if (cur == m_lastContent) {
            // Eigener Write (oder inhaltlich identisch) -> nur den Watch neu
            // setzen (sync() ersetzt die Datei atomar -> Pfad neu beobachten),
            // KEIN Re-Sync, KEIN Bump: m_settings ist bereits aktuell, die
            // Bindings wurden synchron gebumpt.
            ensureWatch();
            return;
        }
        // Externe Aenderung (Config-Dialog-Engine oder anderer Prozess) -> neu
        // einlesen, Snapshot aktualisieren, revision bumpen, damit die
        // revision-verankerten Bindings re-evaluieren.
        m_settings.sync();
        snapshotContent();
        ensureWatch();
        bumpRevision(QString());
    });
}

void ConfigStore::snapshotContent()
{
    QFile f(m_settings.fileName());
    if (f.open(QIODevice::ReadOnly))
        m_lastContent = f.readAll();
    else
        m_lastContent.clear();
}

void ConfigStore::ensureWatch()
{
    const QString path = m_settings.fileName();
    if (!QFileInfo::exists(path)) {
        // QSettings::sync() schreibt die Datei nur, wenn es tatsaechlich Daten
        // gibt — ein brandneuer Store ganz ohne gesetzten Key (erster Start,
        // noch kein einziges setValue()) legt sonst nie eine Datei an, und ein
        // QFileSystemWatcher kann einen nicht existierenden Pfad nicht beobachten.
        // Leere Datei anlegen (touch), damit externe Aenderungen (Config-Dialog-
        // Engine) von Anfang an sichtbar werden.
        QFile f(path);
        [[maybe_unused]] const bool ok = f.open(QIODevice::WriteOnly);
        snapshotContent();          // Touch ist unser eigener Write -> Snapshot nachziehen
    }
    if (!m_watcher.files().contains(path))
        m_watcher.addPath(path);
}

void ConfigStore::bumpRevision(const QString &key)
{
    ++m_revision;
    Q_EMIT revisionChanged();
    Q_EMIT valueChanged(key);
}

int ConfigStore::revision() const { return m_revision; }

QString ConfigStore::configPath() const { return m_settings.fileName(); }

QVariant ConfigStore::value(const QString &key) const
{
    const QVariant def = defaults().value(key);
    QVariant v = m_settings.value(key, def);
    // QSettings(IniFormat) liefert cross-process QString; auf den Schema-Typ
    // konvertieren, damit QML bool/int typrichtig sieht (nur bei bekanntem Key).
    if (def.isValid() && v.metaType() != def.metaType())
        v.convert(def.metaType());
    return v;
}

QVariant ConfigStore::defaultValue(const QString &key) const
{
    return defaults().value(key);
}

bool ConfigStore::contains(const QString &key) const
{
    return m_settings.contains(key);   // roher Treffer, typ-unabhaengig (Migrations-Marker)
}

void ConfigStore::setValue(const QString &key, const QVariant &value)
{
    if (this->value(key) == value)     // this->value konvertiert -> typ-korrekter Vergleich
        return;                        // idempotent: kein Bump ohne echte Aenderung
    m_settings.setValue(key, value);
    m_settings.sync();
    snapshotContent();
    ensureWatch();
    bumpRevision(key);
}

void ConfigStore::reset()
{
    // Migrations-Marker bewahren, sonst re-migriert der naechste Start und macht
    // den Reset rueckgaengig.
    const bool wasMigrated = m_settings.contains(QStringLiteral("_migratedFromAppletsrc"));
    m_settings.clear();
    if (wasMigrated)
        m_settings.setValue(QStringLiteral("_migratedFromAppletsrc"), true);
    m_settings.sync();
    snapshotContent();
    ensureWatch();
    bumpRevision(QString());
}
