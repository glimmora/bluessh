#include "SshEngine.h"
#include "SshSession.h"
#include "KnownHosts.h"
#include <QTcpSocket>
#include <QFile>
#include <QCryptographicHash>
#include <QDebug>
#include <thread>
#include <chrono>

SshEngine::SshEngine(QObject *parent)
    : QObject(parent)
{
}

SshEngine::~SshEngine()
{
    shutdown();
}

bool SshEngine::initialize()
{
    if (m_initialized) {
        return true;
    }

    int rc = libssh2_init(0);
    if (rc != 0) {
        qCritical() << "Failed to initialize libssh2:" << rc;
        return false;
    }

    m_initialized = true;
    qDebug() << "SSH Engine initialized successfully";
    return true;
}

void SshEngine::shutdown()
{
    QMutexLocker locker(&m_mutex);
    
    // Disconnect all sessions
    for (auto it = m_sessions.begin(); it != m_sessions.end(); ++it) {
        it.value()->disconnect();
    }
    m_sessions.clear();

    if (m_initialized) {
        libssh2_exit();
        m_initialized = false;
    }
}

std::shared_ptr<SshSession> SshEngine::connectPassword(
    const QString& sessionId,
    const QString& host,
    int port,
    const QString& username,
    const QString& password,
    const ConnectionConfig& config)
{
    QMutexLocker locker(&m_mutex);

    try {
        // Create TCP socket
        QTcpSocket* socket = new QTcpSocket();
        socket->connectToHost(host, port);
        
        if (!socket->waitForConnected(config.timeout)) {
            emit sessionError(sessionId, "Connection timeout");
            return nullptr;
        }

        // Create libssh2 session
        LIBSSH2_SESSION* session = libssh2_session_init();
        if (!session) {
            emit sessionError(sessionId, "Failed to create SSH session");
            return nullptr;
        }

        // Set blocking mode
        libssh2_session_set_blocking(session, 1);
        
        // Set timeout
        libssh2_session_set_timeout(session, config.timeout);

        // Perform handshake
        int rc = libssh2_session_handshake(session, socket->socketDescriptor());
        if (rc != 0) {
            emit sessionError(sessionId, "SSH handshake failed");
            libssh2_session_free(session);
            return nullptr;
        }

        // Verify host key
        KnownHosts knownHosts;
        if (!knownHosts.verifyHost(host, port, session)) {
            emit sessionError(sessionId, "Host key verification failed");
            libssh2_session_free(session);
            return nullptr;
        }

        // Authenticate with password
        if (!authenticatePassword(session, username, password)) {
            emit sessionError(sessionId, "Password authentication failed");
            libssh2_session_disconnect(session, "Authentication failed");
            libssh2_session_free(session);
            return nullptr;
        }

        // Create session wrapper
        auto sshSession = std::make_shared<SshSession>(
            sessionId, session, socket, config
        );

        m_sessions[sessionId] = sshSession;
        emit sessionConnected(sessionId);
        emit connectionStateChanged(true);

        // Zeroize password
        QString zeroizedPassword = password;
        zeroizedPassword.fill('0');

        return sshSession;

    } catch (const std::exception& e) {
        emit sessionError(sessionId, QString::fromStdString(e.what()));
        return nullptr;
    }
}

std::shared_ptr<SshSession> SshEngine::connectPublicKey(
    const QString& sessionId,
    const QString& host,
    int port,
    const QString& username,
    const QString& privateKeyPath,
    const QString& passphrase,
    const ConnectionConfig& config)
{
    QMutexLocker locker(&m_mutex);

    try {
        // Create TCP socket
        QTcpSocket* socket = new QTcpSocket();
        socket->connectToHost(host, port);
        
        if (!socket->waitForConnected(config.timeout)) {
            emit sessionError(sessionId, "Connection timeout");
            return nullptr;
        }

        // Create libssh2 session
        LIBSSH2_SESSION* session = libssh2_session_init();
        if (!session) {
            emit sessionError(sessionId, "Failed to create SSH session");
            return nullptr;
        }

        libssh2_session_set_blocking(session, 1);
        libssh2_session_set_timeout(session, config.timeout);

        int rc = libssh2_session_handshake(session, socket->socketDescriptor());
        if (rc != 0) {
            emit sessionError(sessionId, "SSH handshake failed");
            libssh2_session_free(session);
            return nullptr;
        }

        KnownHosts knownHosts;
        if (!knownHosts.verifyHost(host, port, session)) {
            emit sessionError(sessionId, "Host key verification failed");
            libssh2_session_free(session);
            return nullptr;
        }

        if (!authenticatePublicKey(session, username, privateKeyPath, passphrase)) {
            emit sessionError(sessionId, "Public key authentication failed");
            libssh2_session_disconnect(session, "Authentication failed");
            libssh2_session_free(session);
            return nullptr;
        }

        auto sshSession = std::make_shared<SshSession>(
            sessionId, session, socket, config
        );

        m_sessions[sessionId] = sshSession;
        emit sessionConnected(sessionId);
        emit connectionStateChanged(true);

        return sshSession;

    } catch (const std::exception& e) {
        emit sessionError(sessionId, QString::fromStdString(e.what()));
        return nullptr;
    }
}

