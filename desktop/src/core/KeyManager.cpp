#include "KeyManager.h"
#include <QFile>
#include <QDir>
#include <QStandardPaths>
#include <QCryptographicHash>
#include <QProcess>
#include <QDebug>
#include <QDateTime>
#include <openssl/pem.h>
#include <openssl/rsa.h>
#include <openssl/ec.h>
#include <openssl/evp.h>
#include <openssl/err.h>

KeyManager::KeyManager(QObject *parent)
    : QObject(parent)
{
    m_keysDirectory = QStandardPaths::writableLocation(QStandardPaths::AppConfigLocation) + "/keys";
    QDir().mkpath(m_keysDirectory);
}

KeyManager::~KeyManager()
{
}

bool KeyManager::generateKeyPair(const QString& name, KeyType type, int keySize,
                                  const QString& outputPath, const QString& passphrase)
{
    QString keyPath = outputPath.isEmpty() ? m_keysDirectory + "/" + name : outputPath;
    
    switch (type) {
        case KeyType::RSA:
            return generateRsaKey(name, keySize, keyPath, passphrase);
        case KeyType::ECDSA:
            return generateEcdsaKey(name, keySize, keyPath, passphrase);
        case KeyType::ED25519:
            return generateEd25519Key(name, keyPath, passphrase);
        default:
            emit errorOccurred("Unknown key type");
            return false;
    }
}

QString KeyManager::generateRsaKey(const QString& name, int keySize, const QString& outputPath, const QString& passphrase)
{
    RSA* rsa = RSA_generate_key(keySize, RSA_F4, nullptr, nullptr);
    if (!rsa) {
        emit errorOccurred("Failed to generate RSA key");
        return QString();
    }
    
    EVP_PKEY* pkey = EVP_PKEY_new();
    EVP_PKEY_assign_RSA(pkey, rsa);
    
    // Write private key
    QFile privFile(outputPath);
    if (!privFile.open(QIODevice::WriteOnly)) {
        emit errorOccurred("Failed to open private key file for writing");
        EVP_PKEY_free(pkey);
        return QString();
    }
    
    FILE* fp = fopen(outputPath.toUtf8().constData(), "w");
    if (!fp) {
        emit errorOccurred("Failed to open private key file");
        EVP_PKEY_free(pkey);
        return QString();
    }
    
    const EVP_CIPHER* cipher = passphrase.isEmpty() ? nullptr : EVP_aes_256_cbc();
    PEM_write_PrivateKey(fp, pkey, cipher, nullptr, 0, nullptr, (void*)passphrase.toUtf8().constData());
    fclose(fp);
    
    // Set permissions
    QFile::setPermissions(outputPath, QFile::ReadOwner | QFile::WriteOwner);
    
    // Write public key
    QString pubPath = outputPath + ".pub";
    FILE* pubFp = fopen(pubPath.toUtf8().constData(), "w");
    if (pubFp) {
        PEM_write_PUBKEY(pubFp, pkey);
        fclose(pubFp);
    }
    
    EVP_PKEY_free(pkey);
    
    emit keyGenerated(name);
    return outputPath;
}

QString KeyManager::generateEcdsaKey(const QString& name, int keySize, const QString& outputPath, const QString& passphrase)
{
    int nid = NID_X9_62_prime256v1;  // P-256
    if (keySize == 384) nid = NID_secp384r1;
    else if (keySize == 521) nid = NID_secp521r1;
    
    EC_KEY* ec = EC_KEY_new_by_curve_name(nid);
    if (!ec) {
        emit errorOccurred("Failed to create EC key");
        return QString();
    }
    
    if (!EC_KEY_generate_key(ec)) {
        emit errorOccurred("Failed to generate EC key");
        EC_KEY_free(ec);
        return QString();
    }
    
    EVP_PKEY* pkey = EVP_PKEY_new();
    EVP_PKEY_assign_EC_KEY(pkey, ec);
    
    // Write private key
    FILE* fp = fopen(outputPath.toUtf8().constData(), "w");
    if (!fp) {
        emit errorOccurred("Failed to open private key file");
        EVP_PKEY_free(pkey);
        return QString();
    }
    
    const EVP_CIPHER* cipher = passphrase.isEmpty() ? nullptr : EVP_aes_256_cbc();
    PEM_write_PrivateKey(fp, pkey, cipher, nullptr, 0, nullptr, (void*)passphrase.toUtf8().constData());
    fclose(fp);
    
    QFile::setPermissions(outputPath, QFile::ReadOwner | QFile::WriteOwner);
    
    // Write public key
    QString pubPath = outputPath + ".pub";
    FILE* pubFp = fopen(pubPath.toUtf8().constData(), "w");
    if (pubFp) {
        PEM_write_PUBKEY(pubFp, pkey);
        fclose(pubFp);
    }
    
    EVP_PKEY_free(pkey);
    
    emit keyGenerated(name);
    return outputPath;
}

