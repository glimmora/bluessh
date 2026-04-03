#ifndef PORTFORWARDING_H
#define PORTFORWARDING_H

#include <QObject>
#include <QString>
#include <QList>
#include <QTcpServer>
#include <QTcpSocket>
#include <QMap>

class SshSession;

/**
 * Port forwarding rule
 */
struct PortForwardingRule {
    QString id;
    QString type; // "local", "remote", "dynamic"
    QString localHost = "127.0.0.1";
    int localPort = 0;
    QString remoteHost = "127.0.0.1";
    int remotePort = 0;
    bool enabled = true;
    QString description;
};

/**
 * Port Forwarding Manager
 * Handles local, remote, and dynamic (SOCKS5) port forwarding
 */
class PortForwardingManager : public QObject
{
    Q_OBJECT

public:
    explicit PortForwardingManager(QObject *parent = nullptr);
    ~PortForwardingManager();

    // Setup local port forwarding
    bool setupLocalForwarding(SshSession* session, const PortForwardingRule& rule);
    
    // Setup remote port forwarding
    bool setupRemoteForwarding(SshSession* session, const PortForwardingRule& rule);
    
    // Setup dynamic forwarding (SOCKS5 proxy)
    bool setupDynamicForwarding(SshSession* session, int localPort);
    
    // Stop forwarding rule
    bool stopForwarding(const QString& ruleId);
    
    // Stop all forwarding
    void stopAllForwarding();
    
    // Get active forwarding rules
    QList<PortForwardingRule> getActiveRules() const;
    
    // Check if rule is active
    bool isRuleActive(const QString& ruleId) const;

signals:
    void forwardingStarted(const QString& ruleId);
    void forwardingStopped(const QString& ruleId);
    void forwardingError(const QString& ruleId, const QString& error);
    void connectionForwarded(const QString& ruleId, const QString& clientAddress);

private:
    void handleLocalConnection();
    void handleDynamicConnection();
    QString generateRuleId();

    QMap<QString, PortForwardingRule> m_rules;
    QMap<QString, QTcpServer*> m_localServers;
    QMap<QString, QList<QTcpSocket*>> m_activeConnections;
};

#endif // PORTFORWARDING_H
