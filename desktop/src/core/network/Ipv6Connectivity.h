#ifndef IPV6_CONNECTIVITY_H
#define IPV6_CONNECTIVITY_H

#include <QObject>
#include <QString>
#include <QHostAddress>
#include <QAbstractSocket>

/**
 * IPv6 Connectivity Manager
 * Handles IPv4/IPv6 dual-stack support
 */
class Ipv6Connectivity : public QObject
{
    Q_OBJECT

public:
    explicit Ipv6Connectivity(QObject *parent = nullptr);
    ~Ipv6Connectivity();

    // Check if IPv6 is available
    bool isIpv6Available();
    
    // Check if host supports IPv6
    bool hostSupportsIpv6(const QString& hostname);
    
    // Resolve hostname to addresses
    QList<QHostAddress> resolveHost(const QString& hostname, 
                                     QAbstractSocket::NetworkLayerProtocol protocol = QAbstractSocket::AnyIPProtocol);
    
    // Get preferred protocol
    QAbstractSocket::NetworkLayerProtocol getPreferredProtocol(const QString& hostname);
    
    // Format address for display
    static QString formatAddress(const QHostAddress& address);
    
    // Parse address string
    static QHostAddress parseAddress(const QString& addressStr);
    
    // Check if address is IPv6
    static bool isIpv6Address(const QString& address);
    
    // Wrap IPv6 address in brackets for URLs
    static QString wrapIpv6(const QString& address);
    
    // Unwrap IPv6 address from brackets
    static QString unwrapIpv6(const QString& address);
    
    // Set IPv6 preference
    void setPreferIpv6(bool prefer);
    bool preferIpv6() const { return m_preferIpv6; }
    
    // Force IPv4 or IPv6
    void setForceProtocol(QAbstractSocket::NetworkLayerProtocol protocol);
    QAbstractSocket::NetworkLayerProtocol getForcedProtocol() const { return m_forcedProtocol; }
    
    // Test connectivity
    bool testIpv6Connectivity();
    bool testIpv4Connectivity();

signals:
    void ipv6Available(bool available);
    void connectivityTestComplete(bool ipv4, bool ipv6);

private:
    bool m_preferIpv6 = false;
    QAbstractSocket::NetworkLayerProtocol m_forcedProtocol = QAbstractSocket::AnyIPProtocol;
    bool m_ipv6Available = false;
    bool m_ipv4Available = false;
};

#endif // IPV6_CONNECTIVITY_H
