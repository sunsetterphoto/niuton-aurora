#pragma once

#include <QObject>
#include <QQmlEngine>
#include <QVariantMap>

// Synchrone Datei-Primitive für die QML-Engine.
// Bewusst synchron: alle Nutzungen sind kleine Dateien, maxBytes kappt in C++.
class FileIO : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

public:
    explicit FileIO(QObject *parent = nullptr);

    Q_INVOKABLE QVariantMap readText(const QString &path, int maxBytes = 1048576) const;
    Q_INVOKABLE QVariantMap writeText(const QString &path, const QString &text) const;
    Q_INVOKABLE QVariantMap readBase64(const QString &path, int maxBytes = 20971520) const;
    Q_INVOKABLE bool exists(const QString &path) const;
    Q_INVOKABLE QVariantMap fileInfo(const QString &path) const;
    Q_INVOKABLE QVariantMap listDir(const QString &path, bool showHidden = false) const;
    Q_INVOKABLE bool mkpath(const QString &path) const;
    Q_INVOKABLE QString standardPath(const QString &kind) const;
    Q_INVOKABLE QString urlToPath(const QString &url) const;
};
