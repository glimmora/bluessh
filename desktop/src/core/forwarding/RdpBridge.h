#ifndef RDP_BRIDGE_H
#define RDP_BRIDGE_H

#include <QObject>
#include <QString>
#include <QTcpServer>
#include <QTcpSocket>
#include <QProcess>
#include <QMap>

/**
 * RDP Connection configuration
 */
struct RdpConfig {
    QString host;
    int port = 3389;
    QString username;
    QString password;
    QString domain;
    int width = 1920;
    int height = 1080;
    int colorDepth = 32;
    bool fullscreen = false;
    bool enableSound = true;
    bool enablePrinter = false;
    bool enableClipboard = true;
    bool enableDriveSharing = false;
    QString drivePath;
    QString workingDirectory;
    QString remoteApplication;
};

/**
 * RDP Bridge - Automatic remote desktop forwarding
 * Bridges SSH connections to RDP sessions
 */
class RdpBridge : public QObject
{
    Q_OBJECT

public:
    explicit RdpBridge(QObject *parent = nullptr);
    ~RdpBridge();

    // Start RDP bridge on local port
    bool startBridge(int localPort, const RdpConfig& config);
    
    // Stop RDP bridge
    bool stopBridge(int localPort);
    
    // Stop all bridges
    void stopAllBridges();
    
    // Launch RDP client directly
    bool launchRdpClient(const RdpConfig& config);
    
    // Get active bridges
    QList<int> getActiveBridges() const;
    
    // Check if bridge is active
    bool isBridgeActive(int port) const;

signals:
    void bridgeStarted(int port);
    void bridgeStopped(int port);
    void bridgeError(int port, const QString& error);
    void rdpClientLaunched(const QString& processId);
    void rdpClientExited(const QString& processId, int exitCode);

private slots:
    void onNewConnection();
    void onClientReadyRead();
    void onRdpProcessStarted();
    void onRdpProcessFinished(int exitCode, QProcess::ExitStatus exitStatus);
    void onRdpProcessError(QProcess::ProcessError error);

private:
    void forwardToRdp(QTcpSocket* client, const RdpConfig& config);
    QString findRdpClient();
    QStringList buildRdpCommandLine(const RdpConfig& config);
    QString generateRdpFile(const RdpConfig& config);

    QMap<int, QTcpServer*> m_bridges;
    QMap<int, RdpConfig> m_bridgeConfigs;
    QMap<QTcpSocket*, int> m_clientToBridge;
    QMap<QString, QProcess*> m_rdpProcesses;
    QString m_rdpClientPath;
};

#endif // RDP_BRIDGE_H
