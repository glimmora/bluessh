package com.bluessh.ui

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.Menu
import android.view.MenuItem
import android.view.View
import android.widget.SearchView
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.bluessh.R
import com.bluessh.databinding.ActivityMainBinding
import com.bluessh.models.HostProfile
import com.google.android.material.floatingactionbutton.FloatingActionButton
import kotlinx.coroutines.launch

/**
 * Main Activity - Host list and session management
 */
class MainActivity : AppCompatActivity() {
    
    private lateinit var binding: ActivityMainBinding
    private lateinit var hostAdapter: HostAdapter
    private val hostProfiles = mutableListOf<HostProfile>()
    private val filteredProfiles = mutableListOf<HostProfile>()
    
    private val requestPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { permissions ->
        val allGranted = permissions.values.all { it }
        if (!allGranted) {
            // Handle permission denial
        }
    }
    
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)
        
        setupToolbar()
        setupRecyclerView()
        setupFab()
        requestPermissions()
        loadHostProfiles()
    }
    
    private fun setupToolbar() {
        setSupportActionBar(binding.toolbar)
        supportActionBar?.title = "BlueSSH"
    }
    
    private fun setupRecyclerView() {
        hostAdapter = HostAdapter(filteredProfiles) { profile ->
            connectToHost(profile)
        }
        
        binding.recyclerViewHosts.apply {
            layoutManager = LinearLayoutManager(this@MainActivity)
            adapter = hostAdapter
        }
    }
    
    private fun setupFab() {
        binding.fabAddHost.setOnClickListener {
            showAddHostDialog()
        }
    }
    
    private fun requestPermissions() {
        val permissions = mutableListOf<String>()
        
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                permissions.add(Manifest.permission.POST_NOTIFICATIONS)
            }
        }
        
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED) {
                permissions.add(Manifest.permission.WRITE_EXTERNAL_STORAGE)
                permissions.add(Manifest.permission.READ_EXTERNAL_STORAGE)
            }
        }
        
        if (permissions.isNotEmpty()) {
            requestPermissionLauncher.launch(permissions.toTypedArray())
        }
    }
    
    private fun loadHostProfiles() {
        lifecycleScope.launch {
            // Load from SharedPreferences/Database
            // hostProfiles.addAll(loadProfiles())
            filterProfiles("")
        }
    }
    
    private fun filterProfiles(query: String) {
        filteredProfiles.clear()
        
        if (query.isEmpty()) {
            filteredProfiles.addAll(hostProfiles)
        } else {
            filteredProfiles.addAll(
                hostProfiles.filter { profile ->
                    profile.name.contains(query, ignoreCase = true) ||
                    profile.host.contains(query, ignoreCase = true) ||
                    profile.username.contains(query, ignoreCase = true) ||
                    profile.tags.any { it.contains(query, ignoreCase = true) }
                }
            )
        }
        
        hostAdapter.notifyDataSetChanged()
    }
    
    private fun showAddHostDialog() {
        // Show bottom sheet dialog for adding/editing host
        val dialog = HostProfileDialog.newInstance()
        dialog.show(supportFragmentManager, "HostProfileDialog")
    }
    
    private fun connectToHost(profile: HostProfile) {
        val intent = Intent(this, TerminalActivity::class.java).apply {
            putExtra("host_profile_id", profile.id)
        }
        startActivity(intent)
    }
    
    override fun onCreateOptionsMenu(menu: Menu?): Boolean {
        menuInflater.inflate(R.menu.menu_main, menu)
        
        val searchItem = menu?.findItem(R.id.action_search)
        val searchView = searchItem?.actionView as? SearchView
        searchView?.setOnQueryTextListener(object : SearchView.OnQueryTextListener {
            override fun onQueryTextSubmit(query: String?): Boolean = false
            override fun onQueryTextChange(newText: String?): Boolean {
                filterProfiles(newText ?: "")
                return true
            }
        })
        
        return true
    }
    
    override fun onOptionsItemSelected(item: MenuItem): Boolean {
        return when (item.itemId) {
            R.id.action_settings -> {
                startActivity(Intent(this, SettingsActivity::class.java))
                true
            }
            R.id.action_key_management -> {
                startActivity(Intent(this, KeyManagementActivity::class.java))
                true
            }
            else -> super.onOptionsItemSelected(item)
        }
    }
}

/**
 * Host Adapter for RecyclerView
 */
class HostAdapter(
    private val profiles: List<HostProfile>,
    private val onHostClick: (HostProfile) -> Unit
) : RecyclerView.Adapter<HostAdapter.HostViewHolder>() {
    
    inner class HostViewHolder(view: View) : RecyclerView.ViewHolder(view) {
        fun bind(profile: HostProfile) {
            itemView.setOnClickListener { onHostClick(profile) }
            // Bind profile data to views
        }
    }
    
    override fun onCreateViewHolder(parent: android.view.ViewGroup, viewType: Int): HostViewHolder {
        val view = android.view.LayoutInflater.from(parent.context)
            .inflate(R.layout.item_host_profile, parent, false)
        return HostViewHolder(view)
    }
    
    override fun onBindViewHolder(holder: HostViewHolder, position: Int) {
        holder.bind(profiles[position])
    }
    
    override fun getItemCount(): Int = profiles.size
}
