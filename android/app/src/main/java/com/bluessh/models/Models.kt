package com.bluessh.models

import kotlinx.serialization.Serializable

/**
 * Host Profile - saved connection configuration
 */
@Serializable
data class HostProfile(
    val id: String = java.util.UUID.randomUUID().toString(),
    val name: String,
    val host: String,
    val port: Int = 22,
    val protocol: String = "SSH", // SSH, SFTP, SCP
    val username: String,
    val authMethod: AuthMethodType = AuthMethodType.PASSWORD,
    val keyAlias: String? = null,
    val passphraseAlias: String? = null,
    val compressionLevel: Int = 0, // 0=none, 1=low, 2=medium, 3=high
    val mfaSecret: String? = null,
    val tags: List<String> = emptyList(),
    val environmentVariables: Map<String, String> = emptyMap(),
    val workingDirectory: String? = null,
    val jumpHostId: String? = null,
    val portForwardingRules: List<PortForwardingRule> = emptyList(),
    val enableAgentForwarding: Boolean = false,
    val enableX11Forwarding: Boolean = false,
    val enableRecording: Boolean = false,
    val keepAliveInterval: Int = 30,
    val maxReconnectAttempts: Int = 5,
    val connectionTimeout: Int = 30000,
    val lastUsed: Long? = null,
    val connectionCount: Int = 0,
    val createdAt: Long = System.currentTimeMillis(),
    val updatedAt: Long = System.currentTimeMillis()
)

/**
 * Authentication method types
 */
enum class AuthMethodType {
    PASSWORD,
    PUBLIC_KEY,
    KEYBOARD_INTERACTIVE,
    GSSAPI
}

/**
 * Port forwarding rule
 */
@Serializable
data class PortForwardingRule(
    val id: String = java.util.UUID.randomUUID().toString(),
    val type: ForwardingType,
    val localHost: String = "127.0.0.1",
    val localPort: Int,
    val remoteHost: String = "127.0.0.1",
    val remotePort: Int,
    val enabled: Boolean = true,
    val description: String = ""
)

/**
 * Forwarding types
 */
enum class ForwardingType {
    LOCAL,      // Local port forwarding
    REMOTE,     // Remote port forwarding
    DYNAMIC     // Dynamic (SOCKS5) forwarding
}

/**
 * Session state
 */
enum class SessionState {
    DISCONNECTED,
    CONNECTING,
    CONNECTED,
    AUTHENTICATING,
    ERROR,
    RECONNECTING
}

/**
 * Terminal settings
 */
@Serializable
data class TerminalSettings(
    val fontSize: Int = 14,
    val ptyType: String = "xterm-256color",
    val scrollbackSize: Int = 10000,
    val enableTimestamps: Boolean = false,
    val enableBell: Boolean = true,
    val theme: TerminalTheme = TerminalTheme.CATPPUCCIN,
    val backgroundOpacity: Float = 0.95f,
    val cursorStyle: CursorStyle = CursorStyle.BLOCK,
    val cursorBlink: Boolean = true
)

/**
 * Terminal themes
 */
enum class TerminalTheme {
    CATPPUCCIN,
    DRACULA,
    MONOKAI,
    SOLARIZED_DARK,
    SOLARIZED_LIGHT,
    NORD,
    GRUVBOX,
    ONE_DARK,
    SYSTEM_DEFAULT
}

/**
 * Cursor styles
 */
enum class CursorStyle {
    BLOCK,
    UNDERLINE,
    BAR
}

/**
 * Application settings
 */
@Serializable
data class AppSettings(
    val theme: AppTheme = AppTheme.DARK,
    val defaultCompressionLevel: Int = 0,
    val defaultKeepAliveInterval: Int = 30,
    val defaultMaxReconnectAttempts: Int = 5,
    val defaultConnectionTimeout: Int = 30000,
    val recordByDefault: Boolean = false,
    val clipboardSync: Boolean = true,
    val autoSaveSessions: Boolean = true,
    val showConnectionStatus: Boolean = true,
    val terminalSettings: TerminalSettings = TerminalSettings()
)

/**
 * Application theme
 */
enum class AppTheme {
    LIGHT,
    DARK,
    AUTO
}

/**
 * Recording format
 */
enum class RecordingFormat {
    ASCIINEMA,  // .cast format
    VNC_REC,    // VNC recording
    RDP_REC     // RDP recording
}

/**
 * Session recording metadata
 */
@Serializable
data class RecordingMetadata(
    val sessionId: String,
    val host: String,
    val startTime: Long,
    val endTime: Long? = null,
    val format: RecordingFormat = RecordingFormat.ASCIINEMA,
    val filePath: String,
    val width: Int = 80,
    val height: Int = 24,
    val environment: Map<String, String> = emptyMap()
)
