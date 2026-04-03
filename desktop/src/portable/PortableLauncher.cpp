#include "portable/PortableLauncher.h"
#include <QDir>
#include <QFile>
#include <QStandardPaths>
#include <QCoreApplication>
#include <QSettings>
#include <QDebug>
#include <QProcessEnvironment>
#include <QJsonDocument>
#include <QJsonObject>

PortableLauncher::PortableLauncher(QObject *parent)
    : QObject(parent)
{
}

PortableLauncher::~PortableLauncher()
{
    if (m_settings) {
        m_settings->sync();
        delete m_settings;
    }
}

bool PortableLauncher::initialize(const QString& appDir)
{
    m_portableDir = appDir;
    m_configDir = m_portableDir + "/config";
    m_dataDir = m_portableDir + "/data";
    m_cacheDir = m_portableDir + "/cache";
    m_logsDir = m_portableDir + "/logs";
    m_profilesDir = m_configDir + "/profiles";
    m_keysDir = m_configDir + "/keys";
    
    if (!createDirectoryStructure()) {
        emit error("Failed to create directory structure");
        return false;
    }
    
    if (!setupEnvironment()) {
        emit error("Failed to setup environment");
        return false;
    }
    
    if (!createDefaultConfig()) {
        emit error("Failed to create default config");
        return false;
    }
    
    m_isPortable = true;
    m_executablePath = findExecutable();
    
    // Create settings in portable location
    m_settings = new QSettings(m_configDir + "/settings.ini", QSettings::IniFormat, this);
    
    qDebug() << "Portable mode initialized:" << m_portableDir;
    emit initialized();
    return true;
}

bool PortableLauncher::createDirectoryStructure()
{
    QStringList dirs = {
        m_configDir,
        m_dataDir,
        m_cacheDir,
        m_logsDir,
        m_profilesDir,
        m_keysDir,
        m_dataDir + "/sessions",
        m_dataDir + "/recordings",
        m_dataDir + "/transfers",
        m_logsDir + "/crash"
    };
    
    for (const QString& dir : dirs) {
        if (!QDir().mkpath(dir)) {
            emit error("Failed to create directory: " + dir);
            return false;
        }
    }
    
    return true;
}

bool PortableLauncher::setupEnvironment()
{
    m_environment = QProcessEnvironment::systemEnvironment();
    
    // Set portable paths
    m_environment.insert("BLUESSH_CONFIG", m_configDir);
    m_environment.insert("BLUESSH_DATA", m_dataDir);
    m_environment.insert("BLUESSH_CACHE", m_cacheDir);
    m_environment.insert("BLUESSH_LOGS", m_logsDir);
    m_environment.insert("BLUESSH_PROFILES", m_profilesDir);
    m_environment.insert("BLUESSH_KEYS", m_keysDir);
    m_environment.insert("BLUESSH_PORTABLE", "1");
    
    // Set library paths for portable Qt
#ifdef Q_OS_LINUX
    QString libPath = m_portableDir + "/lib";
    QString currentLdPath = m_environment.value("LD_LIBRARY_PATH");
    m_environment.insert("LD_LIBRARY_PATH", libPath + (currentLdPath.isEmpty() ? "" : ":" + currentLdPath));
    m_environment.insert("QT_PLUGIN_PATH", m_portableDir + "/plugins");
    m_environment.insert("QT_QPA_PLATFORM_PLUGIN_PATH", m_portableDir + "/plugins/platforms");
#elif defined(Q_OS_WIN)
    QString path = m_environment.value("PATH");
    m_environment.insert("PATH", m_portableDir + "\\bin;" + 
                               m_portableDir + "\\lib;" + 
                               (path.isEmpty() ? "" : path));
#endif
    
    return true;
}

bool PortableLauncher::createDefaultConfig()
{
    QString configPath = m_configDir + "/config.json";
    
    if (QFile::exists(configPath)) {
        return true;  // Config already exists
    }
    
    QJsonObject config;
    config["version"] = "1.0.0";
    config["portable"] = true;
    
    QJsonObject terminal;
    terminal["type"] = "xterm-256color";
    terminal["columns"] = 80;
    terminal["rows"] = 24;
    terminal["scrollbackSize"] = 10000;
    terminal["fontSize"] = 12;
    terminal["theme"] = "dark";
    config["terminal"] = terminal;
    
    QJsonObject connection;
    connection["timeout"] = 30;
    connection["keepaliveInterval"] = 30;
    connection["autoReconnect"] = true;
    connection["maxReconnectAttempts"] = 5;
    connection["enableIPv6"] = true;
    config["connection"] = connection;
    
    QJsonObject security;
    security["hostKeyVerification"] = true;
    security["compression"] = true;
    security["compressionLevel"] = 3;
    config["security"] = security;
    
    QJsonDocument doc(config);
    
    QFile file(configPath);
    if (!file.open(QIODevice::WriteOnly)) {
        return false;
    }
    
    file.write(doc.toJson(QJsonDocument::Indented));
    file.close();
    
    return true;
}

