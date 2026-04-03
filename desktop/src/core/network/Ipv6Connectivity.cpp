#include "network/Ipv6Connectivity.h"
#include <QHostInfo>
#include <QNetworkInterface>
#include <QDebug>

Ipv6Connectivity::Ipv6Connectivity(QObject *parent)
    : QObject(parent)
{
    // Check initial availability
    m_ipv4Available = testIpv4Connectivity();
    m_ipv6Available = testIpv6Connectivity();
}

Ipv6Connectivity::~Ipv6Connectivity()
{
}

bool Ipv6Connectivity::isIpv6Available()
{
    // Re-check availability
    m_ipv6Available = testIpv6Connectivity();
    return m_ipv6Available;
}

bool Ipv6Connectivity::hostSupportsIpv6(const QString& hostname)
{
    QHostInfo info = QHostInfo::fromName(hostname);
    
    for (const QHostAddress& addr : info.addresses()) {
        if (addr.protocol() == QAbstractSocket::IPv6Protocol) {
            return true;
        }
    }
    
    return false;
}

QList<QHostAddress> Ipv6Connectivity::resolveHost(const QString& hostname,
                                                   QAbstractSocket::NetworkLayerProtocol protocol)
{
    QHostInfo info = QHostInfo::fromName(hostname);
    QList<QHostAddress> addresses;
    
    for (const QHostAddress& addr : info.addresses()) {
        if (protocol == QAbstractSocket::AnyIPProtocol ||
            addr.protocol() == protocol) {
            addresses.append(addr);
        }
    }
    
    return addresses;
}

QAbstractSocket::NetworkLayerProtocol Ipv6Connectivity::getPreferredProtocol(const QString& hostname)
{
    if (m_forcedProtocol != QAbstractSocket::AnyIPProtocol) {
        return m_forcedProtocol;
    }
    
    bool ipv4 = false, ipv6 = false;
    
    QHostInfo info = QHostInfo::fromName(hostname);
    for (const QHostAddress& addr : info.addresses()) {
        if (addr.protocol() == QAbstractSocket::IPv4Protocol) ipv4 = true;
        if (addr.protocol() == QAbstractSocket::IPv6Protocol) ipv6 = true;
    }
    
    if (ipv6 && (m_preferIpv6 || !ipv4)) {
        return QAbstractSocket::IPv6Protocol;
    }
    
    return QAbstractSocket::IPv4Protocol;
}

QString Ipv6Connectivity::formatAddress(const QHostAddress& address)
{
    if (address.protocol() == QAbstractSocket::IPv6Protocol) {
        return "[" + address.toString() + "]";
    }
    return address.toString();
}

QHostAddress Ipv6Connectivity::parseAddress(const QString& addressStr)
{
    QString addr = addressStr;
    
    // Remove brackets if present
    if (addr.startsWith("[") && addr.endsWith("]")) {
        addr = addr.mid(1, addr.length() - 2);
    }
    
    return QHostAddress(addr);
}

bool Ipv6Connectivity::isIpv6Address(const QString& address)
{
    QString addr = address;
    
    // Remove brackets if present
    if (addr.startsWith("[") && addr.endsWith("]")) {
        addr = addr.mid(1, addr.length() - 2);
    }
    
    QHostAddress hostAddr(addr);
    return hostAddr.protocol() == QAbstractSocket::IPv6Protocol;
}

QString Ipv6Connectivity::wrapIpv6(const QString& address)
{
    if (isIpv6Address(address) && !address.startsWith("[")) {
        return "[" + address + "]";
    }
    return address;
}

QString Ipv6Connectivity::unwrapIpv6(const QString& address)
{
    if (address.startsWith("[") && address.endsWith("]")) {
        return address.mid(1, address.length() - 2);
    }
    return address;
}

void Ipv6Connectivity::setPreferIpv6(bool prefer)
{
    m_preferIpv6 = prefer;
}

void Ipv6Connectivity::setForceProtocol(QAbstractSocket::NetworkLayerProtocol protocol)
{
    m_forcedProtocol = protocol;
}

bool Ipv6Connectivity::testIpv6Connectivity()
{
    // Test IPv6 connectivity by checking local interfaces
    QList<QHostAddress> addresses = QNetworkInterface::allAddresses();
    
    for (const QHostAddress& addr : addresses) {
        if (addr.protocol() == QAbstractSocket::IPv6Protocol &&
            !addr.isLoopback()) {
            m_ipv6Available = true;
            emit ipv6Available(true);
            return true;
        }
    }
    
    m_ipv6Available = false;
    emit ipv6Available(false);
    return false;
}

bool Ipv6Connectivity::testIpv4Connectivity()
{
    // Test IPv4 connectivity by checking local interfaces
    QList<QHostAddress> addresses = QNetworkInterface::allAddresses();
    
    for (const QHostAddress& addr : addresses) {
        if (addr.protocol() == QAbstractSocket::IPv4Protocol &&
            !addr.isLoopback()) {
            m_ipv4Available = true;
            return true;
        }
    }
    
    m_ipv4Available = false;
    return false;
}
