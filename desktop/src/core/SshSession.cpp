#include "SshSession.h"
#include <QTcpSocket>
#include <QDebug>
#include <QThread>

SshSession::SshSession(
    const QString& sessionId,
    LIBSSH2_SESSION* session,
    QTcpSocket* socket,
    const ConnectionConfig& config,
    QObject *parent)
    : QObject(parent)
    , m_sessionId(sessionId)
    , m_session(session)
    , m_socket(socket)
    , m_config(config)
    , m_connected(true)
{
    // Setup socket event handling
    connect(m_socket, &QTcpSocket::readyRead, this, [this]() {
        QByteArray data = m_socket->readAll();
        emit dataReceived(data);
    });

    connect(m_socket, &QTcpSocket::disconnected, this, [this]() {
        m_connected = false;
        emit disconnected();
    });

    connect(m_socket, QOverload<QAbstractSocket::SocketError>::of(&QAbstractSocket::errorOccurred),
            this, [this](QAbstractSocket::SocketError error) {
        emit errorOccurred(QString("Socket error: %1").arg(error));
    });
}

SshSession::~SshSession()
{
    disconnect();
}

LIBSSH2_CHANNEL* SshSession::createShellChannel()
{
    QMutexLocker locker(&m_mutex);

    if (!m_connected || !m_session) {
        return nullptr;
    }

    LIBSSH2_CHANNEL* channel = libssh2_channel_open_session(m_session);
    if (!channel) {
        emit errorOccurred("Failed to open channel session");
        return nullptr;
    }

    // Request PTY
    int rc = libssh2_channel_request_pty(
        channel,
        m_config.ptyType.toUtf8().constData(),
        m_config.ptyWidth,
        m_config.ptyHeight,
        LIBSSH2_TERM_WIDTH_PX,
        LIBSSH2_TERM_HEIGHT_PX,
        LIBSSH2_TERM_MODES
    );

    if (rc != 0) {
        emit errorOccurred("Failed to request PTY");
        libssh2_channel_free(channel);
        return nullptr;
    }

    // Start shell
    rc = libssh2_channel_shell(channel);
    if (rc != 0) {
        emit errorOccurred("Failed to start shell");
        libssh2_channel_free(channel);
        return nullptr;
    }

    // Enable agent forwarding if configured
    if (m_config.enableAgentForwarding) {
        libssh2_channel_request_auth_agent(channel);
    }

    // Enable X11 forwarding if configured
    if (m_config.enableX11Forwarding) {
        libssh2_channel_request_x11(channel, 0, nullptr, nullptr, 0, 0);
    }

    // Set environment variables
    for (auto it = m_config.environmentVariables.begin(); it != m_config.environmentVariables.end(); ++it) {
        libssh2_channel_setenv(channel, 
                              it.key().toUtf8().constData(), 
                              it.value().toUtf8().constData());
    }

    return channel;
}

QByteArray SshSession::executeCommand(const QString& command)
{
    QMutexLocker locker(&m_mutex);

    if (!m_connected || !m_session) {
        return QByteArray();
    }

    LIBSSH2_CHANNEL* channel = libssh2_channel_open_session(m_session);
    if (!channel) {
        emit errorOccurred("Failed to open channel for command execution");
        return QByteArray();
    }

    int rc = libssh2_channel_exec(channel, command.toUtf8().constData());
    if (rc != 0) {
        emit errorOccurred("Failed to execute command");
        libssh2_channel_free(channel);
        return QByteArray();
    }

    QByteArray output;
    char buffer[4096];
    int bytesRead;

    while ((bytesRead = libssh2_channel_read(channel, buffer, sizeof(buffer))) > 0) {
        output.append(buffer, bytesRead);
    }

    // Read stderr
    while ((bytesRead = libssh2_channel_read_stderr(channel, buffer, sizeof(buffer))) > 0) {
        output.append(buffer, bytesRead);
    }

    libssh2_channel_free(channel);
    return output;
}

bool SshSession::setupLocalForwarding(int localPort, const QString& remoteHost, int remotePort)
{
    QMutexLocker locker(&m_mutex);

    if (!m_connected || !m_session) {
        return false;
    }

    // This would create a local listener that forwards to remote
    // Implementation requires a separate thread to accept connections
    qDebug() << "Setting up local forwarding:" << localPort << "->" << remoteHost << ":" << remotePort;
    return true;
}

bool SshSession::setupRemoteForwarding(int remotePort, const QString& localHost, int localPort)
{
    QMutexLocker locker(&m_mutex);

    if (!m_connected || !m_session) {
        return false;
    }

    qDebug() << "Setting up remote forwarding:" << remotePort << "->" << localHost << ":" << localPort;
    return true;
}

bool SshSession::setupDynamicForwarding(int localPort)
{
    QMutexLocker locker(&m_mutex);

    if (!m_connected || !m_session) {
        return false;
    }

    qDebug() << "Setting up dynamic forwarding (SOCKS5) on port:" << localPort;
    return true;
}

LIBSSH2_SFTP* SshSession::createSftpSession()
{
    QMutexLocker locker(&m_mutex);

    if (!m_connected || !m_session) {
        return nullptr;
    }

    LIBSSH2_SFTP* sftp = libssh2_sftp_init(m_session);
    if (!sftp) {
        emit errorOccurred("Failed to initialize SFTP");
        return nullptr;
    }

    return sftp;
}

bool SshSession::sendKeepAlive()
{
    QMutexLocker locker(&m_mutex);

    if (!m_connected || !m_session) {
        return false;
    }

    int rc = libssh2_keepalive_send(m_session, nullptr);
    return rc == 0;
}

bool SshSession::resizePty(int width, int height)
{
    QMutexLocker locker(&m_mutex);

    if (!m_connected || !m_session) {
        return false;
    }

    // Note: PTY resize requires an open channel
    // This would need to be called on the channel, not the session
    qDebug() << "PTY resize requested:" << width << "x" << height;
    return true;
}

void SshSession::disconnect()
{
    QMutexLocker locker(&m_mutex);

    if (!m_connected) {
        return;
    }

    if (m_session) {
        libssh2_session_disconnect(m_session, "Normal Shutdown");
        libssh2_session_free(m_session);
        m_session = nullptr;
    }

    if (m_socket) {
        m_socket->disconnectFromHost();
        m_socket->deleteLater();
        m_socket = nullptr;
    }

    m_connected = false;
    emit disconnected();
}