QString KeyManager::generateEd25519Key(const QString& name, const QString& outputPath, const QString& passphrase)
{
    EVP_PKEY_CTX* ctx = EVP_PKEY_CTX_new_id(EVP_PKEY_ED25519, nullptr);
    if (!ctx) {
        emit errorOccurred("Failed to create Ed25519 key context");
        return QString();
    }
    
    if (EVP_PKEY_keygen_init(ctx) <= 0) {
        emit errorOccurred("Failed to initialize Ed25519 key generation");
        EVP_PKEY_CTX_free(ctx);
        return QString();
    }
    
    EVP_PKEY* pkey = nullptr;
    if (EVP_PKEY_keygen(ctx, &pkey) <= 0) {
        emit errorOccurred("Failed to generate Ed25519 key");
        EVP_PKEY_CTX_free(ctx);
        return QString();
    }
    
    EVP_PKEY_CTX_free(ctx);
    
    // Write private key
    FILE* fp = fopen(outputPath.toUtf8().constData(), "w");
    if (!fp) {
        emit errorOccurred("Failed to open private key file");
        EVP_PKEY_free(pkey);
        return QString();
    }
    
    const EVP_CIPHER* cipher = passphrase.isEmpty() ? nullptr : EVP_aes_256_cbc();
    PEM_write_PrivateKey(fp, pkey, cipher, nullptr, 0, nullptr, (void*)passphrase.toUtf8().constData());
    fclose(fp);
    
    QFile::setPermissions(outputPath, QFile::ReadOwner | QFile::WriteOwner);
    
    // Write public key
    QString pubPath = outputPath + ".pub";
    FILE* pubFp = fopen(pubPath.toUtf8().constData(), "w");
    if (pubFp) {
        PEM_write_PUBKEY(pubFp, pkey);
        fclose(pubFp);
    }
    
    EVP_PKEY_free(pkey);
    
    emit keyGenerated(name);
    return outputPath;
}

SshKeyInfo KeyManager::importKey(const QString& filePath, const QString& passphrase)
{
    SshKeyInfo info;
    info.path = filePath;
    info.name = QFileInfo(filePath).fileName();
    info.createdAt = QFileInfo(filePath).created();
    
    // Detect key type
    info.type = detectKeyType(filePath);
    
    // Calculate fingerprint
    info.fingerprint = getKeyFingerprint(filePath);
    
    // Check if encrypted
    QFile file(filePath);
    if (file.open(QIODevice::ReadOnly)) {
        QString content = file.readAll();
        info.isEncrypted = content.contains("ENCRYPTED");
        file.close();
    }
    
    // Get key size
    FILE* fp = fopen(filePath.toUtf8().constData(), "r");
    if (fp) {
        EVP_PKEY* pkey = PEM_read_PrivateKey(fp, nullptr, nullptr, (void*)passphrase.toUtf8().constData());
        if (pkey) {
            info.keySize = EVP_PKEY_bits(pkey);
            EVP_PKEY_free(pkey);
        }
        fclose(fp);
    }
    
    emit keyImported(info.name);
    return info;
}

bool KeyManager::loadKeyPair(const QString& name, const QString& passphrase)
{
    QString keyPath = m_keysDirectory + "/" + name;
    
    FILE* fp = fopen(keyPath.toUtf8().constData(), "r");
    if (!fp) {
        return false;
    }
    
    EVP_PKEY* pkey = PEM_read_PrivateKey(fp, nullptr, nullptr, (void*)passphrase.toUtf8().constData());
    fclose(fp);
    
    if (!pkey) {
        return false;
    }
    
    EVP_PKEY_free(pkey);
    return true;
}

