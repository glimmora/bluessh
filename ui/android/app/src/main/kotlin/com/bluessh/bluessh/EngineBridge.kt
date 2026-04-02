package com.bluessh.bluessh

import android.content.Context
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/**
 * Bridge between Flutter UI and the native Rust engine via JNI.
 *
 * Registers a [MethodChannel] named "com.bluessh/engine" that the
 * Flutter [SessionService] invokes. Each method maps directly to a
 * JNI `external fun` declared in this class, which delegates to the
 * Rust engine compiled as libbluessh.so.
 *
 * Usage (in MainActivity):
 * ```
 * EngineBridge.registerWith(flutterEngine, applicationContext)
 * ```
 */
class EngineBridge(private val context: Context) : MethodCallHandler {

    companion object {
        private const val CHANNEL_NAME = "com.bluessh/engine"
        private const val TAG = "EngineBridge"

        /** True if the native library loaded successfully. */
        var isLoaded: Boolean = false
            private set

        init {
            try {
                System.loadLibrary("bluessh")
                isLoaded = true
                Log.i(TAG, "Native library loaded successfully")
            } catch (e: UnsatisfiedLinkError) {
                isLoaded = false
                Log.e(TAG, "Failed to load native library: ${e.message}", e)
            } catch (e: Exception) {
                isLoaded = false
                Log.e(TAG, "Unexpected error loading native library: ${e.message}", e)
            }
        }

        /** Registers this handler on the given Flutter engine's method channel. */
        fun registerWith(flutterEngine: FlutterEngine, context: Context) {
            val channel = MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                CHANNEL_NAME
            )
            channel.setMethodCallHandler(EngineBridge(context))
        }
    }

    // ─── JNI Native Declarations ──────────────────────────────────────
    // Each corresponds to a Java_com_bluessh_bluessh_EngineBridge_native*
    // function exported by the Rust engine.

    /** Initializes the engine tracing and state. Returns 0 on success. */
    private external fun nativeInit(): Int

    /** Shuts down the engine and clears all sessions. Returns 0 on success. */
    private external fun nativeShutdown(): Int

    /**
     * Creates a new session to the given host.
     * @return Non-zero session ID on success, 0 on failure.
     */
    private external fun nativeConnect(
        host: String,
        port: Int,
        protocol: Int,
        compressLevel: Int,
        recordSession: Boolean,
        username: String
    ): Long

    /** Disconnects the session. Returns 0 on success. */
    private external fun nativeDisconnect(sessionId: Long): Int

    /** Writes byte data to the session channel. Returns 0 on success. */
    private external fun nativeWrite(sessionId: Long, data: ByteArray): Int

    /** Resizes the terminal PTY. Returns 0 on success. */
    private external fun nativeResize(sessionId: Long, cols: Int, rows: Int): Int

    /** Authenticates with a password. Returns 0 on success. */
    private external fun nativeAuthPassword(sessionId: Long, password: String): Int

    /** Authenticates with a key file path. Returns 0 on success. */
    private external fun nativeAuthKey(sessionId: Long, keyPath: String): Int

    /** Authenticates with raw key data and passphrase. Returns 0 on success. */
    private external fun nativeAuthKeyData(sessionId: Long, keyData: ByteArray, passphrase: String): Int

    /** Submits an MFA (TOTP) code. Returns 0 on success. */
    private external fun nativeAuthMfa(sessionId: Long, code: String): Int

    /** Lists directory contents via SFTP. Returns JSON string. */
    private external fun nativeSftpList(sessionId: Long, path: String): String

    /** Uploads a local file via SFTP. Returns 0 on success. */
    private external fun nativeSftpUpload(sessionId: Long, localPath: String, remotePath: String): Int

    /** Downloads a remote file via SFTP. Returns 0 on success. */
    private external fun nativeSftpDownload(sessionId: Long, remotePath: String, localPath: String): Int

    /** Creates a remote directory via SFTP. Returns 0 on success. */
    private external fun nativeSftpMkdir(sessionId: Long, path: String): Int

    /** Deletes a remote file via SFTP. Returns 0 on success. */
    private external fun nativeSftpDelete(sessionId: Long, path: String): Int

    /** Renames a remote file via SFTP. Returns 0 on success. */
    private external fun nativeSftpRename(sessionId: Long, oldPath: String, newPath: String): Int

    /** Pushes clipboard data to the remote session. Returns 0 on success. */
    private external fun nativeClipboardSet(sessionId: Long, data: ByteArray): Int

    /** Retrieves the remote session's clipboard content. */
    private external fun nativeClipboardGet(sessionId: Long): ByteArray

    /** Starts session recording to the given file path. Returns 0 on success. */
    private external fun nativeRecordingStart(sessionId: Long, path: String): Int

    /** Stops session recording. Returns 0 on success. */
    private external fun nativeRecordingStop(sessionId: Long): Int

    /** Sets the compression level (0-3) for a session. Returns 0 on success. */
    private external fun nativeSetCompression(sessionId: Long, level: Int): Int

    /** Returns the session state as a JSON string. */
    private external fun nativeGetSessionState(sessionId: Long): String

    /** Returns the engine package version string. */
    private external fun nativeGetVersion(): String

    // ─── MethodChannel Dispatch ───────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: Result) {
        // Guard: if the native library failed to load, reject all calls
        if (!isLoaded) {
            result.error(
                "NATIVE_LIBRARY_MISSING",
                "Native library (libbluessh.so) failed to load. Check ABI compatibility.",
                null
            )
            return
        }

        try {
            when (call.method) {
                "init" -> {
                    val rc = nativeInit()
                    result.success(rc)
                }
                "shutdown" -> {
                    val rc = nativeShutdown()
                    result.success(rc)
                }
                "connect" -> {
                    val host = call.argument<String>("host")
                    if (host.isNullOrBlank()) {
                        result.error("INVALID_INPUT", "Host cannot be empty", null)
                        return
                    }
                    val port = call.argument<Int>("port") ?: 22
                    if (port !in 1..65535) {
                        result.error("INVALID_INPUT", "Port must be 1-65535", null)
                        return
                    }
                    val sessionId = nativeConnect(
                        host,
                        port,
                        call.argument<Int>("protocol") ?: 0,
                        call.argument<Int>("compressLevel") ?: 2,
                        call.argument<Boolean>("recordSession") ?: false,
                        call.argument<String>("username") ?: ""
                    )
                    result.success(sessionId)
                }
                "disconnect" -> {
                    val sid = call.argument<Int>("sessionId")?.toLong() ?: 0L
                    if (sid == 0L) {
                        result.error("INVALID_INPUT", "Session ID required", null)
                        return
                    }
                    result.success(nativeDisconnect(sid))
                }
                "write" -> {
                    val sid = call.argument<Int>("sessionId")?.toLong() ?: 0L
                    val data = call.argument<ByteArray>("data") ?: byteArrayOf()
                    if (sid == 0L || data.isEmpty()) {
                        result.error("INVALID_INPUT", "Session ID and data required", null)
                        return
                    }
                    result.success(nativeWrite(sid, data))
                }
                "resize" -> {
                    val sid = call.argument<Int>("sessionId")?.toLong() ?: 0L
                    val cols = call.argument<Int>("cols") ?: 80
                    val rows = call.argument<Int>("rows") ?: 24
                    if (cols <= 0 || rows <= 0) {
                        result.error("INVALID_INPUT", "Cols and rows must be positive", null)
                        return
                    }
                    result.success(nativeResize(sid, cols, rows))
                }
                "authPassword" -> {
                    val sid = call.argument<Int>("sessionId")?.toLong() ?: 0L
                    val password = call.argument<String>("password")
                    if (sid == 0L || password.isNullOrBlank()) {
                        result.error("INVALID_INPUT", "Session ID and password required", null)
                        return
                    }
                    result.success(nativeAuthPassword(sid, password))
                }
                "authKey" -> {
                    val sid = call.argument<Int>("sessionId")?.toLong() ?: 0L
                    val keyPath = call.argument<String>("keyPath")
                    if (sid == 0L || keyPath.isNullOrBlank()) {
                        result.error("INVALID_INPUT", "Session ID and key path required", null)
                        return
                    }
                    result.success(nativeAuthKey(sid, keyPath))
                }
                "authKeyData" -> {
                    val sid = call.argument<Int>("sessionId")?.toLong() ?: 0L
                    val keyData = call.argument<ByteArray>("keyData") ?: byteArrayOf()
                    if (sid == 0L || keyData.isEmpty()) {
                        result.error("INVALID_INPUT", "Session ID and key data required", null)
                        return
                    }
                    result.success(nativeAuthKeyData(sid, keyData, call.argument<String>("passphrase") ?: ""))
                }
                "authMfa" -> {
                    val sid = call.argument<Int>("sessionId")?.toLong() ?: 0L
                    val code = call.argument<String>("code")
                    if (sid == 0L || code.isNullOrBlank()) {
                        result.error("INVALID_INPUT", "Session ID and MFA code required", null)
                        return
                    }
                    result.success(nativeAuthMfa(sid, code))
                }
                "sftpList" -> {
                    val sid = call.argument<Int>("sessionId")?.toLong() ?: 0L
                    val path = call.argument<String>("path") ?: "/"
                    if (sid == 0L) {
                        result.error("INVALID_INPUT", "Session ID required", null)
                        return
                    }
                    result.success(nativeSftpList(sid, path))
                }
                "sftpUpload" -> {
                    val sid = call.argument<Int>("sessionId")?.toLong() ?: 0L
                    val local = call.argument<String>("localPath")
                    val remote = call.argument<String>("remotePath")
                    if (sid == 0L || local.isNullOrBlank() || remote.isNullOrBlank()) {
                        result.error("INVALID_INPUT", "Session ID, local and remote paths required", null)
                        return
                    }
                    result.success(nativeSftpUpload(sid, local, remote))
                }
                "sftpDownload" -> {
                    val sid = call.argument<Int>("sessionId")?.toLong() ?: 0L
                    val remote = call.argument<String>("remotePath")
                    val local = call.argument<String>("localPath")
                    if (sid == 0L || remote.isNullOrBlank() || local.isNullOrBlank()) {
                        result.error("INVALID_INPUT", "Session ID, remote and local paths required", null)
                        return
                    }
                    result.success(nativeSftpDownload(sid, remote, local))
                }
                "sftpMkdir" -> {
                    val sid = call.argument<Int>("sessionId")?.toLong() ?: 0L
                    val path = call.argument<String>("path")
                    if (sid == 0L || path.isNullOrBlank()) {
                        result.error("INVALID_INPUT", "Session ID and path required", null)
                        return
                    }
                    result.success(nativeSftpMkdir(sid, path))
                }
                "sftpDelete" -> {
                    val sid = call.argument<Int>("sessionId")?.toLong() ?: 0L
                    val path = call.argument<String>("path")
                    if (sid == 0L || path.isNullOrBlank()) {
                        result.error("INVALID_INPUT", "Session ID and path required", null)
                        return
                    }
                    result.success(nativeSftpDelete(sid, path))
                }
                "sftpRename" -> {
                    val sid = call.argument<Int>("sessionId")?.toLong() ?: 0L
                    val oldPath = call.argument<String>("oldPath")
                    val newPath = call.argument<String>("newPath")
                    if (sid == 0L || oldPath.isNullOrBlank() || newPath.isNullOrBlank()) {
                        result.error("INVALID_INPUT", "Session ID, old and new paths required", null)
                        return
                    }
                    result.success(nativeSftpRename(sid, oldPath, newPath))
                }
                "clipboardSet" -> {
                    val sid = call.argument<Int>("sessionId")?.toLong() ?: 0L
                    val data = call.argument<ByteArray>("data") ?: byteArrayOf()
                    result.success(nativeClipboardSet(sid, data))
                }
                "clipboardGet" -> {
                    result.success(nativeClipboardGet(0L))
                }
                "recordingStart" -> {
                    val sid = call.argument<Int>("sessionId")?.toLong() ?: 0L
                    val path = call.argument<String>("path")
                    if (sid == 0L || path.isNullOrBlank()) {
                        result.error("INVALID_INPUT", "Session ID and path required", null)
                        return
                    }
                    result.success(nativeRecordingStart(sid, path))
                }
                "recordingStop" -> {
                    val sid = call.argument<Int>("sessionId")?.toLong() ?: 0L
                    if (sid == 0L) {
                        result.error("INVALID_INPUT", "Session ID required", null)
                        return
                    }
                    result.success(nativeRecordingStop(sid))
                }
                "setCompression" -> {
                    val sid = call.argument<Int>("sessionId")?.toLong() ?: 0L
                    val level = call.argument<Int>("level") ?: 2
                    if (sid == 0L) {
                        result.error("INVALID_INPUT", "Session ID required", null)
                        return
                    }
                    result.success(nativeSetCompression(sid, level))
                }
                "getSessionState" -> {
                    val sid = call.argument<Int>("sessionId")?.toLong() ?: 0L
                    if (sid == 0L) {
                        result.error("INVALID_INPUT", "Session ID required", null)
                        return
                    }
                    result.success(nativeGetSessionState(sid))
                }
                "getVersion" -> result.success(nativeGetVersion())
                "getAppDir" -> result.success(context.filesDir.absolutePath)
                "startForeground" -> {
                    try {
                        SessionForegroundService.start(context)
                        result.success(0)
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to start foreground service: ${e.message}", e)
                        result.error("FOREGROUND_SERVICE_ERROR", e.message, null)
                    }
                }
                "stopForeground" -> {
                    try {
                        SessionForegroundService.stop(context)
                        result.success(0)
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to stop foreground service: ${e.message}", e)
                        result.error("FOREGROUND_SERVICE_ERROR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Unhandled error in method '${call.method}': ${e.message}", e)
            result.error("NATIVE_ERROR", e.message, e.stackTraceToString())
        }
    }
}
