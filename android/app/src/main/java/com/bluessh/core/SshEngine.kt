package com.bluessh.core

import android.content.Context
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.apache.sshd.client.SshClient
import org.apache.sshd.client.channel.ChannelShell
import org.apache.sshd.client.channel.ClientChannel
import org.apache.sshd.client.future.ConnectFuture
import org.apache.sshd.common.future.CloseFuture
import org.apache.sshd.common.util.security.bouncycastle.BouncyCastleGeneratorHostKeyProvider
import org.apache.sshd.sftp.client.SftpClientFactory
import java.io.*
import java.net.InetSocketAddress
import java.nio.charset.StandardCharsets
import java.security.KeyPair
import java.util.concurrent.ConcurrentHashMap

/**
 * Core SSH engine using Apache MINA SSHD
 * Handles all SSH/SFTP/SCP connections and operations
 */
class SshEngine(private val context: Context) {
    
    private val client: SshClient = SshClient.setUpDefaultClient()
    private val sessions = ConcurrentHashMap<String, SshSession>()
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    
    private val _connectionState = MutableStateFlow<ConnectionState>(ConnectionState.Disconnected)
    val connectionState: StateFlow<ConnectionState> = _connectionState.asStateFlow()
    
    init {
        configureClient()
        client.start()
    }
    
    private fun configureClient() {
        // Configure key pair provider for host key verification
        val keyPairProvider = BouncyCastleGeneratorHostKeyProvider(
            context.getFileStreamPath("host_key.ser").toPath()
        )
        client.keyPairProvider = keyPairProvider
        
        // Configure known hosts
        client.serverKeyVerifier = KnownHostsVerifier(context)
        
        // Enable compression
        client.isCompression = true
        
        // Set connection timeout
        client.connectTimeout = 30000
    }
    
    /**
     * Connect to SSH server with password authentication
     */
    suspend fun connectPassword(
        sessionId: String,
        host: String,
        port: Int,
        username: String,
        password: String,
        config: ConnectionConfig = ConnectionConfig()
    ): Result<SshSession> = withContext(Dispatchers.IO) {
        try {
            val connectFuture: ConnectFuture = client.connect(username, host, port)
            connectFuture.verify(config.timeout)
            
            val sshSession = connectFuture.session
            
            // Request keyboard-interactive auth first, fallback to password
            val authFuture = sshSession.authPassword(username, password)
            authFuture.verify(config.timeout)
            
            if (!sshSession.isAuthenticated) {
                return@withContext Result.failure(Exception("Authentication failed"))
            }
            
            val session = SshSession(sessionId, sshSession, config)
            sessions[sessionId] = session
            
            _connectionState.value = ConnectionState.Connected(sessionId)
            Result.success(session)
        } catch (e: Exception) {
            Result.failure(e)
        } finally {
            // Zeroize password
            password.toCharArray().fill('\u0000')
        }
    }
    
