#pragma once

#include <QFileSystemWatcher>
#include <QObject>
#include <QQmlEngine>
#include <QSettings>
#include <QVariant>
#include <QVariantMap>

// Gemeinsamer Config-Store (Spec 2c): die einzige Config-Wahrheit fuer Widget
// UND App. QSettings(IniFormat) auf ~/.config/net.niuton.aurora.rc. Reaktivitaet
// ueber revision (QSettings hat keine eingebaute Notify); ein QFileSystemWatcher
// macht Aenderungen cross-engine sichtbar (QML_SINGLETON ist pro QQmlEngine, und
// der Plasma-Config-Dialog laeuft in eigener Engine). KF6-frei (Fundament 3.1) —
// nur Qt6::Core.
class ConfigStore : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    Q_PROPERTY(int revision READ revision NOTIFY revisionChanged)

public:
    explicit ConfigStore(QObject *parent = nullptr);

    int revision() const;

    Q_INVOKABLE QVariant value(const QString &key) const;
    Q_INVOKABLE void setValue(const QString &key, const QVariant &value);
    Q_INVOKABLE QVariant defaultValue(const QString &key) const;
    Q_INVOKABLE bool contains(const QString &key) const;
    Q_INVOKABLE void reset();
    Q_INVOKABLE QString configPath() const;

Q_SIGNALS:
    void revisionChanged();
    void valueChanged(const QString &key);

private:
    static QString resolvedConfigPath();
    static const QVariantMap &defaults();
    void ensureWatch();          // Pfad (re)registrieren; QSettings::sync ersetzt die Datei atomar
    void bumpRevision(const QString &key);
    void snapshotContent();      // Roh-Bytes der Config-Datei in m_lastContent puffern (Self-Write-Erkennung)

    QSettings m_settings;
    QFileSystemWatcher m_watcher;
    int m_revision = 0;
    // Inhalts-Snapshot nach dem letzten SELBST ausgeloesten Datei-Write. Der
    // fileChanged-Handler vergleicht damit, ob eine Aenderung von uns selbst
    // stammt (Inhalt identisch) oder extern ist (Inhalt abweichend) — robust
    // gegen asynchrone Event-Koaleszenz, unabhaengig von mtime-Aufloesung.
    QByteArray m_lastContent;
};
