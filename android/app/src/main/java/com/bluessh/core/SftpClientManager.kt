package com.bluessh.core

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.apache.sshd.sftp.client.SftpClient
import org.apache.sshd.sftp.client.SftpClientFactory
import org.apache.sshd.sftp.client.fs.SftpFileSystem
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.nio.file.Paths

/**
 * SFTP Client - handles file transfer operations
 * Provides upload, download, directory listing, and file management
 */
class SftpClientManager(private val context: Context) {
    
    /**
     * Create SFTP file system from an existing SSH session
     */
    suspend fun createSftpFileSystem(session: SshSession): Result<SftpFileSystem> = withContext(Dispatchers.IO) {
        try {
            val factory = SftpClientFactory.instance()
            val sftpClient = factory.createSftpClient(session.sshSession)
            val fileSystem = org.apache.sshd.sftp.client.fs.SftpFileSystem(sftpClient)
            Result.success(fileSystem)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
    
    /**
     * List directory contents
     */
    suspend fun listDirectory(fileSystem: SftpFileSystem, path: String): Result<List<SftpFileEntry>> = withContext(Dispatchers.IO) {
        try {
            val sftpClient = fileSystem.client
            val entries = sftpClient.readDir(path).map { handle ->
                SftpFileEntry(
                    name = handle.filename,
                    path = "$path/${handle.filename}",
                    size = handle.attributes.size ?: 0,
                    isDirectory = handle.attributes.isDirectory,
                    isFile = handle.attributes.isRegularFile,
                    permissions = formatPermissions(handle.attributes),
                    modifiedAt = handle.attributes.mtime ?: 0,
                    owner = handle.attributes.ownerId?.toString() ?: "unknown",
                    group = handle.attributes.groupId?.toString() ?: "unknown"
                )
            }
            Result.success(entries)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
    
    /**
     * Upload a file to remote server
     */
    suspend fun uploadFile(
        fileSystem: SftpFileSystem,
        localFile: File,
        remotePath: String,
        progressListener: ((Long, Long) -> Unit)? = null
    ): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            val sftpClient = fileSystem.client
            val remoteFile = Paths.get(remotePath, localFile.name)
            
            val inputStream = FileInputStream(localFile)
            val outputStream = sftpClient.write(remoteFile.toString())
            
            val bufferSize = 32 * 1024 // 32KB buffer
            val buffer = ByteArray(bufferSize)
            var totalRead = 0L
            var bytesRead: Int
            
            while (inputStream.read(buffer).also { bytesRead = it } != -1) {
                outputStream.write(buffer, 0, bytesRead)
                totalRead += bytesRead
                progressListener?.invoke(totalRead, localFile.length())
            }
            
            outputStream.close()
            inputStream.close()
            
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
    
    /**
     * Download a file from remote server
     */
    suspend fun downloadFile(
        fileSystem: SftpFileSystem,
        remotePath: String,
        localFile: File,
        progressListener: ((Long, Long) -> Unit)? = null
    ): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            val sftpClient = fileSystem.client
            val attributes = sftpClient.stat(remotePath)
            val totalSize = attributes.size ?: 0
            
            val inputStream = sftpClient.read(remotePath)
            val outputStream = FileOutputStream(localFile)
            
            val bufferSize = 32 * 1024 // 32KB buffer
            val buffer = ByteArray(bufferSize)
            var totalRead = 0L
            var bytesRead: Int
            
            while (inputStream.read(buffer).also { bytesRead = it } != -1) {
                outputStream.write(buffer, 0, bytesRead)
                totalRead += bytesRead
                progressListener?.invoke(totalRead, totalSize)
            }
            
            outputStream.close()
            inputStream.close()
            
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
    
    /**
     * Create remote directory
     */
    suspend fun createDirectory(fileSystem: SftpFileSystem, path: String): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            val sftpClient = fileSystem.client
            sftpClient.makeDir(path)
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
    
    /**
     * Delete remote file or directory
     */
    suspend fun delete(fileSystem: SftpFileSystem, path: String): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            val sftpClient = fileSystem.client
            val attributes = sftpClient.stat(path)
            
            if (attributes.isDirectory) {
                // Recursively delete directory contents
                val entries = sftpClient.readDir(path)
                entries.forEach { entry ->
                    if (entry.filename != "." && entry.filename != "..") {
                        delete(fileSystem, "$path/${entry.filename}")
                    }
                }
                sftpClient.rmdir(path)
            } else {
                sftpClient.remove(path)
            }
            
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
    
    /**
     * Rename remote file or directory
     */
    suspend fun rename(fileSystem: SftpFileSystem, oldPath: String, newPath: String): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            val sftpClient = fileSystem.client
            sftpClient.rename(oldPath, newPath)
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
    
    /**
     * Change file permissions
     */
    suspend fun changePermissions(fileSystem: SftpFileSystem, path: String, permissions: Int): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            val sftpClient = fileSystem.client
            val attributes = org.apache.sshd.sftp.SftpModuleProperties.createAttributes()
            attributes.permissions = permissions
            sftpClient.setStat(path, attributes)
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
    
    /**
     * Format permissions to Unix-style string
     */
    private fun formatPermissions(attributes: org.apache.sshd.sftp.SftpModuleProperties.Attributes): String {
        val perms = attributes.permissions ?: 0
        val type = if (attributes.isDirectory) "d" else "-"
        
        val owner = formatPermissionTriple((perms shr 6) and 0x7)
        val group = formatPermissionTriple((perms shr 3) and 0x7)
        val other = formatPermissionTriple(perms and 0x7)
        
        return "$type$owner$group$other"
    }
    
    private fun formatPermissionTriple(perm: Int): String {
        val r = if (perm and 4 != 0) "r" else "-"
        val w = if (perm and 2 != 0) "w" else "-"
        val x = if (perm and 1 != 0) "x" else "-"
        return "$r$w$x"
    }
}

/**
 * SFTP file entry
 */
data class SftpFileEntry(
    val name: String,
    val path: String,
    val size: Long,
    val isDirectory: Boolean,
    val isFile: Boolean,
    val permissions: String,
    val modifiedAt: Long,
    val owner: String,
    val group: String
)

/**
 * Transfer progress
 */
data class TransferProgress(
    val bytesTransferred: Long,
    val totalBytes: Long,
    val speed: Long, // bytes per second
    val percentage: Float
) {
    init {
        require(totalBytes > 0) { "Total bytes must be greater than 0" }
    }
    
    fun getPercentageString(): String = "%.1f%%".format(percentage)
    
    fun getSpeedString(): String {
        return when {
            speed > 1024 * 1024 -> "%.1f MB/s".format(speed / 1024.0 / 1024.0)
            speed > 1024 -> "%.1f KB/s".format(speed / 1024.0)
            else -> "$speed B/s"
        }
    }
}
