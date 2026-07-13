#pragma once

#include <QByteArray>
#include <QObject>
#include <QProcess>
#include <QQmlEngine>
#include <QTimer>
#include <QVariantMap>

// Argv-basierte Prozessausführung mit Prozessgruppen-Signalen. Kein Shell:
// start() nimmt Programm + argv-Liste, Escaping entfällt. terminate()/kill()/
// sendSignal() wirken via killpg auf die ganze Gruppe (der Prozess läuft in
// eigener Session, CreateNewSession) — ersetzt die pkill-Muster.
class ProcessRunner : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(bool running READ running NOTIFY runningChanged)
    Q_PROPERTY(int pid READ pid NOTIFY runningChanged)
    Q_PROPERTY(int timeoutMs READ timeoutMs WRITE setTimeoutMs NOTIFY timeoutMsChanged)
    Q_PROPERTY(int maxOutputBytes READ maxOutputBytes WRITE setMaxOutputBytes NOTIFY maxOutputBytesChanged)
    Q_PROPERTY(bool mergeStderr READ mergeStderr WRITE setMergeStderr NOTIFY mergeStderrChanged)
    Q_PROPERTY(QString workingDirectory READ workingDirectory WRITE setWorkingDirectory NOTIFY workingDirectoryChanged)
    Q_PROPERTY(QVariantMap environment READ environment WRITE setEnvironment NOTIFY environmentChanged)

public:
    explicit ProcessRunner(QObject *parent = nullptr);
    ~ProcessRunner() override;

    bool running() const;
    int pid() const;
    int timeoutMs() const;
    void setTimeoutMs(int ms);
    int maxOutputBytes() const;
    void setMaxOutputBytes(int bytes);
    bool mergeStderr() const;
    void setMergeStderr(bool on);
    QString workingDirectory() const;
    void setWorkingDirectory(const QString &dir);
    QVariantMap environment() const;
    void setEnvironment(const QVariantMap &env);

    Q_INVOKABLE void start(const QString &program, const QStringList &args);
    Q_INVOKABLE void writeStdin(const QByteArray &data);
    Q_INVOKABLE void closeStdin();
    Q_INVOKABLE void terminate();
    Q_INVOKABLE void kill();
    Q_INVOKABLE void sendSignal(int sig);

Q_SIGNALS:
    void started();
    void stdoutChunk(const QByteArray &chunk);
    void stderrChunk(const QByteArray &chunk);
    void finished(int exitCode, const QString &stdoutText, const QString &stderrText,
                  bool truncated, bool timedOut);
    void failed(const QString &message);
    void runningChanged();
    void timeoutMsChanged();
    void maxOutputBytesChanged();
    void mergeStderrChanged();
    void workingDirectoryChanged();
    void environmentChanged();

private:
    void appendCapped(QByteArray &buffer, const QByteArray &data, bool &truncatedFlag);
    void cleanup();

    QProcess *m_process = nullptr;
    QTimer m_timeoutTimer;
    QByteArray m_stdout;
    QByteArray m_stderr;
    bool m_stdoutTruncated = false;
    bool m_stderrTruncated = false;
    bool m_timedOut = false;
    int m_timeoutMs = 0;
    int m_maxOutputBytes = 1048576;
    bool m_mergeStderr = false;
    QString m_workingDirectory;
    QVariantMap m_environment;
};
