#include "KnownHosts.h"
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QCryptographicHash>
#include <QStandardPaths>
#include <QDir>
#include <QDebug>
#include <QMessageBox>
#include <libssh2.h>

KnownHosts::KnownHosts()
{
    m_filePath = QStandardPaths::writableLocation(QStandardPaths::AppConfigLocation) + "/known_hosts.json";
}

bool KnownHosts::load(const QString& filePath)
{
    QString path = filePath.isEmpty() ? m_filePath : filePath;
    
    QFile file(path);
    if (!file.exists()) {
        return true;  // No file yet is OK
    }
    
    if (!file.open(QIODevice::ReadOnly)) {
        qWarning() << "Failed to open known_hosts file:" << path;
        return false;
    }
    
    QByteArray data = file.readAll();
    file.close();
    
    QJsonParseError error;
    QJsonDocument doc = QJsonDocument::fromJson(data, &error);
    if (error.error != QJsonParseError::NoError) {
        qWarning() << "Failed to parse known_hosts file:" << error.errorString();
        return false;
    }
    
    QJsonObject root = doc.object();
    QJsonArray hostsArray = root["hosts"].toArray();
    
    m_hosts.clear();
    for (const QJsonValue& value : hostsArray) {
        QJsonObject hostObj = value.toObject();
        KnownHostEntry entry;
        entry.host = hostObj["host"].toString();
        entry.port = hostObj["port"].toInt();
        entry.keyType = hostObj["keyType"].toString();
        entry.fingerprint = hostObj["fingerprint"].toString();
        entry.keyData = hostObj["keyData"].toString();
        entry.addedAt = QDateTime::fromString(hostObj["addedAt"].toString(), Qt::ISODate);
        
        m_hosts[getHostKey(entry.host, entry.port)] = entry;
    }
    
    qDebug() << "Loaded" << m_hosts.size() << "known hosts";
    return true;
}

bool KnownHosts::save(const QString& filePath)
{
    QString path = filePath.isEmpty() ? m_filePath : filePath;
    
    // Ensure directory exists
    QFileInfo fileInfo(path);
    QDir().mkpath(fileInfo.absolutePath());
    
    QJsonArray hostsArray;
    for (auto it = m_hosts.begin(); it != m_hosts.end(); ++it) {
        const KnownHostEntry& entry = it.value();
        QJsonObject hostObj;
        hostObj["host"] = entry.host;
        hostObj["port"] = entry.port;
        hostObj["keyType"] = entry.keyType;
        hostObj["fingerprint"] = entry.fingerprint;
        hostObj["keyData"] = entry.keyData;
        hostObj["addedAt"] = entry.addedAt.toString(Qt::ISODate);
        hostsArray.append(hostObj);
    }
    
    QJsonObject root;
    root["hosts"] = hostsArray;
    
    QJsonDocument doc(root);
    
    QFile file(path);
    if (!file.open(QIODevice::WriteOnly)) {
        qWarning() << "Failed to save known_hosts file:" << path;
        return false;
    }
    
    file.write(doc.toJson(QJsonDocument::Compact));
    file.close();
    
    qDebug() << "Saved" << m_hosts.size() << "known hosts";
    return true;
}

bool KnownHosts::verifyHost(const QString& host, int port, LIBSSH2_SESSION* session)
{
    const char* key;
    size_t keyLen;
    int keyType = libssh2_session_hostkey(session, &key, &keyLen);
    
    if (keyType == LIBSSH2_HOSTKEY_TYPE_UNKNOWN) {
        qWarning() << "Unknown host key type";
        return false;
    }
    
    QString fingerprint = calculateFingerprint(key, keyLen);
    QString hostKey = getHostKey(host, port);
    
    auto it = m_hosts.find(hostKey);
    if (it == m_hosts.end()) {
        // New host - prompt user
        return promptAcceptHost(host, port, fingerprint);
    }
    
    // Known host - check fingerprint
    if (it->fingerprint == fingerprint) {
        return true;  // Key matches
    }
    
    // Key mismatch - possible MITM attack
    qCritical() << "Host key mismatch for" << host << ":" << port;
    qCritical() << "Expected:" << it->fingerprint;
    qCritical() << "Got:" << fingerprint;
    
    QMessageBox::critical(nullptr, "Security Alert",
                         QString("WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!\n\n"
                                "Host: %1:%2\n"
                                "This could mean a man-in-the-middle attack.\n\n"
                                "Expected: %3\n"
                                "Got: %4")
                         .arg(host).arg(port)
                         .arg(it->fingerprint)
                         .arg(fingerprint));
    
    return false;
}

bool KnownHosts::addHost(const QString& host, int port, LIBSSH2_SESSION* session)
{
    const char* key;
    size_t keyLen;
    int keyType = libssh2_session_hostkey(session, &key, &keyLen);
    
    if (keyType == LIBSSH2_HOSTKEY_TYPE_UNKNOWN) {
        return false;
    }
    
    QString fingerprint = calculateFingerprint(key, keyLen);
    QString keyTypeStr;
    
    switch (keyType) {
        case LIBSSH2_HOSTKEY_TYPE_RSA:
            keyTypeStr = "ssh-rsa";
            break;
        case LIBSSH2_HOSTKEY_TYPE_DSS:
            keyTypeStr = "ssh-dss";
            break;
#if LIBSSH2_VERSION_NUM >= 0x010206
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_256:
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_384:
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_521:
            keyTypeStr = "ecdsa-sha2-nistp256";
            break;
        case LIBSSH2_HOSTKEY_TYPE_ED25519:
            keyTypeStr = "ssh-ed25519";
            break;
#endif
    }
    
    KnownHostEntry entry;
    entry.host = host;
    entry.port = port;
    entry.keyType = keyTypeStr;
    entry.fingerprint = fingerprint;
    entry.keyData = QByteArray::fromRawData(key, keyLen).toBase64();
    entry.addedAt = QDateTime::currentDateTime();
    
    m_hosts[getHostKey(host, port)] = entry;
    return save();
}

bool KnownHosts::removeHost(const QString& host, int port)
{
    QString key = getHostKey(host, port);
    if (m_hosts.remove(key)) {
        return save();
    }
    return false;
}

QString KnownHosts::getFingerprint(const QString& host, int port) const
{
    auto it = m_hosts.find(getHostKey(host, port));
    if (it != m_hosts.end()) {
        return it->fingerprint;
    }
    return QString();
}

QList<KnownHostEntry> KnownHosts::getAllHosts() const
{
    return m_hosts.values();
}

QString KnownHosts::calculateFingerprint(const char* key, size_t keyLen)
{
    QByteArray data(key, keyLen);
    QByteArray hash = QCryptographicHash::hash(data, QCryptographicHash::Sha256);
    return hash.toBase64();
}

QString KnownHosts::getHostKey(const QString& host, int port) const
{
    return QString("[%1]:%2").arg(host).arg(port);
}

bool KnownHosts::promptAcceptHost(const QString& host, int port, const QString& fingerprint)
{
    QString message = QString("The authenticity of host '%1:%2' can't be established.\n\n"
                             "Fingerprint: %3\n\n"
                             "Do you want to continue connecting?")
                     .arg(host).arg(port).arg(fingerprint);
    
    int result = QMessageBox::question(nullptr, "Verify Host Key",
                                       message,
                                       QMessageBox::Yes | QMessageBox::No,
                                       QMessageBox::No);
    
    if (result == QMessageBox::Yes) {
        // Note: We can't add the host here without the session
        // This will be done by the caller
        return true;
    }
    
    return false;
}
