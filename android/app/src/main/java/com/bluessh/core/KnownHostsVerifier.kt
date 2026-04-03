package com.bluessh.core

import android.content.Context
import org.apache.sshd.client.keyverifier.ServerKeyVerifier
import java.io.File
import java.net.SocketAddress
import java.security.PublicKey
import java.util.Base64
import java.security.MessageDigest
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Known hosts verifier for SSH host key verification
 * Prevents MITM attacks by verifying server host keys
 */
class KnownHostsVerifier(private val context: Context) : ServerKeyVerifier {
    
    private val knownHostsFile = File(context.filesDir, "known_hosts.json")
    private val knownHosts = loadKnownHosts()
    
    @Serializable
    data class KnownHostEntry(
        val host: String,
        val port: Int,
        val keyType: String,
        val fingerprint: String,
        val keyData: String,
        val addedAt: Long = System.currentTimeMillis()
    )
    
    @Serializable
    data class KnownHostsData(
        val hosts: List<KnownHostEntry> = emptyList()
    )
    
    private fun loadKnownHosts(): MutableMap<String, KnownHostEntry> {
        return try {
            if (knownHostsFile.exists()) {
                val json = knownHostsFile.readText()
                val data = Json.decodeFromString<KnownHostsData>(json)
                data.hosts.associateBy { "${it.host}:${it.port}" }.toMutableMap()
            } else {
                mutableMapOf()
            }
        } catch (e: Exception) {
            mutableMapOf()
        }
    }
    
    private fun saveKnownHosts() {
        try {
            val data = KnownHostsData(knownHosts.values.toList())
            val json = Json.encodeToString(KnownHostsData.serializer(), data)
            knownHostsFile.writeText(json)
        } catch (e: Exception) {
            // Log error
        }
    }
    
    override fun verifyServerKey(
        clientSession: org.apache.sshd.client.session.ClientSession,
        remoteAddress: SocketAddress,
        serverKey: PublicKey
    ): Boolean {
        val host = (remoteAddress as? java.net.InetSocketAddress)?.hostName ?: return false
        val port = (remoteAddress as? java.net.InetSocketAddress)?.port ?: 22
        val key = "${host}:${port}"
        
        val fingerprint = calculateFingerprint(serverKey)
        val keyType = serverKey.algorithm
        val keyData = Base64.getEncoder().encodeToString(serverKey.encoded)
        
        return when {
            !knownHosts.containsKey(key) -> {
                // New host - accept and save
                knownHosts[key] = KnownHostEntry(host, port, keyType, fingerprint, keyData)
                saveKnownHosts()
                true
            }
            knownHosts[key]?.fingerprint == fingerprint -> {
                // Known host - key matches
                true
            }
            else -> {
                // Known host - key mismatch (possible MITM attack)
                false
            }
        }
    }
    
    /**
     * Calculate SHA-256 fingerprint of the host key
     */
    private fun calculateFingerprint(key: PublicKey): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val hash = digest.digest(key.encoded)
        return Base64.getEncoder().encodeToString(hash)
    }
    
    /**
     * Get fingerprint for a host
     */
    fun getFingerprint(host: String, port: Int): String? {
        return knownHosts["${host}:${port}"]?.fingerprint
    }
    
    /**
     * Remove a host from known hosts
     */
    fun removeHost(host: String, port: Int) {
        knownHosts.remove("${host}:${port}")
        saveKnownHosts()
    }
    
    /**
     * Get all known hosts
     */
    fun getAllHosts(): List<KnownHostEntry> {
        return knownHosts.values.toList()
    }
}
