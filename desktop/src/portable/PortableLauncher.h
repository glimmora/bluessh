#ifndef PORTABLE_LAUNCHER_H
#define PORTABLE_LAUNCHER_H

#include <QObject>
#include <QString>
#include <QDir>
#include <QSettings>
#include <QProcess>

/**
 * Portable Distribution Launcher
 * Enables install-free, portable operation
 */
class PortableLauncher : public QObject
{
    Q_OBJECT

public:
    explicit PortableLauncher(QObject *parent = nullptr);
    ~PortableLauncher();

    // Initialize portable mode
    bool initialize(const QString& appDir);
    
    // Get portable directory
    QString getPortableDir() const { return m_portableDir; }
    
    // Get config directory
    QString getConfigDir() const { return m_configDir; }
    
    // Get data directory
    QString getDataDir() const { return m_dataDir; }
    
    // Get cache directory
    QString getCacheDir() const { return m_cacheDir; }
    
    // Get logs directory
    QString getLogsDir() const { return m_logsDir; }
    
    // Get profiles directory
    QString getProfilesDir() const { return m_profilesDir; }
    
    // Get keys directory
    QString getKeysDir() const { return m_keysDir; }
    
    // Check if running in portable mode
    bool isPortableMode() const { return m_isPortable; }
    
    // Create portable distribution
    bool createPortableDistribution(const QString& outputDir);
    
    // Launch application
    bool launchApplication(const QStringList& arguments = QStringList());
    
    // Set environment variables
    void setEnvironmentVariable(const QString& key, const QString& value);
    
    // Get environment
    QProcessEnvironment getEnvironment() const { return m_environment; }

signals:
    void initialized();
    void error(const QString& message);

private:
    bool createDirectoryStructure();
    bool copyDependencies();
    bool createDefaultConfig();
    bool setupEnvironment();
    QString findExecutable();
    QStringList getLibraryPaths();

    QString m_portableDir;
    QString m_configDir;
    QString m_dataDir;
    QString m_cacheDir;
    QString m_logsDir;
    QString m_profilesDir;
    QString m_keysDir;
    QString m_executablePath;
    
    bool m_isPortable = false;
    QProcessEnvironment m_environment;
    QSettings* m_settings = nullptr;
};

#endif // PORTABLE_LAUNCHER_H
