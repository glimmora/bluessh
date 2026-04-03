package com.bluessh.core

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.spec.ECGenParameterSpec
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.spec.GCMParameterSpec

/**
 * SSH Key Manager - handles key generation, import, and storage
 * Supports RSA, ECDSA, and Ed25519 key types
 */
class KeyManager(private val context: Context) {
    
    private val keyStore = KeyStore.getInstance("AndroidKeyStore").apply {
        load(null)
    }
    
    /**
     * Generate a new SSH key pair
     */
    suspend fun generateKeyPair(
        alias: String,
        keyType: KeyType = KeyType.ED25519,
        keySize: Int = 256,
        passphrase: String? = null
    ): Result<KeyPair> = withContext(Dispatchers.IO) {
        try {
            val keyPair = when (keyType) {
                KeyType.RSA -> generateRsaKeyPair(alias, keySize)
                KeyType.ECDSA -> generateEcdsaKeyPair(alias, keySize)
                KeyType.ED25519 -> generateEd25519KeyPair(alias)
            }
            
            // Store the key pair encrypted if passphrase is provided
            if (passphrase != null) {
                storeEncryptedKey(alias, keyPair, passphrase)
            }
            
            Result.success(keyPair)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
    
    /**
     * Generate RSA key pair
     */
    private fun generateRsaKeyPair(alias: String, keySize: Int): KeyPair {
        val keyPairGenerator = KeyPairGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_RSA,
            "AndroidKeyStore"
        )
        
        val spec = KeyGenParameterSpec.Builder(
            alias,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT or
            KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY
        )
            .setKeySize(keySize)
            .setDigests(KeyProperties.DIGEST_SHA256, KeyProperties.DIGEST_SHA512)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_RSA_PKCS1)
            .setSignaturePaddings(KeyProperties.SIGNATURE_PADDING_RSA_PKCS1)
            .setUserAuthenticationRequired(false)
            .build()
        
        keyPairGenerator.initialize(spec)
        return keyPairGenerator.generateKeyPair()
    }
    
    /**
     * Generate ECDSA key pair
     */
    private fun generateEcdsaKeyPair(alias: String, keySize: Int): KeyPair {
        val keyPairGenerator = KeyPairGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_EC,
            "AndroidKeyStore"
        )
        
        val curveName = when (keySize) {
            256 -> "secp256r1"
            384 -> "secp384r1"
            521 -> "secp521r1"
            else -> "secp256r1"
        }
        
        val spec = KeyGenParameterSpec.Builder(
            alias,
            KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY
        )
            .setKeySize(keySize)
            .setDigests(KeyProperties.DIGEST_SHA256)
            .setAlgorithmParameterSpec(ECGenParameterSpec(curveName))
            .setUserAuthenticationRequired(false)
            .build()
        
        keyPairGenerator.initialize(spec)
        return keyPairGenerator.generateKeyPair()
    }
    
    /**
     * Generate Ed25519 key pair
     * Note: AndroidKeyStore doesn't directly support Ed25519, so we use BouncyCastle
     */
    private fun generateEd25519KeyPair(alias: String): KeyPair {
        // For Ed25519, we need to use BouncyCastle provider
        val keyPairGenerator = KeyPairGenerator.getInstance("Ed25519", "BC")
        return keyPairGenerator.generateKeyPair()
    }
    
    /**
     * Store encrypted key with passphrase
     */
    private fun storeEncryptedKey(alias: String, keyPair: KeyPair, passphrase: String) {
        try {
            // Generate AES key for encryption
            val keyGenerator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
            val spec = KeyGenParameterSpec.Builder(
                "${alias}_aes",
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build()
            keyGenerator.init(spec)
            keyGenerator.generateKey()
            
            // Encrypt private key
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, keyStore.getKey("${alias}_aes", null))
            
            val privateKeyBytes = keyPair.private.encoded
            val encryptedBytes = cipher.doFinal(privateKeyBytes)
            
            // Store encrypted key
            val iv = cipher.iv
            context.openFileOutput("${alias}_encrypted_key", Context.MODE_PRIVATE).use {
                it.write(iv.size)
                it.write(iv)
                it.write(encryptedBytes.size)
                it.write(encryptedBytes)
            }
        } catch (e: Exception) {
            // Log error
        }
    }
    
    /**
     * Load a key pair by alias
     */
    fun loadKeyPair(alias: String, passphrase: String? = null): Result<KeyPair> {
        return try {
            val privateKey = keyStore.getKey(alias, null)
            val publicKey = keyStore.getCertificate(alias)?.publicKey
            
            if (privateKey != null && publicKey != null) {
                Result.success(KeyPair(publicKey, privateKey))
            } else {
                Result.failure(Exception("Key not found"))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
    
    /**
     * List all stored keys
     */
    fun listKeys(): List<String> {
        return keyStore.aliases().toList()
    }
    
    /**
     * Delete a key by alias
     */
    fun deleteKey(alias: String) {
        keyStore.deleteEntry(alias)
        context.deleteFile("${alias}_encrypted_key")
    }
    
    /**
     * Get key fingerprint
     */
    fun getKeyFingerprint(keyPair: KeyPair): String {
        val publicKeyBytes = keyPair.public.encoded
        val md = java.security.MessageDigest.getInstance("SHA-256")
        val digest = md.digest(publicKeyBytes)
        return digest.joinToString(":") { "%02x".format(it) }
    }
}

/**
 * Supported key types
 */
enum class KeyType {
    RSA,
    ECDSA,
    ED25519
}
