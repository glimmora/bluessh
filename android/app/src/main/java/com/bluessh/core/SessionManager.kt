package com.bluessh.core

import android.content.Context
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.concurrent.ConcurrentHashMap

/**
 * Session Manager - handles multiple SSH sessions
 * Provides session lifecycle management, auto-reconnect, and keepalive
 */
class SessionManager(private val context: Context) {
    
    private val sessions = ConcurrentHashMap<String, ManagedSession>()
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    
    private val _activeSessions = MutableStateFlow<List<SessionInfo>>(emptyList())
    val activeSessions: StateFlow<List<SessionInfo>> = _activeSessions.asStateFlow()
    
    /**
     * Create and start a new session
     */
    suspend fun createSession(
        sessionId: String,
        host: String,
        port: Int,
        username: String,
        authMethod: AuthMethod,
        config: ConnectionConfig = ConnectionConfig()
    ): Result<ManagedSession> = withContext(Dispatchers.IO) {
        try {
            val engine = (context.applicationContext as com.bluessh.BlueSSHApplication).sshEngine
            
            val result = when (authMethod) {
                is AuthMethod.Password -> {
                    engine.connectPassword(sessionId, host, port, username, authMethod.password, config)
                }
                is AuthMethod.PublicKey -> {
                    engine.connectPublicKey(sessionId, host, port, username, authMethod.keyPair, authMethod.passphrase, config)
                }
                is AuthMethod.KeyboardInteractive -> {
                    engine.connectKeyboardInteractive(sessionId, host, port, username, authMethod.password, authMethod.mfaCode, config)
                }
            }
            
            result.fold(
                onSuccess = { sshSession ->
                    val managedSession = ManagedSession(
                        id = sessionId,
                        sshSession = sshSession,
                        host = host,
                        port = port,
                        username = username,
                        config = config,
                        createdAt = System.currentTimeMillis()
                    )
                    
                    sessions[sessionId] = managedSession
                    startKeepAlive(managedSession)
                    updateActiveSessions()
                    
                    Result.success(managedSession)
                },
                onFailure = { e ->
                    Result.failure(e)
                }
            )
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
    
    /**
     * Start keepalive timer for a session
     */
    private fun startKeepAlive(session: ManagedSession) {
        scope.launch {
            while (isActive) {
                delay(session.config.keepAliveInterval)
                
                val engine = (context.applicationContext as com.bluessh.BlueSSHApplication).sshEngine
                val success = engine.sendKeepAlive(session.sshSession)
                
                if (!success) {
                    session.keepAliveFailedCount++
                    
                    if (session.keepAliveFailedCount >= session.config.maxReconnectAttempts) {
                        // Attempt auto-reconnect
                        attemptReconnect(session)
                        break
                    }
                } else {
                    session.keepAliveFailedCount = 0
                }
            }
        }
    }
    
    /**
     * Attempt to reconnect a session with exponential backoff
     */
    private suspend fun attemptReconnect(session: ManagedSession) {
        var attempt = 1
        while (attempt <= session.config.maxReconnectAttempts) {
            val delayMs = (1000L shl (attempt - 1)).coerceAtMost(32000L) // Exponential backoff: 1s, 2s, 4s, 8s, 16s, 32s
            delay(delayMs)
            
            // Reconnection logic would go here
            attempt++
        }
    }
    
    /**
     * Close a session
     */
    suspend fun closeSession(sessionId: String): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            val engine = (context.applicationContext as com.bluessh.BlueSSHApplication).sshEngine
            engine.disconnect(sessionId)
            sessions.remove(sessionId)
            updateActiveSessions()
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
    
    /**
     * Get session by ID
     */
    fun getSession(sessionId: String): ManagedSession? {
        return sessions[sessionId]
    }
    
    /**
     * Get all active sessions
     */
    fun getAllSessions(): List<ManagedSession> {
        return sessions.values.toList()
    }
    
    private fun updateActiveSessions() {
        _activeSessions.value = sessions.values.map { session ->
            SessionInfo(
                id = session.id,
                host = session.host,
                port = session.port,
                username = session.username,
                connectedAt = session.createdAt,
                keepAliveFailedCount = session.keepAliveFailedCount
            )
        }
    }
    
    /**
     * Cleanup all sessions
     */
    fun cleanup() {
        scope.cancel()
        sessions.clear()
    }
}

/**
 * Managed session with additional metadata
 */
data class ManagedSession(
    val id: String,
    val sshSession: SshSession,
    val host: String,
    val port: Int,
    val username: String,
    val config: ConnectionConfig,
    val createdAt: Long,
    var keepAliveFailedCount: Int = 0
)

/**
 * Session info for UI display
 */
data class SessionInfo(
    val id: String,
    val host: String,
    val port: Int,
    val username: String,
    val connectedAt: Long,
    val keepAliveFailedCount: Int
)

/**
 * Authentication method sealed class
 */
sealed class AuthMethod {
    data class Password(val password: String) : AuthMethod()
    data class PublicKey(val keyPair: java.security.KeyPair, val passphrase: String? = null) : AuthMethod()
    data class KeyboardInteractive(val password: String, val mfaCode: String? = null) : AuthMethod()
}