bool PortableLauncher::launchApplication(const QStringList& arguments)
{
    if (m_executablePath.isEmpty()) {
        emit error("Executable not found");
        return false;
    }
    
    QProcess* process = new QProcess(this);
    process->setProcessEnvironment(m_environment);
    process->setWorkingDirectory(m_portableDir);
    
    connect(process, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, [process](int exitCode, QProcess::ExitStatus exitStatus) {
        qDebug() << "Application exited with code:" << exitCode;
        process->deleteLater();
    });
    
    process->start(m_executablePath, arguments);
    
    if (!process->waitForStarted()) {
        emit error("Failed to start application: " + process->errorString());
        process->deleteLater();
        return false;
    }
    
    qDebug() << "Application started with PID:" << process->processId();
    return true;
}

void PortableLauncher::setEnvironmentVariable(const QString& key, const QString& value)
{
    m_environment.insert(key, value);
}

QProcessEnvironment PortableLauncher::getEnvironment() const
{
    return m_environment;
}

QString PortableLauncher::findExecutable()
{
#ifdef Q_OS_WIN
    QStringList names = {"bluessh.exe", "BlueSSH.exe"};
    for (const QString& name : names) {
        QString path = m_portableDir + "/" + name;
        if (QFile::exists(path)) {
            return path;
        }
    }
#else
    QString path = m_portableDir + "/bluessh";
    if (QFile::exists(path)) {
        return path;
    }
#endif
    
    return QString();
}

bool PortableLauncher::createPortableDistribution(const QString& outputDir)
{
    QDir output(outputDir);
    if (!output.exists()) {
        output.mkpath(".");
    }
    
    // Copy executable
    QString appPath = QCoreApplication::applicationFilePath();
    QString destPath = output.filePath(QFileInfo(appPath).fileName());
    
    if (!QFile::copy(appPath, destPath)) {
        emit error("Failed to copy executable");
        return false;
    }
    
    // Make executable on Linux
#ifdef Q_OS_LINUX
    QFile::setPermissions(destPath, QFile::ExeOwner | QFile::ReadOwner | QFile::WriteOwner |
                                       QFile::ExeGroup | QFile::ReadGroup |
                                       QFile::ExeOther | QFile::ReadOther);
#endif
    
    // Create directory structure
    QStringList dirs = {"config", "config/profiles", "config/keys", "data", "logs", "lib", "plugins"};
    for (const QString& dir : dirs) {
        output.mkpath(dir);
    }
    
    // Create launcher script
#ifdef Q_OS_LINUX
    QString scriptPath = output.filePath("BlueSSH.sh");
    QFile script(scriptPath);
    if (script.open(QIODevice::WriteOnly)) {
        script.write("#!/bin/bash\n");
        script.write("cd \"$(dirname \"$0\")\"\n");
        script.write("export LD_LIBRARY_PATH=\"$PWD/lib:$LD_LIBRARY_PATH\"\n");
        script.write("export QT_PLUGIN_PATH=\"$PWD/plugins\"\n");
        script.write("./bluessh \"$@\"\n");
        script.close();
        
        QFile::setPermissions(scriptPath, QFile::ExeOwner | QFile::ReadOwner |
                                               QFile::ExeGroup | QFile::ReadGroup |
                                               QFile::ExeOther | QFile::ReadOther);
    }
#endif
    
    // Create README
    QString readmePath = output.filePath("README.txt");
    QFile readme(readmePath);
    if (readme.open(QIODevice::WriteOnly)) {
        readme.write("BlueSSH - Portable SSH Client\n");
        readme.write("==============================\n\n");
        readme.write("This is a portable version of BlueSSH.\n");
        readme.write("No installation required.\n\n");
#ifdef Q_OS_WIN
        readme.write("To run: Double-click BlueSSH.exe\n");
#else
        readme.write("To run: ./BlueSSH.sh\n");
#endif
        readme.close();
    }
    
    qDebug() << "Portable distribution created at:" << outputDir;
    return true;
}
