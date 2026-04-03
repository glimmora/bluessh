#ifndef RECORDINGMANAGER_H
#define RECORDINGMANAGER_H

#include <QObject>
#include <QString>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QDateTime>

/**
 * Recording format
 */
enum class RecordingFormat {
    Asciinema,  // .cast format
    VncRec,     // VNC recording
    RdpRec      // RDP recording
};

/**
 * Recording metadata
 */
struct RecordingMetadata {
    QString sessionId;
    QString host;
    qint64 startTime;
    qint64 endTime = 0;
    RecordingFormat format = RecordingFormat::Asciinema;
    QString filePath;
    int width = 80;
    int height = 24;
    QMap<QString, QString> environment;
};

/**
 * Recording Manager - handles session recording and playback
 * Supports asciinema v2 format for terminal sessions
 */
class RecordingManager : public QObject
{
    Q_OBJECT

public:
    explicit RecordingManager(QObject *parent = nullptr);
    ~RecordingManager();

    // Start recording a session
    bool startRecording(const QString& sessionId, const QString& host,
                       const QString& outputPath, int width = 80, int height = 24);

    // Stop recording
    bool stopRecording(const QString& sessionId);

    // Write terminal output to recording
    bool writeOutput(const QString& sessionId, const QString& data);

    // Check if session is being recorded
    bool isRecording(const QString& sessionId) const;

    // Get recording metadata
    RecordingMetadata getMetadata(const QString& sessionId) const;

    // Playback recording
    bool playRecording(const QString& filePath, std::function<void(double, const QString&)> callback);

    // List recordings
    QList<RecordingMetadata> listRecordings(const QString& directory) const;

    // Delete recording
    bool deleteRecording(const QString& filePath);

signals:
    void recordingStarted(const QString& sessionId);
    void recordingStopped(const QString& sessionId);
    void recordingError(const QString& sessionId, const QString& error);

private:
    QString generateCastHeader(const RecordingMetadata& metadata);
    QString formatTimestamp(double elapsed);

    QMap<QString, QFile*> m_recordingFiles;
    QMap<QString, RecordingMetadata> m_metadata;
    QMap<QString, qint64> m_startTimes;
};

#endif // RECORDINGMANAGER_H
