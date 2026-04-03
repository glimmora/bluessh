#ifndef COMPRESSIONMANAGER_H
#define COMPRESSIONMANAGER_H

#include <QObject>
#include <QString>
#include <QByteArray>

/**
 * Compression levels
 */
enum class CompressionLevel {
    None = 0,
    Low = 1,
    Medium = 2,
    High = 3
};

/**
 * Compression Manager - handles adaptive compression
 * Supports zlib and zstd compression algorithms
 */
class CompressionManager : public QObject
{
    Q_OBJECT

public:
    explicit CompressionManager(QObject *parent = nullptr);
    ~CompressionManager();

    // Initialize compression
    bool initialize(CompressionLevel level = CompressionLevel::None);

    // Compress data
    QByteArray compress(const QByteArray& data);

    // Decompress data
    QByteArray decompress(const QByteArray& data);

    // Set compression level
    void setCompressionLevel(CompressionLevel level);

    // Get current compression level
    CompressionLevel getCompressionLevel() const { return m_level; }

    // Get compression ratio
    double getCompressionRatio() const { return m_compressionRatio; }

    // Check if compression is active
    bool isActive() const { return m_level != CompressionLevel::None; }

signals:
    void compressionLevelChanged(CompressionLevel level);

private:
    int getZstdLevel(CompressionLevel level) const;
    int getZlibLevel(CompressionLevel level) const;

    CompressionLevel m_level = CompressionLevel::None;
    double m_compressionRatio = 1.0;
    bool m_initialized = false;
};

#endif // COMPRESSIONMANAGER_H
