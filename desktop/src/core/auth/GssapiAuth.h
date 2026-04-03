#ifndef GSSAPI_AUTH_H
#define GSSAPI_AUTH_H

#include <QObject>
#include <QString>
#include <QByteArray>
#include <functional>

/**
 * GSSAPI/Kerberos Authentication
 * Integrates with system Kerberos for single sign-on
 */
class GssapiAuth : public QObject
{
    Q_OBJECT

public:
    explicit GssapiAuth(QObject *parent = nullptr);
    ~GssapiAuth();

    // Initialize GSSAPI
    bool initialize();
    
    // Acquire credentials
    bool acquireCredentials(const QString& principal = QString());
    
    // Initialize security context
    bool initContext(const QString& targetName);
    
    // Get context token
    QByteArray getContextToken();
    
    // Process challenge from server
    bool processChallenge(const QByteArray& challenge);
    
    // Get response token
    QByteArray getResponseToken();
    
    // Check if authentication is complete
    bool isComplete() const { return m_authComplete; }
    
    // Get principal name
    QString getPrincipal() const { return m_principal; }
    
    // Get available credentials
    QStringList getAvailableCredentials();
    
    // Release credentials
    void releaseCredentials();
    
    // Cleanup
    void cleanup();

signals:
    void authenticationComplete();
    void authenticationFailed(const QString& error);
    void credentialsExpired();

private:
    bool m_initialized = false;
    bool m_authComplete = false;
    QString m_principal;
    QString m_targetName;
    QByteArray m_contextToken;
    QByteArray m_responseToken;
    
    // GSSAPI internal state (opaque)
    void* m_credHandle = nullptr;
    void* m_contextHandle = nullptr;
};

#endif // GSSAPI_AUTH_H
