#include "processrunner.h"
#include "utf8trim.h"

#include <QProcessEnvironment>

#include <csignal>
#include <sys/types.h>

ProcessRunner::ProcessRunner(QObject *parent)
    : QObject(parent)
{
    m_timeoutTimer.setSingleShot(true);
    connect(&m_timeoutTimer, &QTimer::timeout, this, [this]() {
        if (!m_process)
            return;
        m_timedOut = true;
        // Gesamte Gruppe hart beenden; das finished-Handling läuft danach normal.
        if (m_process->processId() > 0)
            ::killpg(m_process->processId(), SIGKILL);
        else
            m_process->kill();
    });
}

ProcessRunner::~ProcessRunner()
{
    // Teardown mit laufendem Prozess: die ganze Gruppe hart beenden (der
    // QProcess-Dtor würde nur das direkte Kind killen — Enkel, z.B. aus
    // run_command-Shells, überlebten als Waisen). Danach ASYNCHRON reapen,
    // nie blockieren: ein waitForFinished() kann bei einem Kind im D-State
    // (ununterbrechbarer Syscall) timeouten und ließe den QProcess-Dtor mit
    // "Destroyed while process is still running" zurück. Stattdessen den
    // QProcess vom Runner lösen — er löscht sich selbst, sobald das gekillte
    // Kind endet.
    if (m_process && m_process->state() != QProcess::NotRunning) {
        m_process->disconnect(this);
        if (m_process->processId() > 0)
            ::killpg(m_process->processId(), SIGKILL);
        m_process->kill();   // Fallback fürs direkte Kind vor setsid (Starting)
        m_process->setParent(nullptr);
        connect(m_process, &QProcess::finished, m_process, &QObject::deleteLater);
    }
}

bool ProcessRunner::running() const { return m_process != nullptr; }
int ProcessRunner::pid() const { return m_process ? int(m_process->processId()) : 0; }
int ProcessRunner::timeoutMs() const { return m_timeoutMs; }
int ProcessRunner::maxOutputBytes() const { return m_maxOutputBytes; }
bool ProcessRunner::mergeStderr() const { return m_mergeStderr; }
QString ProcessRunner::workingDirectory() const { return m_workingDirectory; }
QVariantMap ProcessRunner::environment() const { return m_environment; }

void ProcessRunner::setTimeoutMs(int ms)
{
    if (ms == m_timeoutMs) return;
    m_timeoutMs = ms;
    Q_EMIT timeoutMsChanged();
}
void ProcessRunner::setMaxOutputBytes(int bytes)
{
    if (bytes == m_maxOutputBytes) return;
    m_maxOutputBytes = bytes;
    Q_EMIT maxOutputBytesChanged();
}
void ProcessRunner::setMergeStderr(bool on)
{
    if (on == m_mergeStderr) return;
    m_mergeStderr = on;
    Q_EMIT mergeStderrChanged();
}
void ProcessRunner::setWorkingDirectory(const QString &dir)
{
    if (dir == m_workingDirectory) return;
    m_workingDirectory = dir;
    Q_EMIT workingDirectoryChanged();
}
void ProcessRunner::setEnvironment(const QVariantMap &env)
{
    if (env == m_environment) return;
    m_environment = env;
    Q_EMIT environmentChanged();
}

void ProcessRunner::appendCapped(QByteArray &buffer, const QByteArray &data, bool &truncatedFlag)
{
    if (buffer.size() >= m_maxOutputBytes) {
        truncatedFlag = true;
        return;
    }
    const int platz = m_maxOutputBytes - buffer.size();
    if (data.size() > platz) {
        buffer.append(data.left(platz));
        truncatedFlag = true;
    } else {
        buffer.append(data);
    }
}

