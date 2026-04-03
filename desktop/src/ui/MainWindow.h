#ifndef MAINWINDOW_H
#define MAINWINDOW_H

#include <QMainWindow>
#include <QTabWidget>
#include <QSplitter>
#include <QToolBar>
#include <QStatusBar>
#include <QDockWidget>
#include <QSystemTrayIcon>
#include <memory>

class SshEngine;
class SessionManager;
class KeyManager;
class HostProfileDialog;
class SettingsDialog;
class QTreeView;
class QStandardItemModel;
class QLineEdit;

/**
 * Main Window - Bitvise-style interface
 * Features:
 * - Host profile tree view
 * - Multi-tab terminal
 * - SFTP file manager
 * - Port forwarding manager
 * - Session recording controls
 */
class MainWindow : public QMainWindow
{
    Q_OBJECT

public:
    explicit MainWindow(QWidget *parent = nullptr);
    ~MainWindow();

protected:
    void closeEvent(QCloseEvent *event) override;

private slots:
    // File menu
    void newConnection();
    void quickConnect();
    void disconnectCurrent();
    void exitApplication();

    // Edit menu
    void editHostProfile();
    void deleteHostProfile();
    void searchHosts();

    // View menu
    void toggleTerminal();
    void toggleSftp();
    void togglePortForwarding();
    void toggleFullScreen();

    // Session menu
    void newTab();
    void closeTab();
    void nextTab();
    void previousTab();
    void recordSession();
    void stopRecording();

    // Tools menu
    void openKeyManager();
    void openPortForwardingManager();
    void openSettings();

    // Help menu
    void showAbout();
    void checkForUpdates();

    // Host tree
    void onHostDoubleClicked(const QModelIndex& index);
    void onHostContextMenu(const QPoint& pos);

    // Tab changes
    void onTabChanged(int index);
    void onTabCloseRequested(int index);

    // System tray
    void onTrayIconActivated(QSystemTrayIcon::ActivationReason reason);

private:
    void setupUi();
    void setupMenuBar();
    void setupToolBar();
    void setupStatusBar();
    void setupHostTree();
    void setupTabWidget();
    void setupSystemTray();
    void loadHostProfiles();
    void saveSettings();
    void loadSettings();

    // Core components
    std::unique_ptr<SshEngine> m_sshEngine;
    std::unique_ptr<SessionManager> m_sessionManager;
    std::unique_ptr<KeyManager> m_keyManager;

    // UI components
    QTreeView* m_hostTree;
    QStandardItemModel* m_hostModel;
    QLineEdit* m_searchBox;
    QTabWidget* m_tabWidget;
    QSplitter* m_mainSplitter;
    QToolBar* m_mainToolBar;
    QStatusBar* m_statusBar;

    // System tray
    QSystemTrayIcon* m_trayIcon;

    // Dialogs
    HostProfileDialog* m_hostDialog;
    SettingsDialog* m_settingsDialog;

    // State
    bool m_isRecording = false;
    int m_activeSessionCount = 0;
};

#endif // MAINWINDOW_H