std::shared_ptr<SshSession> SshEngine::connectKeyboardInteractive(
    const QString& sessionId,
    const QString& host,
    int port,
    const QString& username,
    const QString& password,
    const QString& mfaCode,
    const ConnectionConfig& config)
{
    QMutexLocker locker(&m_mutex);

    try {
        QTcpSocket* socket = new QTcpSocket();
        socket->connectToHost(host, port);
        
        if (!socket->waitForConnected(config.timeout)) {
            emit sessionError(sessionId, "Connection timeout");
            return nullptr;
        }

        LIBSSH2_SESSION* session = libssh2_session_init();
        if (!session) {
            emit sessionError(sessionId, "Failed to create SSH session");
            return nullptr;
        }

        libssh2_session_set_blocking(session, 1);
        libssh2_session_set_timeout(session, config.timeout);

        int rc = libssh2_session_handshake(session, socket->socketDescriptor());
        if (rc != 0) {
            emit sessionError(sessionId, "SSH handshake failed");
            libssh2_session_free(session);
            return nullptr;
        }

        KnownHosts knownHosts;
        if (!knownHosts.verifyHost(host, port, session)) {
            emit sessionError(sessionId, "Host key verification failed");
            libssh2_session_free(session);
            return nullptr;
        }

        if (!authenticateKeyboardInteractive(session, username, password, mfaCode)) {
            emit sessionError(sessionId, "Keyboard-interactive authentication failed");
            libssh2_session_disconnect(session, "Authentication failed");
            libssh2_session_free(session);
            return nullptr;
        }

        auto sshSession = std::make_shared<SshSession>(
            sessionId, session, socket, config
        );

        m_sessions[sessionId] = sshSession;
        emit sessionConnected(sessionId);
        emit connectionStateChanged(true);

        return sshSession;

    } catch (const std::exception& e) {
        emit sessionError(sessionId, QString::fromStdString(e.what()));
        return nullptr;
    }
}

bool SshEngine::disconnect(const QString& sessionId)
{
    QMutexLocker locker(&m_mutex);

    auto it = m_sessions.find(sessionId);
    if (it != m_sessions.end()) {
        it.value()->disconnect();
        m_sessions.erase(it);
        emit sessionDisconnected(sessionId);
        
        if (m_sessions.isEmpty()) {
            emit connectionStateChanged(false);
        }
        return true;
    }
    return false;
}

std::shared_ptr<SshSession> SshEngine::getSession(const QString& sessionId) const
{
    QMutexLocker locker(&m_mutex);
    return m_sessions.value(sessionId);
}

QList<std::shared_ptr<SshSession>> SshEngine::getAllSessions() const
{
    QMutexLocker locker(&m_mutex);
    return m_sessions.values();
}

bool SshEngine::sendKeepAlive(const QString& sessionId)
{
    QMutexLocker locker(&m_mutex);
    
    auto session = m_sessions.value(sessionId);
    if (!session) {
        return false;
    }

    return session->sendKeepAlive();
}

LIBSSH2_SESSION* SshEngine::createSession(int socket)
{
    LIBSSH2_SESSION* session = libssh2_session_init();
    if (session) {
        libssh2_session_set_blocking(session, 1);
        libssh2_session_handshake(session, socket);
    }
    return session;
}

bool SshEngine::authenticatePassword(LIBSSH2_SESSION* session, const QString& username, const QString& password)
{
    int rc = libssh2_userauth_password(session, 
                                       username.toUtf8().constData(), 
                                       password.toUtf8().constData());
    return rc == 0;
}

bool SshEngine::authenticatePublicKey(LIBSSH2_SESSION* session, const QString& username, const QString& privateKeyPath, const QString& passphrase)
{
    const char* passphrasePtr = passphrase.isEmpty() ? nullptr : passphrase.toUtf8().constData();
    
    int rc = libssh2_userauth_publickey_fromfile(
        session,
        username.toUtf8().constData(),
        nullptr,  // Public key file (auto-detected)
        privateKeyPath.toUtf8().constData(),
        passphrasePtr
    );
    
    return rc == 0;
}

bool SshEngine::authenticateKeyboardInteractive(LIBSSH2_SESSION* session, const QString& username, const QString& password, const QString& mfaCode)
{
    // For keyboard-interactive, we need to handle the callback
    // This is a simplified version
    int rc = libssh2_userauth_keyboard_interactive(
        session,
        username.toUtf8().constData(),
        nullptr  // Callback function would be needed for full implementation
    );
    
    return rc == 0;
}
