#include "SftpClient.h"
#include <QFile>
#include <QFileInfo>
#include <QDir>
#include <QDebug>
#include <QThread>

SftpClient::SftpClient(LIBSSH2_SESSION* session, QObject *parent)
    : QObject(parent)
    , m_session(session)
{
}

SftpClient::~SftpClient()
{
    close();
}

bool SftpClient::initialize()
{
    if (m_initialized) {
        return true;
    }

    m_sftp = libssh2_sftp_init(m_session);
    if (!m_sftp) {
        emit errorOccurred("Failed to initialize SFTP subsystem");
        return false;
    }

    m_initialized = true;
    m_currentDirectory = "/";
    return true;
}

QList<SftpFileEntry> SftpClient::listDirectory(const QString& path)
{
    QList<SftpFileEntry> entries;

    if (!m_initialized || !m_sftp) {
        emit errorOccurred("SFTP not initialized");
        return entries;
    }

    QString fullPath = path.startsWith("/") ? path : m_currentDirectory + "/" + path;

    LIBSSH2_SFTP_HANDLE* handle = libssh2_sftp_opendir(m_sftp, fullPath.toUtf8().constData());
    if (!handle) {
        emit errorOccurred("Failed to open directory: " + path);
        return entries;
    }

    char buffer[512];
    char longEntry[512];
    LIBSSH2_SFTP_ATTRIBUTES attrs;

    while (libssh2_sftp_readdir_ex(handle, buffer, sizeof(buffer), 
                                    longEntry, sizeof(longEntry), &attrs) > 0) {
        SftpFileEntry entry;
        entry.name = QString::fromUtf8(buffer);
        entry.path = fullPath + "/" + entry.name;
        entry.size = attrs.filesize;
        entry.isDirectory = LIBSSH2_SFTP_S_ISDIR(attrs.permissions);
        entry.isFile = LIBSSH2_SFTP_S_ISREG(attrs.permissions);
        entry.permissions = formatPermissions(attrs.permissions);
        entry.modifiedAt = QDateTime::fromSecsSinceEpoch(attrs.mtime);
        entry.owner = QString::number(attrs.uid);
        entry.group = QString::number(attrs.gid);

        // Skip . and ..
        if (entry.name != "." && entry.name != "..") {
            entries.append(entry);
        }
    }

    libssh2_sftp_closedir(handle);
    return entries;
}

bool SftpClient::uploadFile(const QString& localPath, const QString& remotePath,
                           TransferProgressCallback progressCallback)
{
    if (!m_initialized || !m_sftp) {
        emit errorOccurred("SFTP not initialized");
        return false;
    }

    QFile localFile(localPath);
    if (!localFile.open(QIODevice::ReadOnly)) {
        emit errorOccurred("Failed to open local file: " + localPath);
        return false;
    }

    qint64 totalSize = localFile.size();
    
    LIBSSH2_SFTP_HANDLE* sftpHandle = libssh2_sftp_open(
        m_sftp,
        remotePath.toUtf8().constData(),
        LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC,
        LIBSSH2_SFTP_S_IRUSR | LIBSSH2_SFTP_S_IWUSR | LIBSSH2_SFTP_S_IRGRP | LIBSSH2_SFTP_S_IROTH
    );

    if (!sftpHandle) {
        emit errorOccurred("Failed to open remote file: " + remotePath);
        localFile.close();
        return false;
    }

    char buffer[32768]; // 32KB buffer
    qint64 totalWritten = 0;
    qint64 bytesRead;

    while ((bytesRead = localFile.read(buffer, sizeof(buffer))) > 0) {
        int written = libssh2_sftp_write(sftpHandle, buffer, bytesRead);
        if (written < 0) {
            emit errorOccurred("Failed to write to remote file");
            libssh2_sftp_close(sftpHandle);
            localFile.close();
            return false;
        }

        totalWritten += written;

        if (progressCallback) {
            progressCallback(totalWritten, totalSize);
        }

        emit transferProgress(totalWritten, totalSize);
    }

    libssh2_sftp_close(sftpHandle);
    localFile.close();

    emit transferComplete(remotePath);
    return true;
}

bool SftpClient::downloadFile(const QString& remotePath, const QString& localPath,
                             TransferProgressCallback progressCallback)
{
    if (!m_initialized || !m_sftp) {
        emit errorOccurred("SFTP not initialized");
        return false;
    }

    LIBSSH2_SFTP_HANDLE* sftpHandle = libssh2_sftp_open(
        m_sftp,
        remotePath.toUtf8().constData(),
        LIBSSH2_FXF_READ,
        0
    );

    if (!sftpHandle) {
        emit errorOccurred("Failed to open remote file: " + remotePath);
        return false;
    }

    LIBSSH2_SFTP_ATTRIBUTES attrs;
    if (libssh2_sftp_fstat_ex(sftpHandle, &attrs, 0) == 0) {
        emit errorOccurred("Failed to get file attributes");
        libssh2_sftp_close(sftpHandle);
        return false;
    }

    qint64 totalSize = attrs.filesize;

    QFile localFile(localPath);
    if (!localFile.open(QIODevice::WriteOnly)) {
        emit errorOccurred("Failed to open local file for writing: " + localPath);
        libssh2_sftp_close(sftpHandle);
        return false;
    }

    char buffer[32768]; // 32KB buffer
    qint64 totalRead = 0;
    int bytesRead;

    while ((bytesRead = libssh2_sftp_read(sftpHandle, buffer, sizeof(buffer))) > 0) {
        localFile.write(buffer, bytesRead);
        totalRead += bytesRead;

        if (progressCallback) {
            progressCallback(totalRead, totalSize);
        }

        emit transferProgress(totalRead, totalSize);
    }

    libssh2_sftp_close(sftpHandle);
    localFile.close();

    emit transferComplete(localPath);
    return true;
}

