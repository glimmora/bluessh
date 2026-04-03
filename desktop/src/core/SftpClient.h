#ifndef SFTPCLIENT_H
#define SFTPCLIENT_H

#include <QObject>
#include <QString>
#include <QList>
#include <QDateTime>
#include <functional>
#include <libssh2.h>
#include <libssh2_sftp.h>

/**
 * SFTP file entry
 */
struct SftpFileEntry {
    QString name;
    QString path;
    qint64 size;
    bool isDirectory;
    bool isFile;
    QString permissions;
    QDateTime modifiedAt;
    QString owner;
    QString group;
};

/**
 * Transfer progress callback
 */
using TransferProgressCallback = std::function<void(qint64 bytesTransferred, qint64 totalBytes)>;

/**
 * SFTP Client - handles file transfer operations
 */
class SftpClient : public QObject
{
    Q_OBJECT

public:
    explicit SftpClient(LIBSSH2_SESSION* session, QObject *parent = nullptr);
    ~SftpClient();

    // Initialize SFTP
    bool initialize();

    // List directory contents
    QList<SftpFileEntry> listDirectory(const QString& path);

    // Upload file
    bool uploadFile(const QString& localPath, const QString& remotePath, 
                   TransferProgressCallback progressCallback = nullptr);

    // Download file
    bool downloadFile(const QString& remotePath, const QString& localPath,
                     TransferProgressCallback progressCallback = nullptr);

    // Create directory
    bool createDirectory(const QString& path);

    // Delete file or directory
    bool remove(const QString& path);

    // Rename file or directory
    bool rename(const QString& oldPath, const QString& newPath);

    // Change permissions
    bool changePermissions(const QString& path, int permissions);

    // Get file info
    SftpFileEntry getFileInfo(const QString& path);

    // Check if path exists
    bool exists(const QString& path);

    // Get current directory
    QString getCurrentDirectory() const;

    // Set current directory
    void setCurrentDirectory(const QString& path);

    // Close SFTP session
    void close();

signals:
    void transferProgress(qint64 bytesTransferred, qint64 totalBytes);
    void transferComplete(const QString& path);
    void errorOccurred(const QString& error);

private:
    QString formatPermissions(long perms);
    long parsePermissions(const QString& perms);

    LIBSSH2_SESSION* m_session;
    LIBSSH2_SFTP* m_sftp = nullptr;
    QString m_currentDirectory;
    bool m_initialized = false;
};

#endif // SFTPCLIENT_H
