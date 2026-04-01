package com.bluessh.bluessh

import android.content.Context
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

        init {
            System.loadLibrary("bluessh")
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
        recordSession: Boolean
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
        try {
            when (call.method) {
                "init" -> result.success(nativeInit())
                "shutdown" -> result.success(nativeShutdown())
                "connect" -> {
                    val sessionId = nativeConnect(
                        call.argument<String>("host") ?: "",
                        call.argument<Int>("port") ?: 22,
                        call.argument<Int>("protocol") ?: 0,
                        call.argument<Int>("compressLevel") ?: 2,
                        call.argument<Boolean>("recordSession") ?: false
                    )
                    result.success(sessionId)
                }
                "disconnect" -> result.success(
                    nativeDisconnect(call.argument<Int>("sessionId")?.toLong() ?: 0L)
                )
                "write" -> {
                    val data = call.argument<ByteArray>("data") ?: byteArrayOf()
                    result.success(
                        nativeWrite(call.argument<Int>("sessionId")?.toLong() ?: 0L, data)
                    )
                }
                "resize" -> result.success(
                    nativeResize(
                        call.argument<Int>("sessionId")?.toLong() ?: 0L,
                        call.argument<Int>("cols") ?: 80,
                        call.argument<Int>("rows") ?: 24
                    )
                )
                "authPassword" -> result.success(
                    nativeAuthPassword(
                        call.argument<Int>("sessionId")?.toLong() ?: 0L,
                        call.argument<String>("password") ?: ""
                    )
                )
                "authKey" -> result.success(
                    nativeAuthKey(
                        call.argument<Int>("sessionId")?.toLong() ?: 0L,
                        call.argument<String>("keyPath") ?: ""
                    )
                )
                "authKeyData" -> result.success(
                    nativeAuthKeyData(
                        call.argument<Int>("sessionId")?.toLong() ?: 0L,
                        call.argument<ByteArray>("keyData") ?: byteArrayOf(),
                        call.argument<String>("passphrase") ?: ""
                    )
                )
                "authMfa" -> result.success(
                    nativeAuthMfa(
                        call.argument<Int>("sessionId")?.toLong() ?: 0L,
                        call.argument<String>("code") ?: ""
                    )
                )
                "sftpList" -> result.success(
                    nativeSftpList(
                        call.argument<Int>("sessionId")?.toLong() ?: 0L,
                        call.argument<String>("path") ?: "/"
                    )
                )
                "sftpUpload" -> result.success(
                    nativeSftpUpload(
                        call.argument<Int>("sessionId")?.toLong() ?: 0L,
                        call.argument<String>("localPath") ?: "",
                        call.argument<String>("remotePath") ?: ""
                    )
                )
                "sftpDownload" -> result.success(
                    nativeSftpDownload(
                        call.argument<Int>("sessionId")?.toLong() ?: 0L,
                        call.argument<String>("remotePath") ?: "",
                        call.argument<String>("localPath") ?: ""
                    )
                )
                "sftpMkdir" -> result.success(
                    nativeSftpMkdir(
                        call.argument<Int>("sessionId")?.toLong() ?: 0L,
                        call.argument<String>("path") ?: ""
                    )
                )
                "sftpDelete" -> result.success(
                    nativeSftpDelete(
                        call.argument<Int>("sessionId")?.toLong() ?: 0L,
                        call.argument<String>("path") ?: ""
                    )
                )
                "sftpRename" -> result.success(
                    nativeSftpRename(
                        call.argument<Int>("sessionId")?.toLong() ?: 0L,
                        call.argument<String>("oldPath") ?: "",
                        call.argument<String>("newPath") ?: ""
                    )
                )
                "clipboardSet" -> result.success(
                    nativeClipboardSet(
                        call.argument<Int>("sessionId")?.toLong() ?: 0L,
                        call.argument<ByteArray>("data") ?: byteArrayOf()
                    )
                )
                "clipboardGet" -> result.success(nativeClipboardGet(0L))
                "recordingStart" -> result.success(
                    nativeRecordingStart(
                        call.argument<Int>("sessionId")?.toLong() ?: 0L,
                        call.argument<String>("path") ?: ""
                    )
                )
                "recordingStop" -> result.success(
                    nativeRecordingStop(
                        call.argument<Int>("sessionId")?.toLong() ?: 0L
                    )
                )
                "setCompression" -> result.success(
                    nativeSetCompression(
                        call.argument<Int>("sessionId")?.toLong() ?: 0L,
                        call.argument<Int>("level") ?: 2
                    )
                )
                "getSessionState" -> result.success(
                    nativeGetSessionState(
                        call.argument<Int>("sessionId")?.toLong() ?: 0L
                    )
                )
                "getVersion" -> result.success(nativeGetVersion())
                "getAppDir" -> result.success(context.filesDir.absolutePath)
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("NATIVE_ERROR", e.message, null)
        }
    }
}
