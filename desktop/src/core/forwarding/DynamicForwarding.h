#ifndef DYNAMIC_FORWARDING_H
#define DYNAMIC_FORWARDING_H

#include <QObject>
#include <QString>
#include <QTcpServer>
#include <QTcpSocket>
#include <QMap>
#include <QByteArray>
#include <functional>

/**
 * Proxy type enumeration
 */
enum class ProxyType {
    SOCKS4,
    SOCKS4A,
    SOCKS5,
    HTTP
};

/**
 * SOCKS5 authentication method
 */
enum class Socks5AuthMethod {
    NoAuth,
    UsernamePassword,
    GSSAPI
};

/**
 * Forwarding rule for dynamic port forwarding
 */
struct DynamicForwardingRule {
    QString id;
    ProxyType type;
    QString listenHost = "127.0.0.1";
    int listenPort = 0;
    bool enabled = true;
    Socks5AuthMethod authMethod = Socks5AuthMethod::NoAuth;
    QString username;
    QString password;
    QString description;
};

/**
 * Dynamic Port Forwarding Manager
 * Supports SOCKS4, SOCKS4A, SOCKS5, and HTTP proxy
 */
class DynamicForwardingManager : public QObject
{
    Q_OBJECT

public:
    explicit DynamicForwardingManager(QObject *parent = nullptr);
    ~DynamicForwardingManager();

    // Start dynamic forwarding
    bool startForwarding(const DynamicForwardingRule& rule);
    
    // Stop dynamic forwarding
    bool stopForwarding(const QString& ruleId);
    
    // Stop all forwarding
    void stopAllForwarding();
    
    // Get active rules
    QList<DynamicForwardingRule> getActiveRules() const;
    
    // Check if rule is active
    bool isRuleActive(const QString& ruleId) const;
    
    // Set SSH session for tunneling
    void setSshSession(void* sshSession);

signals:
    void forwardingStarted(const QString& ruleId);
    void forwardingStopped(const QString& ruleId);
    void forwardingError(const QString& ruleId, const QString& error);
    void connectionForwarded(const QString& ruleId, const QString& destination);
    void authenticationRequired(const QString& ruleId, const QString& username, const QString& password);

private slots:
    void onNewConnection();
    void onClientReadyRead();
    void onClientConnected();
    void onTunnelReadyRead();
    void onTunnelConnected();
    void onClientError(QAbstractSocket::SocketError error);
    void onTunnelError(QAbstractSocket::SocketError error);

private:
    // SOCKS4/4A handling
    bool handleSocks4Request(QTcpSocket* client, QString& host, int& port);
    bool handleSocks4ARequest(QTcpSocket* client, QString& host, int& port);
    
    // SOCKS5 handling
    bool handleSocks5Negotiation(QTcpSocket* client);
    bool handleSocks5Auth(QTcpSocket* client);
    bool handleSocks5Request(QTcpSocket* client, QString& host, int& port);
    
    // HTTP proxy handling
    bool handleHttpRequest(QTcpSocket* client, QString& host, int& port);
    
    // Create tunnel through SSH
    bool createTunnel(const QString& host, int port, QTcpSocket*& tunnel);
    
    // Send SOCKS response
    void sendSocks4Response(QTcpSocket* client, bool success);
    void sendSocks5Response(QTcpSocket* client, bool success);
    void sendHttpResponse(QTcpSocket* client, bool success);
    
    // Generate rule ID
    QString generateRuleId();

    // SSH session pointer
    void* m_sshSession = nullptr;
    
    // Active servers
    QMap<QString, QTcpServer*> m_servers;
    
    // Active rules
    QMap<QString, DynamicForwardingRule> m_rules;
    
    // Client connections
    QMap<QTcpSocket*, QString> m_clientToRule;
    QMap<QTcpSocket*, QTcpSocket*> m_clientToTunnel;
    QMap<QTcpSocket*, QTcpSocket*> m_tunnelToClient;
    
    // Connection state
    enum class ConnectionState {
        WaitingForRequest,
        Authenticating,
        Connecting,
        Forwarding
    };
    QMap<QTcpSocket*, ConnectionState> m_connectionStates;
    QMap<QTcpSocket*, QByteArray> m_requestBuffer;
};

#endif // DYNAMIC_FORWARDING_H