bool KeyManager::deleteKey(const QString& name)
{
    QString keyPath = m_keysDirectory + "/" + name;
    QString pubPath = keyPath + ".pub";
    
    bool success = true;
    if (QFile::exists(keyPath)) {
        success &= QFile::remove(keyPath);
    }
    if (QFile::exists(pubPath)) {
        success &= QFile::remove(pubPath);
    }
    
    if (success) {
        emit keyDeleted(name);
    }
    
    return success;
}

QList<SshKeyInfo> KeyManager::listKeys() const
{
    QList<SshKeyInfo> keys;
    
    QDir dir(m_keysDirectory);
    QStringList filters;
    filters << "*.pem" << "*.key" << "id_*";
    
    QFileInfoList files = dir.entryInfoList(filters, QDir::Files);
    for (const QFileInfo& fileInfo : files) {
        SshKeyInfo info;
        info.name = fileInfo.fileName();
        info.path = fileInfo.absoluteFilePath();
        info.type = detectKeyType(info.absoluteFilePath());
        info.fingerprint = getKeyFingerprint(info.absoluteFilePath());
        info.keySize = 0;  // Would need to load key to get size
        info.isEncrypted = false;
        info.createdAt = fileInfo.created();
        
        keys.append(info);
    }
    
    return keys;
}

QString KeyManager::getKeyFingerprint(const QString& keyPath) const
{
    FILE* fp = fopen(keyPath.toUtf8().constData(), "r");
    if (!fp) {
        return QString();
    }
    
    EVP_PKEY* pkey = PEM_read_PrivateKey(fp, nullptr, nullptr, nullptr);
    fclose(fp);
    
    if (!pkey) {
        return QString();
    }
    
    // Get public key
    EVP_PKEY* pubKey = EVP_PKEY_dup(pkey);
    EVP_PKEY_free(pkey);
    
    if (!pubKey) {
        return QString();
    }
    
    // Get key data
    unsigned char* der = nullptr;
    int derLen = i2d_PUBKEY(pubKey, &der);
    EVP_PKEY_free(pubKey);
    
    if (derLen <= 0 || !der) {
        return QString();
    }
    
    // Calculate SHA256 fingerprint
    QByteArray hash = QCryptographicHash::hash(QByteArray((const char*)der, derLen),
                                               QCryptographicHash::Sha256);
    OPENSSL_free(der);
    
    // Format as hex string
    return hash.toHex(':');
}

KeyType KeyManager::detectKeyType(const QString& filePath) const
{
    QFile file(filePath);
    if (!file.open(QIODevice::ReadOnly)) {
        return KeyType::RSA;  // Default
    }
    
    QString content = file.readAll();
    file.close();
    
    if (content.contains("EC PRIVATE KEY")) {
        return KeyType::ECDSA;
    } else if (content.contains("ED25519")) {
        return KeyType::ED25519;
    } else if (content.contains("DSA PRIVATE KEY")) {
        return KeyType::DSA;
    }
    
    return KeyType::RSA;
}

QByteArray KeyManager::exportPublicKey(const QString& name) const
{
    QString keyPath = m_keysDirectory + "/" + name;
    QString pubPath = keyPath + ".pub";
    
    if (QFile::exists(pubPath)) {
        QFile pubFile(pubPath);
        if (pubFile.open(QIODevice::ReadOnly)) {
            return pubFile.readAll();
        }
    }
    
    // Try to extract from private key
    FILE* fp = fopen(keyPath.toUtf8().constData(), "r");
    if (!fp) {
        return QByteArray();
    }
    
    EVP_PKEY* pkey = PEM_read_PrivateKey(fp, nullptr, nullptr, nullptr);
    fclose(fp);
    
    if (!pkey) {
        return QByteArray();
    }
    
    BIO* bio = BIO_new(BIO_s_mem());
    PEM_write_bio_PUBKEY(bio, pkey);
    EVP_PKEY_free(pkey);
    
    char* data;
    long len = BIO_get_mem_data(bio, &data);
    QByteArray result(data, len);
    BIO_free(bio);
    
    return result;
}

bool KeyManager::keyExists(const QString& name) const
{
    return QFile::exists(m_keysDirectory + "/" + name);
}