bool SftpClient::createDirectory(const QString& path)
{
    if (!m_initialized || !m_sftp) {
        emit errorOccurred("SFTP not initialized");
        return false;
    }

    int rc = libssh2_sftp_mkdir(
        m_sftp,
        path.toUtf8().constData(),
        LIBSSH2_SFTP_S_IRWXU | LIBSSH2_SFTP_S_IRGRP | LIBSSH2_SFTP_S_IXGRP | 
        LIBSSH2_SFTP_S_IROTH | LIBSSH2_SFTP_S_IXOTH
    );

    if (rc != 0) {
        emit errorOccurred("Failed to create directory: " + path);
        return false;
    }

    return true;
}

bool SftpClient::remove(const QString& path)
{
    if (!m_initialized || !m_sftp) {
        emit errorOccurred("SFTP not initialized");
        return false;
    }

    // Check if it's a directory
    LIBSSH2_SFTP_ATTRIBUTES attrs;
    int rc = libssh2_sftp_stat(m_sftp, path.toUtf8().constData(), &attrs);
    
    if (rc != 0) {
        emit errorOccurred("Path does not exist: " + path);
        return false;
    }

    if (LIBSSH2_SFTP_S_ISDIR(attrs.permissions)) {
        // Remove directory
        rc = libssh2_sftp_rmdir(m_sftp, path.toUtf8().constData());
    } else {
        // Remove file
        rc = libssh2_sftp_unlink(m_sftp, path.toUtf8().constData());
    }

    if (rc != 0) {
        emit errorOccurred("Failed to remove: " + path);
        return false;
    }

    return true;
}

bool SftpClient::rename(const QString& oldPath, const QString& newPath)
{
    if (!m_initialized || !m_sftp) {
        emit errorOccurred("SFTP not initialized");
        return false;
    }

    int rc = libssh2_sftp_rename(
        m_sftp,
        oldPath.toUtf8().constData(),
        newPath.toUtf8().constData()
    );

    if (rc != 0) {
        emit errorOccurred("Failed to rename: " + oldPath + " -> " + newPath);
        return false;
    }

    return true;
}

bool SftpClient::changePermissions(const QString& path, int permissions)
{
    if (!m_initialized || !m_sftp) {
        emit errorOccurred("SFTP not initialized");
        return false;
    }

    int rc = libssh2_sftp_chmod(m_sftp, path.toUtf8().constData(), permissions);

    if (rc != 0) {
        emit errorOccurred("Failed to change permissions: " + path);
        return false;
    }

    return true;
}

SftpFileEntry SftpClient::getFileInfo(const QString& path)
{
    SftpFileEntry entry;
    
    if (!m_initialized || !m_sftp) {
        emit errorOccurred("SFTP not initialized");
        return entry;
    }

    LIBSSH2_SFTP_ATTRIBUTES attrs;
    int rc = libssh2_sftp_stat(m_sftp, path.toUtf8().constData(), &attrs);
    
    if (rc != 0) {
        emit errorOccurred("Failed to get file info: " + path);
        return entry;
    }

    QFileInfo fileInfo(path);
    entry.name = fileInfo.fileName();
    entry.path = path;
    entry.size = attrs.filesize;
    entry.isDirectory = LIBSSH2_SFTP_S_ISDIR(attrs.permissions);
    entry.isFile = LIBSSH2_SFTP_S_ISREG(attrs.permissions);
    entry.permissions = formatPermissions(attrs.permissions);
    entry.modifiedAt = QDateTime::fromSecsSinceEpoch(attrs.mtime);
    entry.owner = QString::number(attrs.uid);
    entry.group = QString::number(attrs.gid);

    return entry;
}

bool SftpClient::exists(const QString& path)
{
    if (!m_initialized || !m_sftp) {
        return false;
    }

    LIBSSH2_SFTP_ATTRIBUTES attrs;
    int rc = libssh2_sftp_stat(m_sftp, path.toUtf8().constData(), &attrs);
    return rc == 0;
}

QString SftpClient::getCurrentDirectory() const
{
    return m_currentDirectory;
}

void SftpClient::setCurrentDirectory(const QString& path)
{
    m_currentDirectory = path;
}

void SftpClient::close()
{
    if (m_sftp) {
        libssh2_sftp_shutdown(m_sftp);
        m_sftp = nullptr;
    }
    m_initialized = false;
}

QString SftpClient::formatPermissions(long perms)
{
    QString result;
    result += LIBSSH2_SFTP_S_ISDIR(perms) ? "d" : "-";
    
    result += (perms & 0400) ? "r" : "-";
    result += (perms & 0200) ? "w" : "-";
    result += (perms & 0100) ? "x" : "-";
    
    result += (perms & 0040) ? "r" : "-";
    result += (perms & 0020) ? "w" : "-";
    result += (perms & 0010) ? "x" : "-";
    
    result += (perms & 0004) ? "r" : "-";
    result += (perms & 0002) ? "w" : "-";
    result += (perms & 0001) ? "x" : "-";
    
    return result;
}

long SftpClient::parsePermissions(const QString& perms)
{
    // Parse Unix permission string to octal
    long result = 0;
    // Implementation would parse "rwxr-xr--" format
    return result;
}
