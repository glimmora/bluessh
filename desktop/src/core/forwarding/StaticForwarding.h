#ifndef STATIC_FORWARDING_H
#define STATIC_FORWARDING_H

#include <QObject>
#include <QString>
#include <QTcpServer>
#include <QTcpSocket>
#include <QMap>
#include <QList>

/**
 * Forwarding direction
 */
enum class ForwardingDirection {
    C2S,  // Client-to-Server (Local forwarding)
    S2C   // Server-to-Client (Remote forwarding)
};

/**
 * Static forwarding rule
 */
struct StaticForwardingRule {
    QString id;
    ForwardingDirection direction;
    QString listenHost;
    int listenPort;
    QString targetHost;
    int targetPort;
    bool enabled = true;
    QString description;
};

/**
 * Static Port Forwarding Manager
 * Handles C2S (local) and S2C (remote) port forwarding
 */
class StaticForwardingManager : public QObject
{
    Q_OBJECT

public:
    explicit StaticForwardingManager(QObject *parent = nullptr);
    ~StaticForwardingManager();

    // Add forwarding rule
    bool addRule(const StaticForwardingRule& rule);
    
    // Remove forwarding rule
    bool removeRule(const QString& ruleId);
    
    // Enable/disable rule
    bool enableRule(const QString& ruleId, bool enable);
    
    // Start all forwarding
    bool startAllForwarding();
    
    // Stop all forwarding
    void stopAllForwarding();
    
    // Get active rules
    QList<StaticForwardingRule> getActiveRules() const;
    
    // Check if rule is active
    bool isRuleActive(const QString& ruleId) const;
    
    // Set SSH session
    void setSshSession(void* sshSession);

signals:
    void ruleAdded(const QString& ruleId);
    void ruleRemoved(const QString& ruleId);
    void forwardingStarted(const QString& ruleId);
    void forwardingStopped(const QString& ruleId);
    void forwardingError(const QString& ruleId, const QString& error);
    void connectionForwarded(const QString& ruleId, const QString& source, const QString& destination);

private slots:
    void onLocalConnection();
    void onRemoteConnection();
    void onClientReadyRead();
    void onTunnelReadyRead();
    void onClientError(QAbstractSocket::SocketError error);
    void onTunnelError(QAbstractSocket::SocketError error);

private:
    bool startLocalForwarding(const StaticForwardingRule& rule);
    bool startRemoteForwarding(const StaticForwardingRule& rule);
    bool stopLocalForwarding(const QString& ruleId);
    bool stopRemoteForwarding(const QString& ruleId);
    void handleLocalConnection(QTcpSocket* client, const QString& ruleId);
    void handleRemoteConnection(QTcpSocket* client, const QString& ruleId);
    QString generateRuleId();

    void* m_sshSession = nullptr;
    QMap<QString, StaticForwardingRule> m_rules;
    QMap<QString, QTcpServer*> m_localServers;
    QMap<QString, QTcpServer*> m_remoteServers;
    QMap<QTcpSocket*, QString> m_clientToRule;
    QMap<QTcpSocket*, QTcpSocket*> m_clientToTunnel;
    QMap<QTcpSocket*, QTcpSocket*> m_tunnelToClient;
};

#endif // STATIC_FORWARDING_H
