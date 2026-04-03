#ifndef KEYMANAGER_H
#define KEYMANAGER_H

#include <QObject>
#include <QString>
#include <QList>
#include <QByteArray>

/**
 * Key type enumeration
 */
enum class KeyType {
    RSA,
    DSA,
    ECDSA,
    ED25519
};

/**
 * SSH Key information
 */
struct SshKeyInfo {
    QString name;
    QString path;
    KeyType type;
    QString fingerprint;
    int keySize;
    bool isEncrypted;
    QDateTime createdAt;
};

/**
 * Key Manager - handles SSH key generation, import, and storage
 */
class KeyManager : public QObject
{
    Q_OBJECT

public:
    explicit KeyManager(QObject *parent = nullptr);
    ~KeyManager();

    // Generate new key pair
    bool generateKeyPair(const QString& name, KeyType type, int keySize, 
                        const QString& outputPath, const QString& passphrase = QString());
    
    // Import key from file
    SshKeyInfo importKey(const QString& filePath, const QString& passphrase = QString());
    
    // Load key pair
    bool loadKeyPair(const QString& name, const QString& passphrase = QString());
    
    // Delete key
    bool deleteKey(const QString& name);
    
    // List all keys
    QList<SshKeyInfo> listKeys() const;
    
    // Get key fingerprint
    QString getKeyFingerprint(const QString& keyPath) const;
    
    // Get key type from file
    KeyType detectKeyType(const QString& filePath) const;
    
    // Export public key
    QByteArray exportPublicKey(const QString& name) const;
    
    // Check if key exists
    bool keyExists(const QString& name) const;

signals:
    void keyGenerated(const QString& name);
    void keyImported(const QString& name);
    void keyDeleted(const QString& name);
    void errorOccurred(const QString& error);

private:
    QString generateRsaKey(const QString& name, int keySize, const QString& outputPath, const QString& passphrase);
    QString generateEcdsaKey(const QString& name, int keySize, const QString& outputPath, const QString& passphrase);
    QString generateEd25519Key(const QString& name, const QString& outputPath, const QString& passphrase);
    
    QString m_keysDirectory;
};

#endif // KEYMANAGER_H