void ProcessRunner::start(const QString &program, const QStringList &args)
{
    if (m_process)
        return; // läuft schon

    m_stdout.clear();
    m_stderr.clear();
    m_stdoutTruncated = false;
    m_stderrTruncated = false;
    m_timedOut = false;

    m_process = new QProcess(this);
    QProcess *proc = m_process;
    if (m_mergeStderr)
        m_process->setProcessChannelMode(QProcess::MergedChannels);
    if (!m_workingDirectory.isEmpty())
        m_process->setWorkingDirectory(m_workingDirectory);
    if (!m_environment.isEmpty()) {
        QProcessEnvironment pe = QProcessEnvironment::systemEnvironment();
        for (auto it = m_environment.constBegin(); it != m_environment.constEnd(); ++it)
            pe.insert(it.key(), it.value().toString());
        m_process->setProcessEnvironment(pe);
    }

    // Eigene Session -> Prozess ist Gruppen-/Session-Leader (pgid == pid),
    // damit killpg(pid, sig) die ganze Nachkommenschaft trifft.
    QProcess::UnixProcessParameters upp;
    upp.flags |= QProcess::UnixProcessFlag::CreateNewSession;
    m_process->setUnixProcessParameters(upp);

    connect(m_process, &QProcess::readyReadStandardOutput, this, [this]() {
        const QByteArray d = m_process->readAllStandardOutput();
        appendCapped(m_stdout, d, m_stdoutTruncated);
        Q_EMIT stdoutChunk(d);
    });
    connect(m_process, &QProcess::readyReadStandardError, this, [this]() {
        const QByteArray d = m_process->readAllStandardError();
        appendCapped(m_stderr, d, m_stderrTruncated);
        Q_EMIT stderrChunk(d);
    });
    connect(m_process, &QProcess::started, this, [this]() { Q_EMIT started(); });
    connect(m_process, &QProcess::errorOccurred, this, [this](QProcess::ProcessError e) {
        if (e == QProcess::FailedToStart) {
            const QString msg = m_process->errorString();
            cleanup();
            Q_EMIT failed(msg);
        }
    });
    connect(m_process, &QProcess::finished, this,
            [this](int code, QProcess::ExitStatus) {
        // restliche gepufferte Ausgabe abholen. Bei MergedChannels gibt es keinen
        // separaten stderr-Kanal mehr; readAllStandardError() würde dann nur eine
        // QWARN erzeugen (kein Fehler, aber unnötiger Lärm in der Testausgabe).
        appendCapped(m_stdout, m_process->readAllStandardOutput(), m_stdoutTruncated);
        if (!m_mergeStderr)
            appendCapped(m_stderr, m_process->readAllStandardError(), m_stderrTruncated);
        const int exitCode = code;
        const QString out = QString::fromUtf8(
            m_stdoutTruncated ? aurora::trimAufUtf8Grenze(m_stdout) : m_stdout);
        const QString err = QString::fromUtf8(
            m_stderrTruncated ? aurora::trimAufUtf8Grenze(m_stderr) : m_stderr);
        const bool trunc = m_stdoutTruncated || m_stderrTruncated;
        const bool timedOut = m_timedOut;
        cleanup();
        Q_EMIT finished(exitCode, out, err, trunc, timedOut);
    });

    m_process->start(program, args);
    // Re-Entranz-Schutz: Feuert failed() synchron und startet ein Handler
    // sofort neu, gehören Timer/notify dem NEUEN Lauf — nicht doppelt anfassen.
    // (Deckt den bisherigen `if (!m_process)`-Fall mit ab: nullptr != proc.)
    if (m_process != proc)
        return;
    Q_EMIT runningChanged();
    if (m_timeoutMs > 0)
        m_timeoutTimer.start(m_timeoutMs);
}

void ProcessRunner::writeStdin(const QByteArray &data)
{
    if (m_process)
        m_process->write(data);
}

void ProcessRunner::closeStdin()
{
    if (m_process)
        m_process->closeWriteChannel();
}

void ProcessRunner::terminate() { sendSignal(SIGTERM); }
void ProcessRunner::kill() { sendSignal(SIGKILL); }

void ProcessRunner::sendSignal(int sig)
{
    if (!m_process || m_process->processId() <= 0)
        return;
    ::killpg(m_process->processId(), sig);
}

void ProcessRunner::cleanup()
{
    m_timeoutTimer.stop();
    if (m_process) {
        m_process->disconnect(this);
        m_process->deleteLater();
        m_process = nullptr;
    }
    Q_EMIT runningChanged();
}
