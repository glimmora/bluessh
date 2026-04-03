package com.bluessh

import android.app.Application
import com.bluessh.core.SshEngine
import com.bluessh.core.SessionManager
import com.bluessh.utils.KeyStoreManager

class BlueSSHApplication : Application() {
    
    lateinit var sshEngine: SshEngine
        private set
    
    lateinit var sessionManager: SessionManager
        private set
    
    lateinit var keyStoreManager: KeyStoreManager
        private set

    override fun onCreate() {
        super.onCreate()
        instance = this
        
        sshEngine = SshEngine(this)
        sessionManager = SessionManager(this)
        keyStoreManager = KeyStoreManager(this)
    }

    companion object {
        lateinit var instance: BlueSSHApplication
            private set
    }
}
