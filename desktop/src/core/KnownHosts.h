#ifndef KNOWNHOSTS_H
#define KNOWNHOSTS_H

#include <QString>
#include <QMap>
#include <QDateTime>
#include <libssh2.h>

/**
 * Known host entry
 */
struct KnownHostEntry {
    QString host;
    int port;
    QString keyType;
    QString fingerprint;
    QString keyData;
    QDateTime addedAt;
};

/**
 * Known Hosts Manager
 * Verifies SSH host keys to prevent MITM attacks
 */
class KnownHosts
{
public:
    KnownHosts();
    
    // Load known hosts from file
    bool load(const QString& filePath = QString());
    
    // Save known hosts to file
    bool save(const QString& filePath = QString());
    
    // Verify host key
    bool verifyHost(const QString& host, int port, LIBSSH2_SESSION* session);
    
    // Add host key
    bool addHost(const QString& host, int port, LIBSSH2_SESSION* session);
    
    // Remove host
    bool removeHost(const QString& host, int port);
    
    // Get fingerprint for host
    QString getFingerprint(const QString& host, int port) const;
    
    // Get all known hosts
    QList<KnownHostEntry> getAllHosts() const;
    
    // Calculate SHA256 fingerprint
    static QString calculateFingerprint(const char* key, size_t keyLen);

private:
    QString getHostKey(const QString& host, int port) const;
    QString m_filePath;
    QMap<QString, KnownHostEntry> m_hosts;
};

#endif // KNOWNHOSTS_H
