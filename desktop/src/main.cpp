#include <QApplication>
#include <QStyleFactory>
#include <QTranslator>
#include <QLocale>
#include <QDir>
#include <QStandardPaths>
#include "ui/MainWindow.h"
#include "core/SshEngine.h"

int main(int argc, char *argv[])
{
    // High DPI scaling
    QApplication::setAttribute(Qt::AA_EnableHighDpiScaling);
    QApplication::setAttribute(Qt::AA_UseHighDpiPixmaps);
    
    QApplication app(argc, argv);
    
    // Application metadata
    app.setApplicationName("BlueSSH");
    app.setApplicationVersion("1.0.0");
    app.setOrganizationName("BlueSSH");
    app.setOrganizationDomain("bluessh.io");
    
    // Set application style
    app.setStyle(QStyleFactory::create("Fusion"));
    
    // Set dark palette by default
    QPalette darkPalette;
    darkPalette.setColor(QPalette::Window, QColor(13, 17, 23));
    darkPalette.setColor(QPalette::WindowText, QColor(201, 209, 217));
    darkPalette.setColor(QPalette::Base, QColor(22, 27, 34));
    darkPalette.setColor(QPalette::AlternateBase, QColor(33, 38, 45));
    darkPalette.setColor(QPalette::ToolTipBase, QColor(22, 27, 34));
    darkPalette.setColor(QPalette::ToolTipText, QColor(201, 209, 217));
    darkPalette.setColor(QPalette::Text, QColor(201, 209, 217));
    darkPalette.setColor(QPalette::Button, QColor(33, 38, 45));
    darkPalette.setColor(QPalette::ButtonText, QColor(201, 209, 217));
    darkPalette.setColor(QPalette::BrightText, QColor(255, 255, 255));
    darkPalette.setColor(QPalette::Link, QColor(79, 195, 247));
    darkPalette.setColor(QPalette::Highlight, QColor(79, 195, 247));
    darkPalette.setColor(QPalette::HighlightedText, QColor(13, 17, 23));
    app.setPalette(darkPalette);
    
    // Create config directory
    QString configDir = QStandardPaths::writableLocation(QStandardPaths::AppConfigLocation);
    QDir().mkpath(configDir);
    
    // Initialize SSH engine
    SshEngine engine;
    if (!engine.initialize()) {
        qCritical() << "Failed to initialize SSH engine";
        return -1;
    }
    
    // Create and show main window
    MainWindow mainWindow;
    mainWindow.show();
    
    // Event loop
    int result = app.exec();
    
    // Cleanup
    engine.shutdown();
    
    return result;
}
