#ifndef SESSIONMANAGER_H
#define SESSIONMANAGER_H

#include <QObject>
#include <QString>
#include <QMap>
#include <QTimer>
#include <memory>

class SshEngine;
class SshSession;
struct ConnectionConfig;

/**
 * Session state
 */
enum class SessionState {
    Disconnected,
    Connecting,
    Connected,
    Authenticating,
    Error,
    Reconnecting
};

/**
 * Session info for UI
 */
struct SessionInfo {
    QString id;
    QString host;
    int port;
    QString username;
    qint64 connectedAt;
    int keepAliveFailedCount;
    SessionState state;
};

/**
 * Session Manager - handles multiple SSH sessions
 * Provides session lifecycle management, auto-reconnect, and keepalive
 */
class SessionManager : public QObject
{
    Q_OBJECT

public:
    explicit SessionManager(SshEngine* engine, QObject *parent = nullptr);
    ~SessionManager();

    // Create and start a new session
    void createSession(const QString& sessionId, const QString& host, int port,
                      const QString& username, const QString& password,
                      const ConnectionConfig& config = ConnectionConfig());

    // Close a session
    bool closeSession(const QString& sessionId);

    // Get session by ID
    std::shared_ptr<SshSession> getSession(const QString& sessionId) const;

    // Get all active sessions
    QList<SessionInfo> getAllSessions() const;

    // Get session count
    int getSessionCount() const;

    // Check if session exists
    bool hasSession(const QString& sessionId) const;

signals:
    void sessionCreated(const QString& sessionId);
    void sessionClosed(const QString& sessionId);
    void sessionStateChanged(const QString& sessionId, SessionState state);
    void keepAliveFailed(const QString& sessionId, int attempt);
    void reconnecting(const QString& sessionId, int attempt);

private slots:
    void checkKeepAlive();

private:
    void startKeepAlive(const QString& sessionId);
    void attemptReconnect(const QString& sessionId, int attempt = 1);

    SshEngine* m_engine;
    QMap<QString, std::shared_ptr<SshSession>> m_sessions;
    QMap<QString, int> m_keepAliveFailedCounts;
    QTimer* m_keepAliveTimer;
};

#endif // SESSIONMANAGER_H