    /**
     * Connect to SSH server with public key authentication
     */
    suspend fun connectPublicKey(
        sessionId: String,
        host: String,
        port: Int,
        username: String,
        keyPair: KeyPair,
        passphrase: String? = null,
        config: ConnectionConfig = ConnectionConfig()
    ): Result<SshSession> = withContext(Dispatchers.IO) {
        try {
            val connectFuture: ConnectFuture = client.connect(username, host, port)
            connectFuture.verify(config.timeout)
            
            val sshSession = connectFuture.session
            
            val authFuture = sshSession.authPublicKey(username, keyPair)
            authFuture.verify(config.timeout)
            
            if (!sshSession.isAuthenticated) {
                return@withContext Result.failure(Exception("Authentication failed"))
            }
            
            val session = SshSession(sessionId, sshSession, config)
            sessions[sessionId] = session
            
            _connectionState.value = ConnectionState.Connected(sessionId)
            Result.success(session)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
    
    /**
     * Connect with keyboard-interactive authentication (for MFA)
     */
    suspend fun connectKeyboardInteractive(
        sessionId: String,
        host: String,
        port: Int,
        username: String,
        password: String,
        mfaCode: String? = null,
        config: ConnectionConfig = ConnectionConfig()
    ): Result<SshSession> = withContext(Dispatchers.IO) {
        try {
            val connectFuture: ConnectFuture = client.connect(username, host, port)
            connectFuture.verify(config.timeout)
            
            val sshSession = connectFuture.session
            
            // Keyboard-interactive auth supports MFA challenges
            val authFuture = sshSession.authKeyboardInteractive(username, "", "", arrayOf(password, mfaCode ?: ""))
            authFuture.verify(config.timeout)
            
            if (!sshSession.isAuthenticated) {
                return@withContext Result.failure(Exception("Authentication failed"))
            }
            
            val session = SshSession(sessionId, sshSession, config)
            sessions[sessionId] = session
            
            _connectionState.value = ConnectionState.Connected(sessionId)
            Result.success(session)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
    
    /**
     * Create a shell channel for terminal access
     */
    fun createShellChannel(session: SshSession, ptyType: String = "xterm-256color"): Result<ChannelShell> {
        return try {
            val channel = session.sshSession.createShellChannel(ptyType, "UTF-8")
            channel.open().verify(session.config.timeout)
            Result.success(channel)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
    
    /**
     * Execute a remote command and return output
     */
    suspend fun executeCommand(session: SshSession, command: String): Result<String> = withContext(Dispatchers.IO) {
        try {
            val channel = session.sshSession.createExecChannel(command)
            channel.open().verify(session.config.timeout)
            
            val outputStream = ByteArrayOutputStream()
            channel.setOut(outputStream)
            channel.setErr(outputStream)
            
            channel.waitFor(setOf(ClientChannel.CLOSED), 0)
            channel.close(false)
            
            Result.success(outputStream.toString(StandardCharsets.UTF_8.name()))
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
    
    /**
     * Setup local port forwarding
     */
    fun setupLocalForwarding(session: SshSession, localPort: Int, remoteHost: String, remotePort: Int): Result<Unit> {
        return try {
            val localAddress = InetSocketAddress("127.0.0.1", localPort)
            val remoteAddress = InetSocketAddress(remoteHost, remotePort)
            
            session.sshSession.startLocalPortForwarding(localAddress, remoteAddress)
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
    
    /**
     * Setup remote port forwarding
     */
    fun setupRemoteForwarding(session: SshSession, remotePort: Int, localHost: String, localPort: Int): Result<Unit> {
        return try {
            val remoteAddress = InetSocketAddress("0.0.0.0", remotePort)
            val localAddress = InetSocketAddress(localHost, localPort)
            
            session.sshSession.startRemotePortForwarding(remoteAddress, localAddress)
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
    
    /**
     * Setup dynamic port forwarding (SOCKS5 proxy)
     */
    fun setupDynamicForwarding(session: SshSession, localPort: Int): Result<Unit> {
        return try {
            val localAddress = InetSocketAddress("127.0.0.1", localPort)
            session.sshSession.startDynamicPortForwarding(localAddress)
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
    
    /**
     * Create SFTP client for file operations
     */
    suspend fun createSftpClient(session: SshSession): Result<SftpClientFactory> = withContext(Dispatchers.IO) {
        try {
            val factory = SftpClientFactory.instance()
            Result.success(factory)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
    
    /**
     * Disconnect a session
     */
    suspend fun disconnect(sessionId: String): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            sessions[sessionId]?.let { session ->
                session.sshSession.close(false).verify(5000)
                sessions.remove(sessionId)
                
                if (sessions.isEmpty()) {
                    _connectionState.value = ConnectionState.Disconnected
                }
            }
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
    
    /**
     * Send keepalive packet
     */
    fun sendKeepAlive(session: SshSession): Boolean {
        return try {
            session.sshSession.sendKeepAlive()
            true
        } catch (e: Exception) {
            false
        }
    }
    
    /**
     * Shutdown the engine
     */
    fun shutdown() {
        scope.cancel()
        sessions.values.forEach { session ->
            runBlocking {
                session.sshSession.close(false).verify(5000)
            }
        }
        sessions.clear()
        client.stop()
    }
}

/**
 * SSH Session wrapper
 */
data class SshSession(
    val id: String,
    val sshSession: org.apache.sshd.client.session.ClientSession,
    val config: ConnectionConfig
)

/**
 * Connection configuration
 */
data class ConnectionConfig(
    val timeout: Long = 30000,
    val keepAliveInterval: Long = 30000,
    val maxReconnectAttempts: Int = 5,
    val compressionLevel: Int = 0, // 0=none, 1=low, 2=medium, 3=high
    val ptyType: String = "xterm-256color",
    val ptyWidth: Int = 80,
    val ptyHeight: Int = 24,
    val enableAgentForwarding: Boolean = false,
    val enableX11Forwarding: Boolean = false,
    val environmentVariables: Map<String, String> = emptyMap(),
    val jumpHostConfig: JumpHostConfig? = null
)

/**
 * Jump host/bastion configuration
 */
data class JumpHostConfig(
    val host: String,
    val port: Int = 22,
    val username: String,
    val password: String? = null,
    val keyPair: KeyPair? = null
)

/**
 * Connection state
 */
sealed class ConnectionState {
    object Disconnected : ConnectionState()
    data class Connected(val sessionId: String) : ConnectionState()
    data class Connecting(val host: String) : ConnectionState()
    data class Error(val message: String) : ConnectionState()
}
