#ifndef BVC_PROFILE_H
#define BVC_PROFILE_H

#include <QObject>
#include <QString>
#include <QMap>
#include <QList>
#include <QDateTime>
#include <QDomDocument>

/**
 * .bvc Profile - Bitvise-compatible profile format
 * XML-based configuration file for SSH connections
 */
struct BvcProfile {
    // Profile metadata
    QString profileName;
    QString profileId;
    QDateTime created;
    QDateTime modified;
    QString version = "1.0";
    
    // Server settings
    QString host;
    int port = 22;
    QString username;
    QString initialMethod = "password";  // password, publickey, keyboard-interactive, gssapi
    
    // Authentication
    struct Authentication {
        QString method;
        QString password;  // Encrypted
        QString keyPath;
        QString keyPassphrase;  // Encrypted
        QString gssapiPrincipal;
        bool tryKeyboardInteractive = true;
        bool tryGssapi = false;
        bool tryPublicKey = true;
        bool tryPassword = true;
        QStringList keyPaths;
    } auth;
    
    // Terminal settings
    struct Terminal {
        QString type = "xterm-256color";  // xterm, vt100, bvterm
        int columns = 80;
        int rows = 24;
        bool enablePty = true;
        QString command;  // Command to execute instead of shell
        QString environment;  // Environment variables
        bool enableAgentForwarding = false;
        bool enableX11Forwarding = false;
        QString x11Display;
        bool enableCompression = true;
        int compressionLevel = 3;
    } terminal;
    
    // SFTP settings
    struct Sftp {
        bool enableSftp = true;
        QString initialRemoteDirectory;
        QString localDirectory;
        bool syncDirectories = false;
        int transferThreads = 4;
        bool preserveTimestamps = true;
        bool showHiddenFiles = false;
        bool autoResume = true;
    } sftp;
    
    // Port forwarding
    struct Forwarding {
        struct Rule {
            QString id;
            QString type;  // local, remote, dynamic
            QString listenHost;
            int listenPort;
            QString targetHost;
            int targetPort;
            bool enabled = true;
            QString description;
        };
        QList<Rule> rules;
        bool enableForwarding = false;
    } forwarding;
    
    // RDP settings
    struct Rdp {
        bool enableRdp = false;
        QString rdpHost;
        int rdpPort = 3389;
        QString rdpUsername;
        QString rdpPassword;  // Encrypted
        int width = 1920;
        int height = 1080;
        bool fullscreen = false;
    } rdp;
    
    // Connection settings
    struct Connection {
        int timeout = 30;
        int keepaliveInterval = 30;
        bool enableKeepalive = true;
        int maxReconnectAttempts = 5;
        bool autoReconnect = true;
        int reconnectDelay = 5;
        bool enableIPv6 = true;
        bool preferIPv6 = false;
        QString proxyHost;
        int proxyPort = 0;
        QString proxyType;  // none, socks4, socks5, http
        QString proxyUsername;
        QString proxyPassword;  // Encrypted
    } connection;
    
    // Logging
    struct Logging {
        bool enableLogging = false;
        QString logFile;
        int logLevel = 2;  // 0=none, 1=errors, 2=info, 3=debug
        bool logTerminal = false;
        bool logSftp = false;
        bool logForwarding = false;
    } logging;
    
    // Custom data
    QMap<QString, QString> customData;
    QStringList tags;
    QString notes;
};

/**
 * BVC Profile Manager
 * Handles .bvc file parsing, serialization, and management
 */
class BvcProfileManager : public QObject
{
    Q_OBJECT

public:
    explicit BvcProfileManager(QObject *parent = nullptr);
    ~BvcProfileManager();

    // Load profile from .bvc file
    bool loadProfile(const QString& filePath, BvcProfile& profile);
    
    // Save profile to .bvc file
    bool saveProfile(const QString& filePath, const BvcProfile& profile);
    
    // Load profile from XML string
    bool loadProfileFromXml(const QString& xml, BvcProfile& profile);
    
    // Save profile to XML string
    QString saveProfileToXml(const BvcProfile& profile);
    
    // Import profile from Bitvise format
    bool importBitviseProfile(const QString& filePath, BvcProfile& profile);
    
    // Export profile to Bitvise format
    bool exportBitviseProfile(const QString& filePath, const BvcProfile& profile);
    
    // List profiles in directory
    QList<QString> listProfiles(const QString& directory);
    
    // Validate profile
    bool validateProfile(const BvcProfile& profile, QStringList& errors);
    
    // Encrypt sensitive fields
    void encryptProfile(BvcProfile& profile);
    
    // Decrypt sensitive fields
    void decryptProfile(BvcProfile& profile);
    
    // Create default profile
    BvcProfile createDefaultProfile();
    
    // Clone profile
    BvcProfile cloneProfile(const BvcProfile& source);

signals:
    void profileLoaded(const QString& filePath);
    void profileSaved(const QString& filePath);
    void profileError(const QString& filePath, const QString& error);

private:
    // XML parsing helpers
    QString readElementText(const QDomElement& parent, const QString& tagName, const QString& defaultValue = QString());
    int readElementInt(const QDomElement& parent, const QString& tagName, int defaultValue = 0);
    bool readElementBool(const QDomElement& parent, const QString& tagName, bool defaultValue = false);
    void writeElement(QDomDocument& doc, QDomElement& parent, const QString& tagName, const QString& value);
    void writeElement(QDomDocument& doc, QDomElement& parent, const QString& tagName, int value);
    void writeElement(QDomDocument& doc, QDomElement& parent, const QString& tagName, bool value);
    
    // Parse sections
    void parseAuthentication(const QDomElement& element, BvcProfile::Authentication& auth);
    void parseTerminal(const QDomElement& element, BvcProfile::Terminal& terminal);
    void parseSftp(const QDomElement& element, BvcProfile::Sftp& sftp);
    void parseForwarding(const QDomElement& element, BvcProfile::Forwarding& forwarding);
    void parseRdp(const QDomElement& element, BvcProfile::Rdp& rdp);
    void parseConnection(const QDomElement& element, BvcProfile::Connection& connection);
    void parseLogging(const QDomElement& element, BvcProfile::Logging& logging);
    
    // Write sections
    void writeAuthentication(QDomDocument& doc, QDomElement& parent, const BvcProfile::Authentication& auth);
    void writeTerminal(QDomDocument& doc, QDomElement& parent, const BvcProfile::Terminal& terminal);
    void writeSftp(QDomDocument& doc, QDomElement& parent, const BvcProfile::Sftp& sftp);
    void writeForwarding(QDomDocument& doc, QDomElement& parent, const BvcProfile::Forwarding& forwarding);
    void writeRdp(QDomDocument& doc, QDomElement& parent, const BvcProfile::Rdp& rdp);
    void writeConnection(QDomDocument& doc, QDomElement& parent, const BvcProfile::Connection& connection);
    void writeLogging(QDomDocument& doc, QDomElement& parent, const BvcProfile::Logging& logging);
    
    // Encryption
    QString encryptString(const QString& plain);
    QString decryptString(const QString& encrypted);
    
    QString m_encryptionKey;
};

#endif // BVC_PROFILE_H
