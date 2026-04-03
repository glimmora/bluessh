#ifndef MULTI_TERMINAL_MANAGER_H
#define MULTI_TERMINAL_MANAGER_H

#include <QObject>
#include <QString>
#include <QMap>
#include <QList>
#include <memory>

class TerminalEmulator;
class SshSession;

/**
 * Terminal window within a session
 */
struct TerminalWindow {
    QString id;
    QString sessionId;
    std::shared_ptr<TerminalEmulator> emulator;
    LIBSSH2_CHANNEL* channel = nullptr;
    int columns = 80;
    int rows = 24;
    QString title;
    bool isActive = false;
    QDateTime createdAt;
};

/**
 * Multi-Terminal Session Manager
 * Manages multiple terminal windows within a single SSH session
 */
class MultiTerminalManager : public QObject
{
    Q_OBJECT

public:
    explicit MultiTerminalManager(QObject *parent = nullptr);
    ~MultiTerminalManager();

    // Create new terminal window in session
    QString createTerminalWindow(const QString& sessionId, const QString& terminalType = "xterm-256color");
    
    // Close terminal window
    bool closeTerminalWindow(const QString& windowId);
    
    // Close all terminals in session
    void closeAllTerminals(const QString& sessionId);
    
    // Get terminal window
    TerminalWindow* getTerminalWindow(const QString& windowId);
    
    // Get all terminals in session
    QList<TerminalWindow*> getSessionTerminals(const QString& sessionId);
    
    // Set active terminal
    void setActiveTerminal(const QString& windowId);
    
    // Get active terminal
    TerminalWindow* getActiveTerminal() const;
    
    // Resize terminal
    bool resizeTerminal(const QString& windowId, int cols, int rows);
    
    // Write to terminal
    bool writeToTerminal(const QString& windowId, const QByteArray& data);
    
    // Read from terminal
    QByteArray readFromTerminal(const QString& windowId);
    
    // Get terminal count
    int getTerminalCount(const QString& sessionId) const;
    
    // Get all terminal IDs
    QStringList getAllTerminalIds() const;

signals:
    void terminalCreated(const QString& windowId, const QString& sessionId);
    void terminalClosed(const QString& windowId);
    void terminalResized(const QString& windowId, int cols, int rows);
    void terminalDataReceived(const QString& windowId, const QByteArray& data);
    void activeTerminalChanged(const QString& windowId);
    void terminalTitleChanged(const QString& windowId, const QString& title);
    void terminalError(const QString& windowId, const QString& error);

private:
    QString generateWindowId();
    bool openChannel(TerminalWindow* window);

    QMap<QString, TerminalWindow*> m_terminals;
    QString m_activeTerminalId;
    int m_windowCounter = 0;
};

#endif // MULTI_TERMINAL_MANAGER_H
