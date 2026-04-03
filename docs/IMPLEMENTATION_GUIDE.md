# BlueSSH Implementation Guide

## Complete Bitvise-Compatible SSH Client

This guide provides detailed implementation instructions for all components of the BlueSSH SSH client.

## Table of Contents

1. [Terminal Emulation](#terminal-emulation)
2. [SFTP Graphical Interface](#sftp-graphical-interface)
3. [Port Forwarding](#port-forwarding)
4. [Authentication](#authentication)
5. [Profile Management](#profile-management)
6. [CLI Tools](#cli-tools)
7. [Auto-Reconnect](#auto-reconnect)
8. [IPv6 Support](#ipv6-support)
9. [Multi-Terminal Sessions](#multi-terminal-sessions)
10. [RDP Bridge](#rdp-bridge)
11. [Portable Distribution](#portable-distribution)
12. [Security Best Practices](#security-best-practices)

---

## Terminal Emulation

### Architecture

The terminal emulation system supports three terminal types:
- **xterm-256color**: Full xterm with 256 colors and true color (24-bit)
- **vt100**: DEC VT100 compatibility mode
- **bvterm**: BlueSSH enhanced terminal with additional features

### Implementation

```cpp
// TerminalEmulator.h - Core terminal emulation interface
class TerminalEmulator : public QObject {
    Q_OBJECT
public:
    void feed(const QByteArray& data);           // Process incoming data
    void write(const QByteArray& data);          // Send data to SSH
    void resize(int cols, int rows);             // Resize terminal
    const ScreenBuffer& getScreen() const;       // Get screen buffer
    QString getSelectedText() const;             // Get selected text
    
signals:
    void screenChanged();                        // Screen updated
    void titleChanged(const QString& title);     // Window title changed
    void bell();                                 // Bell character received
    void sendData(const QByteArray& data);       // Data to send to SSH
};
```

### Key Features

1. **ANSI Escape Sequence Parsing**
   - CSI sequences (cursor movement, colors, etc.)
   - OSC sequences (window title, colors)
   - DCS sequences (device control)
   - Private mode sequences (DECSET/DECRST)

2. **Screen Buffer Management**
   - Primary and alternate screen buffers
   - Scrollback buffer (configurable size)
   - Selection handling
   - Line wrapping

3. **Color Support**
   - 16 standard colors
   - 256 color palette
   - True color (24-bit RGB)

4. **Terminal Modes**
   - Application cursor keys
   - Bracketed paste mode
   - Mouse tracking (X10, VT200, SGR)
   - Auto-wrap mode
   - Origin mode

### Example Usage

```cpp
auto terminal = std::make_unique<TerminalEmulator>(TerminalType::Xterm, 80, 24);

// Connect signals
connect(terminal.get(), &TerminalEmulator::screenChanged, this, [this]() {
    updateDisplay();
});

connect(terminal.get(), &TerminalEmulator::sendData, this, [this](const QByteArray& data) {
    sshSession->write(data);
});

// Process data from SSH
sshSession->onData([terminal](const QByteArray& data) {
    terminal->feed(data);
});

// Handle keyboard input
terminalWidget->onKeyPress([terminal](const QString& text) {
    terminal->write(text.toUtf8());
});
```

---

## SFTP Graphical Interface

### Architecture

The SFTP interface provides a dual-pane file browser with drag-and-drop support:

```
┌─────────────────┬─────────────────┐
│  Local Files    │  Remote Files   │
│  (QTreeView)    │  (QTreeView)    │
│                 │                 │
│  - Navigate     │  - Navigate     │
│  - Select       │  - Select       │
│  - Drag source  │  - Drop target  │
└────────┬────────┴────────┬────────┘
         │                 │
         └──────┬──────────┘
                │
         Transfer Queue
         - Upload/Download
         - Progress tracking
         - Pause/Resume
```

### Implementation

```cpp
// SftpWidget.h - Graphical SFTP interface
class SftpWidget : public QWidget {
    Q_OBJECT
public:
    void navigateTo(const QString& path);
    void refresh();
    void uploadFiles(const QStringList& localPaths);
    void downloadFiles(const QStringList& remotePaths);
    
protected:
    void dragEnterEvent(QDragEnterEvent *event) override;
    void dropEvent(QDropEvent *event) override;
    
signals:
    void transferStarted(const TransferItem& item);
    void transferProgress(const TransferItem& item);
    void transferComplete(const TransferItem& item);
};
```

### Drag-and-Drop Implementation

```cpp
void SftpWidget::dragEnterEvent(QDragEnterEvent *event) {
    if (event->mimeData()->hasUrls()) {
        event->acceptProposedAction();
        m_isDragTarget = true;
        update();
    }
}

void SftpWidget::dropEvent(QDropEvent *event) {
    if (event->mimeData()->hasUrls()) {
        QStringList localPaths;
        for (const QUrl& url : event->mimeData()->urls()) {
            localPaths.append(url.toLocalFile());
        }
        onUploadFiles(localPaths);
    }
    m_isDragTarget = false;
    update();
}
```

### Transfer Queue

```cpp
struct TransferItem {
    QString localPath;
    QString remotePath;
    qint64 size;
    qint64 transferred;
    bool isUpload;
    bool isPaused;
    bool isComplete;
};

class TransferQueue : public QObject {
    Q_OBJECT
public:
    void enqueue(const TransferItem& item);
    void pause(const QString& itemId);
    void resume(const QString& itemId);
    void cancel(const QString& itemId);
    
signals:
    void itemStarted(const TransferItem& item);
    void itemProgress(const TransferItem& item);
    void itemComplete(const TransferItem& item);
};
```

---

## Port Forwarding

### Dynamic Forwarding (SOCKS/HTTP Proxy)

Supports SOCKS4, SOCKS4A, SOCKS5, and HTTP proxy protocols:

```cpp
// SOCKS5 handshake example
bool DynamicForwardingManager::handleSocks5Negotiation(QTcpSocket* client) {
    // Read methods
    QByteArray data = client->readAll();
    if (data.size() < 2) return false;
    
    quint8 nmethods = data[1];
    if (data.size() < 2 + nmethods) return false;
    
    // Select method (0x00 = no auth)
    QByteArray response;
    response.append('\x05');  // SOCKS5 version
    response.append('\x00');  // No authentication
    client->write(response);
    
    return true;
}

// SOCKS5 connection request
bool DynamicForwardingManager::handleSocks5Request(QTcpSocket* client, 
                                                    QString& host, int& port) {
    QByteArray data = client->readAll();
    if (data.size() < 7) return false;
    
    quint8 cmd = data[1];      // Command (CONNECT = 0x01)
    quint8 atyp = data[3];     // Address type
    
    if (cmd != 0x01) return false;  // Only support CONNECT
    
    if (atyp == 0x01) {  // IPv4
        QHostAddress addr(ntohl(*reinterpret_cast<quint32*>(data.data() + 4)));
        host = addr.toString();
        port = ntohs(*reinterpret_cast<quint16*>(data.data() + 8));
    } else if (atyp == 0x03) {  // Domain name
        quint8 len = data[4];
        host = QString::fromUtf8(data.mid(5, len));
        port = ntohs(*reinterpret_cast<quint16*>(data.data() + 5 + len));
    } else if (atyp == 0x04) {  // IPv6
        // Handle IPv6 address
    }
    
    return true;
}
```

### Static Forwarding (C2S & S2C)

```cpp
// Client-to-Server (Local) Forwarding
bool StaticForwardingManager::startLocalForwarding(const StaticForwardingRule& rule) {
    QTcpServer* server = new QTcpServer(this);
    
    if (!server->listen(QHostAddress(rule.listenHost), rule.listenPort)) {
        emit forwardingError(rule.id, server->errorString());
        return false;
    }
    
    connect(server, &QTcpServer::newConnection, this, [this, server, rule]() {
        QTcpSocket* client = server->nextPendingConnection();
        handleLocalConnection(client, rule.id);
    });
    
    m_localServers[rule.id] = server;
    emit forwardingStarted(rule.id);
    return true;
}

// Server-to-Client (Remote) Forwarding
bool StaticForwardingManager::startRemoteForwarding(const StaticForwardingRule& rule) {
    // Request remote forwarding from SSH server
    int rc = libssh2_channel_forward_listen_ex(
        m_sshSession,
        rule.listenHost.toUtf8().constData(),
        rule.listenPort,
        nullptr,
        16  // Max backlog
    );
    
    if (rc != 0) {
        emit forwardingError(rule.id, "Failed to setup remote forwarding");
        return false;
    }
    
    emit forwardingStarted(rule.id);
    return true;
}
```

---

## Authentication

### Public Key Authentication

Supports RSA, ECDSA, and Ed25519:

```cpp
bool SshEngine::authenticatePublicKey(LIBSSH2_SESSION* session, 
                                       const QString& username,
                                       const QString& privateKeyPath,
                                       const QString& passphrase) {
    const char* passphrasePtr = passphrase.isEmpty() ? nullptr 
                                                     : passphrase.toUtf8().constData();
    
    int rc = libssh2_userauth_publickey_fromfile(
        session,
        username.toUtf8().constData(),
        nullptr,  // Public key file (auto-detected)
        privateKeyPath.toUtf8().constData(),
        passphrasePtr
    );
    
    if (rc == 0) {
        return true;
    }
    
    // Try agent authentication if file auth fails
    return libssh2_userauth_publickey_frommemory(session, 
                                                  username.toUtf8().constData(),
                                                  nullptr, 0,
                                                  keyData, keyDataLen,
                                                  passphrasePtr) == 0;
}
```

### GSSAPI/Kerberos Authentication

```cpp
bool GssapiAuth::initContext(const QString& targetName) {
    m_targetName = targetName;
    
    OM_uint32 maj_stat, min_stat;
    gss_buffer_desc target_name_buf;
    gss_name_t target_name;
    
    // Import target name
    target_name_buf.value = (void*)targetName.toUtf8().constData();
    target_name_buf.length = targetName.size();
    
    maj_stat = gss_import_name(&min_stat, &target_name_buf,
                               GSS_C_NT_HOSTBASED_SERVICE, &target_name);
    if (GSS_ERROR(maj_stat)) return false;
    
    // Initialize context
    maj_stat = gss_init_sec_context(&min_stat,
                                     GSS_C_NO_CREDENTIAL,
                                     &m_contextHandle,
                                     target_name,
                                     GSS_C_NO_OID,
                                     GSS_C_MUTUAL_FLAG | GSS_C_REPLAY_FLAG,
                                     0,
                                     GSS_C_NO_CHANNEL_BINDINGS,
                                     GSS_C_NO_BUFFER,
                                     nullptr,
                                     &m_contextToken,
                                     nullptr,
                                     nullptr);
    
    return !GSS_ERROR(maj_stat);
}
```

---

## Profile Management (.bvc Files)

### XML Format

```xml
<?xml version="1.0" encoding="UTF-8"?>
<BlueSSHProfile version="1.0">
    <ProfileMetadata>
        <Name>Production Server</Name>
        <Id>{uuid}</Id>
        <Created>2024-01-01T00:00:00</Created>
        <Modified>2024-01-01T00:00:00</Modified>
    </ProfileMetadata>
    
    <Server>
        <Host>example.com</Host>
        <Port>22</Port>
        <Username>admin</Username>
        <InitialMethod>publickey</InitialMethod>
    </Server>
    
    <Authentication>
        <Method>publickey</Method>
        <KeyPath>~/.ssh/id_ed25519</KeyPath>
        <TryKeyboardInteractive>true</TryKeyboardInteractive>
        <TryGssapi>false</TryGssapi>
    </Authentication>
    
    <Terminal>
        <Type>xterm-256color</Type>
        <Columns>80</Columns>
        <Rows>24</Rows>
        <EnablePty>true</EnablePty>
        <EnableAgentForwarding>false</EnableAgentForwarding>
        <EnableX11Forwarding>false</EnableX11Forwarding>
    </Terminal>
    
    <Sftp>
        <EnableSftp>true</EnableSftp>
        <InitialRemoteDirectory>/home/admin</InitialRemoteDirectory>
        <TransferThreads>4</TransferThreads>
        <AutoResume>true</AutoResume>
    </Sftp>
    
    <Forwarding>
        <EnableForwarding>true</EnableForwarding>
        <Rule>
            <Type>local</Type>
            <ListenHost>127.0.0.1</ListenHost>
            <ListenPort>8080</ListenPort>
            <TargetHost>localhost</TargetHost>
            <TargetPort>80</TargetPort>
            <Enabled>true</Enabled>
        </Rule>
    </Forwarding>
    
    <Connection>
        <Timeout>30</Timeout>
        <KeepaliveInterval>30</KeepaliveInterval>
        <AutoReconnect>true</AutoReconnect>
        <MaxReconnectAttempts>5</MaxReconnectAttempts>
        <EnableIPv6>true</EnableIPv6>
    </Connection>
</BlueSSHProfile>
```

### Profile Manager Implementation

```cpp
bool BvcProfileManager::loadProfile(const QString& filePath, BvcProfile& profile) {
    QFile file(filePath);
    if (!file.open(QIODevice::ReadOnly)) return false;
    
    QDomDocument doc;
    if (!doc.setContent(&file)) {
        file.close();
        return false;
    }
    file.close();
    
    QDomElement root = doc.documentElement();
    if (root.tagName() != "BlueSSHProfile") return false;
    
    // Parse metadata
    QDomElement metadata = root.firstChildElement("ProfileMetadata");
    profile.profileName = readElementText(metadata, "Name");
    profile.profileId = readElementText(metadata, "Id");
    
    // Parse server settings
    QDomElement server = root.firstChildElement("Server");
    profile.host = readElementText(server, "Host");
    profile.port = readElementInt(server, "Port", 22);
    profile.username = readElementText(server, "Username");
    
    // Parse other sections...
    parseAuthentication(root.firstChildElement("Authentication"), profile.auth);
    parseTerminal(root.firstChildElement("Terminal"), profile.terminal);
    parseSftp(root.firstChildElement("Sftp"), profile.sftp);
    parseForwarding(root.firstChildElement("Forwarding"), profile.forwarding);
    parseConnection(root.firstChildElement("Connection"), profile.connection);
    
    emit profileLoaded(filePath);
    return true;
}
```

---

## CLI Tools

### sftpc - SFTP Command-Line Client

```python
#!/usr/bin/env python3
"""sftpc - BlueSSH SFTP Command-Line Client"""

import sys
import argparse
from bluessh import SftpClient, ProfileManager

def main():
    parser = argparse.ArgumentParser(description='BlueSSH SFTP Client')
    parser.add_argument('host', nargs='?', help='[USER@]HOST[:PORT]')
    parser.add_argument('-p', '--profile', help='Profile file (.bvc)')
    parser.add_argument('-i', '--identity', help='Identity file')
    parser.add_argument('-P', '--port', type=int, default=22)
    parser.add_argument('-v', '--verbose', action='count', default=0)
    parser.add_argument('-6', '--ipv6', action='store_true')
    
    args = parser.parse_args()
    
    # Load profile if specified
    if args.profile:
        profile = ProfileManager.load(args.profile)
        host = profile.host
        port = profile.port
        username = profile.username
    else:
        # Parse host string
        host, port, username = parse_host_string(args.host)
    
    # Connect
    client = SftpClient(host, port, username)
    client.connect()
    
    # Interactive mode
    if sys.stdin.isatty():
        interactive_mode(client)
    else:
        # Batch mode
        batch_mode(client, sys.stdin)
    
    client.disconnect()

if __name__ == '__main__':
    main()
```

---

## Auto-Reconnect

### Implementation

```cpp
void AutoReconnectManager::triggerReconnect(const QString& sessionId) {
    auto& state = m_sessionStates[sessionId];
    state.state = ReconnectState::Waiting;
    state.attemptCount = 0;
    state.cancelled = false;
    
    // Save current state for restoration
    if (m_config.preserveState) {
        saveSessionState(sessionId);
    }
    
    startReconnectTimer(sessionId);
}

int AutoReconnectManager::calculateDelay(int attempt) {
    int delay = m_config.initialDelay * pow(m_config.backoffMultiplier, attempt);
    return qMin(delay, m_config.maxDelay);
}

void AutoReconnectManager::onReconnectTimer() {
    QString sessionId = sender()->property("sessionId").toString();
    auto& state = m_sessionStates[sessionId];
    
    if (state.cancelled) return;
    
    state.attemptCount++;
    state.state = ReconnectState::Reconnecting;
    
    emit reconnectAttempt(sessionId, state.attemptCount, m_config.maxAttempts);
    
    // Attempt reconnection
    bool success = attemptReconnect(sessionId);
    
    if (success) {
        state.state = ReconnectState::Restoring;
        
        // Restore state
        if (m_config.preserveState) {
            restoreSessionState(sessionId);
        }
        
        state.state = ReconnectState::Complete;
        emit reconnectSuccess(sessionId, state.attemptCount);
    } else {
        if (state.attemptCount >= m_config.maxAttempts) {
            state.state = ReconnectState::Failed;
            emit reconnectFailed(sessionId, state.attemptCount);
        } else {
            // Schedule next attempt
            state.currentDelay = calculateDelay(state.attemptCount);
            state.nextRetryTime = QDateTime::currentDateTime().addMSecs(state.currentDelay);
            startReconnectTimer(sessionId);
        }
    }
}
```

---

## IPv6 Support

### Implementation

```cpp
bool Ipv6Connectivity::hostSupportsIpv6(const QString& hostname) {
    QHostInfo info = QHostInfo::fromName(hostname);
    
    for (const QHostAddress& addr : info.addresses()) {
        if (addr.protocol() == QAbstractSocket::IPv6Protocol) {
            return true;
        }
    }
    
    return false;
}

QAbstractSocket::NetworkLayerProtocol Ipv6Connectivity::getPreferredProtocol(
    const QString& hostname) {
    
    if (m_forcedProtocol != QAbstractSocket::AnyIPProtocol) {
        return m_forcedProtocol;
    }
    
    bool ipv4 = false, ipv6 = false;
    
    QHostInfo info = QHostInfo::fromName(hostname);
    for (const QHostAddress& addr : info.addresses()) {
        if (addr.protocol() == QAbstractSocket::IPv4Protocol) ipv4 = true;
        if (addr.protocol() == QAbstractSocket::IPv6Protocol) ipv6 = true;
    }
    
    if (ipv6 && (m_preferIpv6 || !ipv4)) {
        return QAbstractSocket::IPv6Protocol;
    }
    
    return QAbstractSocket::IPv4Protocol;
}

// Usage in connection
void SshEngine::connect(const QString& host, int port) {
    QAbstractSocket::NetworkLayerProtocol protocol = 
        m_ipv6Connectivity->getPreferredProtocol(host);
    
    QTcpSocket* socket = new QTcpSocket();
    socket->setProtocol(protocol);
    socket->connectToHost(host, port);
    
    // ... rest of connection logic
}
```

---

## Multi-Terminal Sessions

### Implementation

```cpp
QString MultiTerminalManager::createTerminalWindow(const QString& sessionId,
                                                     const QString& terminalType) {
    QString windowId = generateWindowId();
    
    auto window = new TerminalWindow();
    window->id = windowId;
    window->sessionId = sessionId;
    window->emulator = std::make_shared<TerminalEmulator>(
        terminalTypeFromString(terminalType)
    );
    window->createdAt = QDateTime::currentDateTime();
    
    // Open channel
    if (!openChannel(window)) {
        delete window;
        return QString();
    }
    
    m_terminals[windowId] = window;
    
    // Connect signals
    connect(window->emulator.get(), &TerminalEmulator::sendData,
            this, [this, windowId](const QByteArray& data) {
        writeToTerminal(windowId, data);
    });
    
    emit terminalCreated(windowId, sessionId);
    return windowId;
}
```

---

## RDP Bridge

### Single-Click RDP Launch

```cpp
bool RdpBridge::launchRdpClient(const RdpConfig& config) {
    QString rdpClient = findRdpClient();
    if (rdpClient.isEmpty()) {
        emit rdpClientError("RDP client not found");
        return false;
    }
    
    QStringList args = buildRdpCommandLine(config);
    
    QProcess* process = new QProcess(this);
    process->start(rdpClient, args);
    
    if (!process->waitForStarted()) {
        emit rdpClientError("Failed to start RDP client");
        delete process;
        return false;
    }
    
    QString processId = QString::number(process->processId());
    m_rdpProcesses[processId] = process;
    
    connect(process, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, [this, processId](int exitCode, QProcess::ExitStatus exitStatus) {
        emit rdpClientExited(processId, exitCode);
        m_rdpProcesses.remove(processId);
    });
    
    emit rdpClientLaunched(processId);
    return true;
}

QStringList RdpBridge::buildRdpCommandLine(const RdpConfig& config) {
    QStringList args;
    
    // Generate .rdp file
    QString rdpFile = generateRdpFile(config);
    args.append(rdpFile);
    
    return args;
}

QString RdpBridge::generateRdpFile(const RdpConfig& config) {
    QString rdpContent;
    rdpContent += QString("full address:s:%1:%2\n").arg(config.host).arg(config.port);
    rdpContent += QString("username:s:%1\n").arg(config.username);
    rdpContent += QString("screen mode id:i:%1\n").arg(config.fullscreen ? 2 : 1);
    rdpContent += QString("desktopwidth:i:%1\n").arg(config.width);
    rdpContent += QString("desktopheight:i:%1\n").arg(config.height);
    rdpContent += QString("session bpp:i:%1\n").arg(config.colorDepth);
    rdpContent += QString("audiomode:i:%1\n").arg(config.enableSound ? 0 : 1);
    rdpContent += QString("redirectclipboard:i:%1\n").arg(config.enableClipboard ? 1 : 0);
    
    // Save to temp file
    QString rdpFile = QDir::temp().filePath("bluessh_session.rdp");
    QFile file(rdpFile);
    file.open(QIODevice::WriteOnly);
    file.write(rdpContent.toUtf8());
    file.close();
    
    return rdpFile;
}
```

---

## Portable Distribution

### Implementation

```cpp
bool PortableLauncher::initialize(const QString& appDir) {
    m_portableDir = appDir;
    m_configDir = m_portableDir + "/config";
    m_dataDir = m_portableDir + "/data";
    m_cacheDir = m_portableDir + "/cache";
    m_logsDir = m_portableDir + "/logs";
    m_profilesDir = m_configDir + "/profiles";
    m_keysDir = m_configDir + "/keys";
    
    if (!createDirectoryStructure()) return false;
    if (!setupEnvironment()) return false;
    
    m_isPortable = true;
    emit initialized();
    return true;
}

bool PortableLauncher::createDirectoryStructure() {
    QStringList dirs = {
        m_configDir,
        m_dataDir,
        m_cacheDir,
        m_logsDir,
        m_profilesDir,
        m_keysDir
    };
    
    for (const QString& dir : dirs) {
        if (!QDir().mkpath(dir)) {
            emit error("Failed to create directory: " + dir);
            return false;
        }
    }
    
    return true;
}

bool PortableLauncher::setupEnvironment() {
    m_environment = QProcessEnvironment::systemEnvironment();
    
    // Set portable paths
    m_environment.insert("BLUESSH_CONFIG", m_configDir);
    m_environment.insert("BLUESSH_DATA", m_dataDir);
    m_environment.insert("BLUESSH_CACHE", m_cacheDir);
    m_environment.insert("BLUESSH_LOGS", m_logsDir);
    m_environment.insert("BLUESSH_PROFILES", m_profilesDir);
    m_environment.insert("BLUESSH_KEYS", m_keysDir);
    
    // Set library paths for portable Qt
    m_environment.insert("LD_LIBRARY_PATH", 
                         m_portableDir + "/lib:" + m_environment.value("LD_LIBRARY_PATH"));
    
    return true;
}
```

---

## Security Best Practices

### 1. Credential Zeroization

```cpp
void secureZeroize(QString& str) {
    // Overwrite with zeros before destruction
    for (int i = 0; i < str.size(); i++) {
        str[i] = QChar(0);
    }
}

void secureZeroize(QByteArray& data) {
    OPENSSL_cleanse(data.data(), data.size());
}
```

### 2. Encrypted Storage

```cpp
QString encryptString(const QString& plain, const QByteArray& key) {
    // Use AES-256-GCM
    EVP_CIPHER_CTX* ctx = EVP_CIPHER_CTX_new();
    EVP_EncryptInit_ex(ctx, EVP_aes_256_gcm(), nullptr, nullptr, nullptr);
    EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, 12, nullptr);
    
    // Generate random IV
    unsigned char iv[12];
    RAND_bytes(iv, sizeof(iv));
    EVP_EncryptInit_ex(ctx, nullptr, nullptr, key.constData(), iv);
    
    // Encrypt
    int len;
    QByteArray ciphertext(plain.size() + EVP_MAX_BLOCK_LENGTH, 0);
    EVP_EncryptUpdate(ctx, (unsigned char*)ciphertext.data(), &len,
                      (const unsigned char*)plain.toUtf8().constData(), plain.size());
    
    int ciphertextLen = len;
    EVP_EncryptFinal_ex(ctx, (unsigned char*)ciphertext.data() + len, &len);
    ciphertextLen += len;
    ciphertext.resize(ciphertextLen);
    
    // Get tag
    unsigned char tag[16];
    EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, 16, tag);
    
    EVP_CIPHER_CTX_free(ctx);
    
    // Return IV + ciphertext + tag
    QByteArray result;
    result.append((const char*)iv, 12);
    result.append(ciphertext);
    result.append((const char*)tag, 16);
    
    return result.toBase64();
}
```

### 3. Host Key Verification

```cpp
bool KnownHosts::verifyHost(const QString& host, int port, LIBSSH2_SESSION* session) {
    const char* key;
    size_t keyLen;
    int keyType = libssh2_session_hostkey(session, &key, &keyLen);
    
    if (keyType == LIBSSH2_HOSTKEY_TYPE_UNKNOWN) {
        return false;
    }
    
    QString fingerprint = calculateFingerprint(key, keyLen);
    QString hostKey = getHostKey(host, port);
    
    if (hostKey.isEmpty()) {
        // New host - prompt user
        return promptAcceptHost(host, port, fingerprint);
    }
    
    return hostKey == fingerprint;
}
```

### 4. Secure Defaults

```cpp
// Default security settings
struct SecurityDefaults {
    // Encryption
    QString cipherList = "chacha20-poly1305@openssh.com,"
                         "aes256-gcm@openssh.com,"
                         "aes128-gcm@openssh.com,"
                         "aes256-ctr,aes192-ctr,aes128-ctr";
    
    // MAC
    QString macList = "hmac-sha2-512-etm@openssh.com,"
                      "hmac-sha2-256-etm@openssh.com,"
                      "hmac-sha2-512,hmac-sha2-256";
    
    // Key Exchange
    QString kexList = "curve25519-sha256,"
                      "curve25519-sha256@libssh.org,"
                      "diffie-hellman-group-exchange-sha256,"
                      "diffie-hellman-group16-sha512";
    
    // Host Keys
    QString hostKeyList = "ssh-ed25519,"
                          "ecdsa-sha2-nistp521,"
                          "ecdsa-sha2-nistp384,"
                          "ecdsa-sha2-nistp256,"
                          "rsa-sha2-512,rsa-sha2-256";
};
```

---

## Build Instructions

### Desktop (Linux)

```bash
# Install dependencies
sudo apt-get install -y \
    build-essential cmake \
    qt6-base-dev qt6-tools-dev \
    libssh2-1-dev libvterm-dev \
    libssl-dev zlib1g-dev libzstd-dev \
    libgssapi-krb5-2 libkrb5-dev

# Build
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)

# Install
sudo make install
```

### Desktop (Windows)

```powershell
# Install dependencies (using vcpkg)
vcpkg install qt6-base qt6-tools libssh2 openssl zlib zstd

# Build
mkdir build && cd build
cmake .. -G "Visual Studio 17 2022" -A x64 `
    -DCMAKE_TOOLCHAIN_FILE=C:/vcpkg/scripts/buildsystems/vcpkg.cmake
cmake --build . --config Release
```

### Android

```bash
cd android
./gradlew assembleDebug    # Debug APK
./gradlew assembleRelease  # Release APK
```

---

## Testing

### Unit Tests

```cpp
class TerminalEmulatorTest : public QObject {
    Q_OBJECT
private slots:
    void testCursorMovement() {
        TerminalEmulator terminal(TerminalType::Xterm, 80, 24);
        
        // Test cursor up
        terminal.feed("\033[5A");
        QCOMPARE(terminal.getScreen().cursorY, 0);
        
        // Test cursor down
        terminal.feed("\033[10B");
        QCOMPARE(terminal.getScreen().cursorY, 10);
        
        // Test cursor position
        terminal.feed("\033[5;10H");
        QCOMPARE(terminal.getScreen().cursorY, 4);
        QCOMPARE(terminal.getScreen().cursorX, 9);
    }
    
    void testColors() {
        TerminalEmulator terminal(TerminalType::Xterm, 80, 24);
        
        // Test 256 colors
        terminal.feed("\033[38;5;196m");  // Red
        // Verify color set
        
        // Test true color
        terminal.feed("\033[38;2;255;0;0m");  // RGB red
        // Verify color set
    }
};
```

---

## Performance Optimization

1. **Terminal Rendering**
   - Use OpenGL for rendering
   - Batch cell updates
   - Dirty rectangle tracking
   - Font caching

2. **SFTP Transfers**
   - Parallel transfers (configurable threads)
   - Large buffer sizes (32KB+)
   - Pipeline requests
   - Resume support

3. **Network**
   - Async I/O
   - Connection pooling
   - Compression (configurable levels)
   - Keepalive optimization

---

## License

MIT License - See LICENSE file for details
