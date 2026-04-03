#ifndef SSHSESSION_H
#define SSHSESSION_H

#include <QObject>
#include <QString>
#include <QByteArray>
#include <QMutex>
#include <functional>
#include <memory>
#include <libssh2.h>
#include <libssh2_sftp.h>

class QTcpSocket;
struct ConnectionConfig;

/**
 * SSH Session wrapper
 * Manages a single SSH connection with channel support
 */
class SshSession : public QObject
{
    Q_OBJECT

public:
    explicit SshSession(
        const QString& sessionId,
        LIBSSH2_SESSION* session,
        QTcpSocket* socket,
        const ConnectionConfig& config,
        QObject *parent = nullptr
    );
    
    ~SshSession();

    // Get session ID
    QString sessionId() const { return m_sessionId; }

    // Get libssh2 session handle
    LIBSSH2_SESSION* libssh2Session() const { return m_session; }

    // Get connection config
    const ConnectionConfig& config() const { return m_config; }

    // Check if session is connected
    bool isConnected() const { return m_connected; }

    // Create shell channel for terminal
    LIBSSH2_CHANNEL* createShellChannel();

    // Execute command and return output
    QByteArray executeCommand(const QString& command);

    // Setup local port forwarding
    bool setupLocalForwarding(int localPort, const QString& remoteHost, int remotePort);

    // Setup remote port forwarding
    bool setupRemoteForwarding(int remotePort, const QString& localHost, int localPort);

    // Setup dynamic forwarding (SOCKS5)
    bool setupDynamicForwarding(int localPort);

    // Create SFTP session
    LIBSSH2_SFTP* createSftpSession();

    // Send keepalive
    bool sendKeepAlive();

    // Resize PTY
    bool resizePty(int width, int height);

    // Disconnect session
    void disconnect();

signals:
    void dataReceived(const QByteArray& data);
    void channelClosed();
    void errorOccurred(const QString& error);
    void disconnected();

private:
    QString m_sessionId;
    LIBSSH2_SESSION* m_session;
    QTcpSocket* m_socket;
    ConnectionConfig m_config;
    bool m_connected = false;
    mutable QMutex m_mutex;
};

#endif // SSHSESSION_H
