#include "session/AutoReconnect.h"
#include <QDebug>
#include <QTimer>
#include <cmath>

AutoReconnectManager::AutoReconnectManager(QObject *parent)
    : QObject(parent)
{
}

AutoReconnectManager::~AutoReconnectManager()
{
    for (auto it = m_sessionStates.begin(); it != m_sessionStates.end(); ++it) {
        if (it->timer) {
            it->timer->stop();
            delete it->timer;
        }
    }
    m_sessionStates.clear();
}

void AutoReconnectManager::setConfig(const ReconnectConfig& config)
{
    m_config = config;
}

void AutoReconnectManager::startMonitoring(const QString& sessionId)
{
    if (!m_sessionStates.contains(sessionId)) {
        SessionReconnectState state;
        state.sessionId = sessionId;
        state.timer = new QTimer(this);
        state.timer->setProperty("sessionId", sessionId);
        connect(state.timer, &QTimer::timeout, this, &AutoReconnectManager::onReconnectTimer);
        m_sessionStates[sessionId] = state;
    }
}

void AutoReconnectManager::stopMonitoring(const QString& sessionId)
{
    auto it = m_sessionStates.find(sessionId);
    if (it != m_sessionStates.end()) {
        if (it->timer) {
            it->timer->stop();
        }
        m_sessionStates.erase(it);
    }
}

void AutoReconnectManager::triggerReconnect(const QString& sessionId)
{
    if (!m_sessionStates.contains(sessionId)) {
        startMonitoring(sessionId);
    }
    
    auto& state = m_sessionStates[sessionId];
    state.state = ReconnectState::Waiting;
    state.attemptCount = 0;
    state.cancelled = false;
    
    // Save current state for restoration
    if (m_config.preserveState) {
        saveSessionState(sessionId);
    }
    
    // Start first reconnect attempt
    state.currentDelay = m_config.initialDelay;
    state.nextRetryTime = QDateTime::currentDateTime().addMSecs(state.currentDelay);
    
    if (state.timer) {
        state.timer->start(state.currentDelay);
    }
    
    emit reconnectStarted(sessionId, 1);
    emit nextRetryIn(sessionId, state.currentDelay / 1000);
}

void AutoReconnectManager::cancelReconnect(const QString& sessionId)
{
    auto it = m_sessionStates.find(sessionId);
    if (it != m_sessionStates.end()) {
        it->cancelled = true;
        if (it->timer) {
            it->timer->stop();
        }
        it->state = ReconnectState::Idle;
        emit reconnectCancelled(sessionId);
    }
}

ReconnectState AutoReconnectManager::getState(const QString& sessionId) const
{
    auto it = m_sessionStates.find(sessionId);
    if (it != m_sessionStates.end()) {
        return it->state;
    }
    return ReconnectState::Idle;
}

int AutoReconnectManager::getAttemptCount(const QString& sessionId) const
{
    auto it = m_sessionStates.find(sessionId);
    if (it != m_sessionStates.end()) {
        return it->attemptCount;
    }
    return 0;
}

QDateTime AutoReconnectManager::getNextRetryTime(const QString& sessionId) const
{
    auto it = m_sessionStates.find(sessionId);
    if (it != m_sessionStates.end()) {
        return it->nextRetryTime;
    }
    return QDateTime();
}

bool AutoReconnectManager::isReconnecting(const QString& sessionId) const
{
    auto it = m_sessionStates.find(sessionId);
    if (it != m_sessionStates.end()) {
        return it->state == ReconnectState::Waiting || 
               it->state == ReconnectState::Reconnecting;
    }
    return false;
}

void AutoReconnectManager::resetState(const QString& sessionId)
{
    auto it = m_sessionStates.find(sessionId);
    if (it != m_sessionStates.end()) {
        if (it->timer) {
            it->timer->stop();
        }
        it->state = ReconnectState::Idle;
        it->attemptCount = 0;
        it->cancelled = false;
    }
}

int AutoReconnectManager::calculateDelay(int attempt)
{
    int delay = m_config.initialDelay * std::pow(m_config.backoffMultiplier, attempt - 1);
    return qMin(delay, m_config.maxDelay);
}

void AutoReconnectManager::saveSessionState(const QString& sessionId)
{
    auto& state = m_sessionStates[sessionId];
    // Save terminal state, port forwarding rules, etc.
    // This would be implemented to actually save the state
    qDebug() << "Saving session state for:" << sessionId;
}

bool AutoReconnectManager::restoreSessionState(const QString& sessionId)
{
    auto& state = m_sessionStates[sessionId];
    
    // Restore port forwarding if configured
    if (m_config.restorePortForwarding) {
        restorePortForwarding(sessionId);
    }
    
    // Restore terminal state if configured
    if (m_config.restoreTerminal) {
        restoreTerminalState(sessionId);
    }
    
    emit stateRestored(sessionId);
    return true;
}

void AutoReconnectManager::restorePortForwarding(const QString& sessionId)
{
    // Restore port forwarding rules
    qDebug() << "Restoring port forwarding for session:" << sessionId;
}

void AutoReconnectManager::restoreTerminalState(const QString& sessionId)
{
    // Restore terminal state (current directory, environment, etc.)
    qDebug() << "Restoring terminal state for session:" << sessionId;
}

void AutoReconnectManager::onReconnectTimer()
{
    QString sessionId = sender()->property("sessionId").toString();
    auto it = m_sessionStates.find(sessionId);
    
    if (it == m_sessionStates.end()) {
        return;
    }
    
    auto& state = *it;
    
    if (state.cancelled) {
        return;
    }
    
    state.attemptCount++;
    state.state = ReconnectState::Reconnecting;
    
    emit reconnectAttempt(sessionId, state.attemptCount, m_config.maxAttempts);
    
    // Attempt reconnection (this would call the actual reconnect logic)
    bool success = false;  // Would be actual reconnection attempt
    
    if (success) {
        state.state = ReconnectState::Restoring;
        
        // Restore state
        if (m_config.preserveState) {
            restoreSessionState(sessionId);
        }
        
        state.state = ReconnectState::Complete;
        emit reconnectSuccess(sessionId, state.attemptCount);
        
        if (state.timer) {
            state.timer->stop();
        }
    } else {
        if (state.attemptCount >= m_config.maxAttempts) {
            state.state = ReconnectState::Failed;
            emit reconnectFailed(sessionId, state.attemptCount);
            
            if (state.timer) {
                state.timer->stop();
            }
        } else {
            // Schedule next attempt with exponential backoff
            state.currentDelay = calculateDelay(state.attemptCount + 1);
            state.nextRetryTime = QDateTime::currentDateTime().addMSecs(state.currentDelay);
            
            if (state.timer) {
                state.timer->start(state.currentDelay);
            }
            
            emit nextRetryIn(sessionId, state.currentDelay / 1000);
        }
    }
}
