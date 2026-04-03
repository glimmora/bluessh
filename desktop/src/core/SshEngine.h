#ifndef SSHENGINE_H
#define SSHENGINE_H

#include <QObject>
#include <QString>
#include <QMap>
#include <QMutex>
#include <functional>
#include <memory>
#include <libssh2.h>
#include <libssh2_sftp.h>

class SshSession;
struct ConnectionConfig;

/**
 * Core SSH Engine using libssh2
 * Handles all SSH/SFTP/SCP connections and operations
 */
class SshEngine : public QObject
{
    Q_OBJECT

public:
    explicit SshEngine(QObject *parent = nullptr);
    ~SshEngine();

    // Initialize the engine
    bool initialize();
    
    // Shutdown the engine
    void shutdown();

    // Connect to SSH server with password authentication
    std::shared_ptr<SshSession> connectPassword(
        const QString& sessionId,
        const QString& host,
        int port,
        const QString& username,
        const QString& password,
        const ConnectionConfig& config = ConnectionConfig()
    );

    // Connect to SSH server with public key authentication
    std::shared_ptr<SshSession> connectPublicKey(
        const QString& sessionId,
        const QString& host,
        int port,
        const QString& username,
        const QString& privateKeyPath,
        const QString& passphrase = QString(),
        const ConnectionConfig& config = ConnectionConfig()
    );

    // Connect with keyboard-interactive authentication (for MFA)
    std::shared_ptr<SshSession> connectKeyboardInteractive(
        const QString& sessionId,
        const QString& host,
        int port,
        const QString& username,
        const QString& password,
        const QString& mfaCode = QString(),
        const ConnectionConfig& config = ConnectionConfig()
    );

    // Disconnect a session
    bool disconnect(const QString& sessionId);

    // Get session by ID
    std::shared_ptr<SshSession> getSession(const QString& sessionId) const;

    // Get all active sessions
    QList<std::shared_ptr<SshSession>> getAllSessions() const;

    // Send keepalive
    bool sendKeepAlive(const QString& sessionId);

    // Check if engine is initialized
    bool isInitialized() const { return m_initialized; }

signals:
    void sessionConnected(const QString& sessionId);
    void sessionDisconnected(const QString& sessionId);
    void sessionError(const QString& sessionId, const QString& error);
    void connectionStateChanged(bool connected);

private:
    LIBSSH2_SESSION* createSession(int socket);
    bool authenticatePassword(LIBSSH2_SESSION* session, const QString& username, const QString& password);
    bool authenticatePublicKey(LIBSSH2_SESSION* session, const QString& username, const QString& privateKeyPath, const QString& passphrase);
    bool authenticateKeyboardInteractive(LIBSSH2_SESSION* session, const QString& username, const QString& password, const QString& mfaCode);

    LIBSSH2_SESSION* m_libssh2Session = nullptr;
    bool m_initialized = false;
    QMap<QString, std::shared_ptr<SshSession>> m_sessions;
    mutable QMutex m_mutex;
};

/**
 * Connection configuration
 */
struct ConnectionConfig {
    int timeout = 30000;              // Connection timeout in ms
    int keepAliveInterval = 30000;    // Keepalive interval in ms
    int maxReconnectAttempts = 5;     // Max reconnect attempts
    int compressionLevel = 0;         // 0=none, 1=low, 2=medium, 3=high
    QString ptyType = "xterm-256color";
    int ptyWidth = 80;
    int ptyHeight = 24;
    bool enableAgentForwarding = false;
    bool enableX11Forwarding = false;
    QMap<QString, QString> environmentVariables;
    QString jumpHost;
    int jumpHostPort = 22;
};

/**
 * Connection state
 */
enum class ConnectionState {
    Disconnected,
    Connecting,
    Connected,
    Error
};

#endif // SSHENGINE_H
