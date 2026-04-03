package com.bluessh.utils

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.bluessh.models.AppSettings
import com.bluessh.models.HostProfile
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/**
 * Secure KeyStore Manager
 * Handles encrypted storage of sensitive data
 */
class KeyStoreManager(private val context: Context) {
    
    private val masterKey = MasterKey.Builder(context)
        .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
        .build()
    
    private val securePrefs: SharedPreferences = EncryptedSharedPreferences.create(
        context,
        "secure_prefs",
        masterKey,
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
    )
    
    private val prefs: SharedPreferences = context.getSharedPreferences(
        "app_prefs",
        Context.MODE_PRIVATE
    )
    
    private val json = Json { ignoreUnknownKeys = true }
    
    /**
     * Store password securely
     */
    fun storePassword(hostId: String, password: String) {
        securePrefs.edit()
            .putString("password_$hostId", password)
            .apply()
    }
    
    /**
     * Retrieve password
     */
    fun getPassword(hostId: String): String? {
        return securePrefs.getString("password_$hostId", null)
    }
    
    /**
     * Store SSH key data securely
     */
    fun storeKeyData(hostId: String, keyData: String) {
        securePrefs.edit()
            .putString("key_data_$hostId", keyData)
            .apply()
    }
    
    /**
     * Retrieve SSH key data
     */
    fun getKeyData(hostId: String): String? {
        return securePrefs.getString("key_data_$hostId", null)
    }
    
    /**
     * Store passphrase securely
     */
    fun storePassphrase(hostId: String, passphrase: String) {
        securePrefs.edit()
            .putString("passphrase_$hostId", passphrase)
            .apply()
    }
    
    /**
     * Retrieve passphrase
     */
    fun getPassphrase(hostId: String): String? {
        return securePrefs.getString("passphrase_$hostId", null)
    }
    
    /**
     * Store MFA secret securely
     */
    fun storeMfaSecret(hostId: String, secret: String) {
        securePrefs.edit()
            .putString("mfa_secret_$hostId", secret)
            .apply()
    }
    
    /**
     * Retrieve MFA secret
     */
    fun getMfaSecret(hostId: String): String? {
        return securePrefs.getString("mfa_secret_$hostId", null)
    }
    
    /**
     * Store jump host password
     */
    fun storeJumpHostPassword(hostId: String, password: String) {
        securePrefs.edit()
            .putString("jump_password_$hostId", password)
            .apply()
    }
    
    /**
     * Retrieve jump host password
     */
    fun getJumpHostPassword(hostId: String): String? {
        return securePrefs.getString("jump_password_$hostId", null)
    }
    
    /**
     * Delete all credentials for a host
     */
    fun deleteCredentials(hostId: String) {
        securePrefs.edit()
            .remove("password_$hostId")
            .remove("key_data_$hostId")
            .remove("passphrase_$hostId")
            .remove("mfa_secret_$hostId")
            .remove("jump_password_$hostId")
            .apply()
    }
    
    /**
     * Save host profile (non-sensitive data)
     */
    fun saveHostProfile(profile: HostProfile) {
        val profiles = getAllHostProfiles().toMutableList()
        val existingIndex = profiles.indexOfFirst { it.id == profile.id }
        
        if (existingIndex >= 0) {
            profiles[existingIndex] = profile
        } else {
            profiles.add(profile)
        }
        
        val profilesJson = json.encodeToString(profiles)
        prefs.edit()
            .putString("host_profiles", profilesJson)
            .apply()
    }
    
    /**
     * Get all host profiles
     */
    fun getAllHostProfiles(): List<HostProfile> {
        val profilesJson = prefs.getString("host_profiles", null) ?: return emptyList()
        return try {
            json.decodeFromString<List<HostProfile>>(profilesJson)
        } catch (e: Exception) {
            emptyList()
        }
    }
    
    /**
     * Get host profile by ID
     */
    fun getHostProfile(profileId: String): HostProfile? {
        return getAllHostProfiles().find { it.id == profileId }
    }
    
    /**
     * Delete host profile
     */
    fun deleteHostProfile(profileId: String) {
        val profiles = getAllHostProfiles().toMutableList()
        profiles.removeAll { it.id == profileId }
        
        val profilesJson = json.encodeToString(profiles)
        prefs.edit()
            .putString("host_profiles", profilesJson)
            .apply()
        
        // Also delete credentials
        deleteCredentials(profileId)
    }
    
    /**
     * Save application settings
     */
    fun saveSettings(settings: AppSettings) {
        val settingsJson = json.encodeToString(settings)
        prefs.edit()
            .putString("app_settings", settingsJson)
            .apply()
    }
    
    /**
     * Get application settings
     */
    fun getSettings(): AppSettings {
        val settingsJson = prefs.getString("app_settings", null) ?: return AppSettings()
        return try {
            json.decodeFromString<AppSettings>(settingsJson)
        } catch (e: Exception) {
            AppSettings()
        }
    }
    
    /**
     * Clear all data
     */
    fun clearAll() {
        prefs.edit().clear().apply()
        securePrefs.edit().clear().apply()
    }
}
