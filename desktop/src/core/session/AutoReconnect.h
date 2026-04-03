#ifndef AUTO_RECONNECT_H
#define AUTO_RECONNECT_H

#include <QObject>
#include <QString>
#include <QTimer>
#include <QDateTime>
#include <functional>

/**
 * Auto-reconnect configuration
 */
struct ReconnectConfig {
    bool enabled = true;
    int maxAttempts = 5;
    int initialDelay = 1000;      // milliseconds
    int maxDelay = 32000;         // milliseconds
    double backoffMultiplier = 2.0;
    bool preserveState = true;
    bool restorePortForwarding = true;
    bool restoreTerminal = true;
    bool notifyOnReconnect = true;
};

/**
 * Reconnect state
 */
enum class ReconnectState {
    Idle,
    Waiting,
    Reconnecting,
    Restoring,
    Complete,
    Failed
};

/**
 * Auto-Reconnect Manager
 * Handles automatic reconnection with exponential backoff and state preservation
 */
class AutoReconnectManager : public QObject
{
    Q_OBJECT

public:
    explicit AutoReconnectManager(QObject *parent = nullptr);
    ~AutoReconnectManager();

    // Configure auto-reconnect
    void setConfig(const ReconnectConfig& config);
    ReconnectConfig getConfig() const { return m_config; }
    
    // Start monitoring for reconnection
    void startMonitoring(const QString& sessionId);
    
    // Stop monitoring
    void stopMonitoring(const QString& sessionId);
    
    // Trigger reconnection
    void triggerReconnect(const QString& sessionId);
    
    // Cancel reconnection
    void cancelReconnect(const QString& sessionId);
    
    // Get reconnect state
    ReconnectState getState(const QString& sessionId) const;
    
    // Get attempt count
    int getAttemptCount(const QString& sessionId) const;
    
    // Get next retry time
    QDateTime getNextRetryTime(const QString& sessionId) const;
    
    // Check if session is reconnecting
    bool isReconnecting(const QString& sessionId) const;
    
    // Reset reconnect state
    void resetState(const QString& sessionId);

signals:
    void reconnectStarted(const QString& sessionId, int attempt);
    void reconnectAttempt(const QString& sessionId, int attempt, int maxAttempts);
    void reconnectSuccess(const QString& sessionId, int attempts);
    void reconnectFailed(const QString& sessionId, int attempts);
    void reconnectCancelled(const QString& sessionId);
    void stateRestored(const QString& sessionId);
    void nextRetryIn(const QString& sessionId, int seconds);

private slots:
    void onReconnectTimer();

private:
    int calculateDelay(int attempt);
    void saveSessionState(const QString& sessionId);
    bool restoreSessionState(const QString& sessionId);
    void restorePortForwarding(const QString& sessionId);
    void restoreTerminalState(const QString& sessionId);

    ReconnectConfig m_config;
    
    struct SessionReconnectState {
        QString sessionId;
        ReconnectState state = ReconnectState::Idle;
        int attemptCount = 0;
        int currentDelay = 0;
        QDateTime nextRetryTime;
        QTimer* timer = nullptr;
        bool cancelled = false;
        
        // Saved state for restoration
        struct SavedState {
            QMap<QString, QVariant> terminalState;
            QList<QVariant> portForwardingRules;
            QString currentDirectory;
            QMap<QString, QString> environment;
        } savedState;
    };
    
    QMap<QString, SessionReconnectState> m_sessionStates;
};

#endif // AUTO_RECONNECT_H
