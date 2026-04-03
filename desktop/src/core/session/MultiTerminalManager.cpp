#include "session/MultiTerminalManager.h"
#include "terminal/TerminalEmulator.h"
#include <QDebug>
#include <QUuid>

MultiTerminalManager::MultiTerminalManager(QObject *parent)
    : QObject(parent)
{
}

MultiTerminalManager::~MultiTerminalManager()
{
    for (auto it = m_terminals.begin(); it != m_terminals.end(); ++it) {
        delete it.value();
    }
    m_terminals.clear();
}

QString MultiTerminalManager::createTerminalWindow(const QString& sessionId, const QString& terminalType)
{
    QString windowId = generateWindowId();
    
    TerminalWindow* window = new TerminalWindow();
    window->id = windowId;
    window->sessionId = sessionId;
    window->emulator = std::make_shared<TerminalEmulator>(
        TerminalType::XTerm, 80, 24
    );
    window->createdAt = QDateTime::currentDateTime();
    window->isActive = (m_terminals.isEmpty());
    
    // Open channel (would be implemented with actual SSH channel creation)
    if (!openChannel(window)) {
        delete window;
        emit terminalError(windowId, "Failed to open channel");
        return QString();
    }
    
    m_terminals[windowId] = window;
    
    // Connect signals
    connect(window->emulator.get(), &TerminalEmulator::sendData,
            this, [this, windowId](const QByteArray& data) {
        emit terminalDataReceived(windowId, data);
    });
    
    connect(window->emulator.get(), &TerminalEmulator::titleChanged,
            this, [this, windowId](const QString& title) {
        if (m_terminals.contains(windowId)) {
            m_terminals[windowId]->title = title;
            emit terminalTitleChanged(windowId, title);
        }
    });
    
    emit terminalCreated(windowId, sessionId);
    return windowId;
}

bool MultiTerminalManager::closeTerminalWindow(const QString& windowId)
{
    auto it = m_terminals.find(windowId);
    if (it != m_terminals.end()) {
        // Close channel
        if (it.value()->channel) {
            // libssh2_channel_free(it.value()->channel);
            it.value()->channel = nullptr;
        }
        
        if (m_activeTerminalId == windowId) {
            m_activeTerminalId = QString();
        }
        
        delete it.value();
        m_terminals.erase(it);
        
        emit terminalClosed(windowId);
        return true;
    }
    return false;
}

void MultiTerminalManager::closeAllTerminals(const QString& sessionId)
{
    QList<QString> toRemove;
    for (auto it = m_terminals.begin(); it != m_terminals.end(); ++it) {
        if (it.value()->sessionId == sessionId) {
            toRemove.append(it.key());
        }
    }
    
    for (const QString& windowId : toRemove) {
        closeTerminalWindow(windowId);
    }
}

TerminalWindow* MultiTerminalManager::getTerminalWindow(const QString& windowId)
{
    return m_terminals.value(windowId);
}

QList<TerminalWindow*> MultiTerminalManager::getSessionTerminals(const QString& sessionId)
{
    QList<TerminalWindow*> terminals;
    for (auto it = m_terminals.begin(); it != m_terminals.end(); ++it) {
        if (it.value()->sessionId == sessionId) {
            terminals.append(it.value());
        }
    }
    return terminals;
}

void MultiTerminalManager::setActiveTerminal(const QString& windowId)
{
    if (m_terminals.contains(windowId)) {
        // Deactivate current active
        if (!m_activeTerminalId.isEmpty() && m_terminals.contains(m_activeTerminalId)) {
            m_terminals[m_activeTerminalId]->isActive = false;
        }
        
        m_activeTerminalId = windowId;
        m_terminals[windowId]->isActive = true;
        
        emit activeTerminalChanged(windowId);
    }
}

TerminalWindow* MultiTerminalManager::getActiveTerminal() const
{
    if (!m_activeTerminalId.isEmpty() && m_terminals.contains(m_activeTerminalId)) {
        return m_terminals[m_activeTerminalId];
    }
    return nullptr;
}

bool MultiTerminalManager::resizeTerminal(const QString& windowId, int cols, int rows)
{
    auto it = m_terminals.find(windowId);
    if (it != m_terminals.end()) {
        it.value()->emulator->resize(cols, rows);
        it.value()->columns = cols;
        it.value()->rows = rows;
        
        // Send resize to SSH channel
        if (it.value()->channel) {
            // libssh2_channel_request_pty_size(it.value()->channel, cols, rows);
        }
        
        emit terminalResized(windowId, cols, rows);
        return true;
    }
    return false;
}

bool MultiTerminalManager::writeToTerminal(const QString& windowId, const QByteArray& data)
{
    auto it = m_terminals.find(windowId);
    if (it != m_terminals.end()) {
        // Write to SSH channel
        if (it.value()->channel) {
            // libssh2_channel_write(it.value()->channel, data.constData(), data.size());
        }
        return true;
    }
    return false;
}

QByteArray MultiTerminalManager::readFromTerminal(const QString& windowId)
{
    auto it = m_terminals.find(windowId);
    if (it != m_terminals.end()) {
        // Read from SSH channel
        if (it.value()->channel) {
            char buffer[4096];
            int bytesRead = 0; // libssh2_channel_read(it.value()->channel, buffer, sizeof(buffer));
            if (bytesRead > 0) {
                return QByteArray(buffer, bytesRead);
            }
        }
    }
    return QByteArray();
}

int MultiTerminalManager::getTerminalCount(const QString& sessionId) const
{
    int count = 0;
    for (auto it = m_terminals.begin(); it != m_terminals.end(); ++it) {
        if (it.value()->sessionId == sessionId) {
            count++;
        }
    }
    return count;
}

QStringList MultiTerminalManager::getAllTerminalIds() const
{
    return m_terminals.keys();
}

QString MultiTerminalManager::generateWindowId()
{
    return QString("term_%1").arg(++m_windowCounter);
}

bool MultiTerminalManager::openChannel(TerminalWindow* window)
{
    // This would create an actual SSH channel
    // For now, just mark as successful
    window->channel = reinterpret_cast<LIBSSH2_CHANNEL*>(0x1);  // Placeholder
    return true;
}
