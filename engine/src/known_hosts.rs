//! Known-hosts storage and verification.
//!
//! Stores server public keys keyed by `[host]:port`. On connection,
//! the server's key is compared against the stored key. If no entry
//! exists, the user is prompted to trust or reject the key.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::RwLock;

/// A stored host key entry.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HostKeyEntry {
    pub key_type: String,
    pub fingerprint: String,
}

/// Global known-hosts store.
static KNOWN_HOSTS: RwLock<Option<HashMap<String, HostKeyEntry>>> = RwLock::new(None);

/// Initializes the known-hosts store from disk if not already loaded.
fn ensure_loaded() {
    let guard = KNOWN_HOSTS.read().unwrap();
    if guard.is_some() {
        return;
    }
    drop(guard);

    let mut guard = KNOWN_HOSTS.write().unwrap();
    if guard.is_none() {
        *guard = Some(load_from_disk());
    }
}

/// Verifies a server key against known hosts.
///
/// Returns:
/// - `Ok(true)` if the key matches the stored key
/// - `Ok(false)` if no entry exists (caller should prompt user)
/// - `Err(fingerprint)` if the key conflicts with a stored key (MITM)
pub fn verify_host_key(host: &str, port: u16, fingerprint: &str) -> Result<bool, String> {
    ensure_loaded();
    let key_id = format!("{host}:{port}");

    let guard = KNOWN_HOSTS.read().unwrap();
    let store_ref = guard.as_ref().unwrap();

    match store_ref.get(&key_id) {
        Some(entry) => {
            if entry.fingerprint == fingerprint {
                Ok(true)
            } else {
                Err(format!(
                    "HOST KEY MISMATCH for {key_id}. \
                     Expected: {} Got: {fingerprint}. \
                     Possible man-in-the-middle attack!",
                    entry.fingerprint
                ))
            }
        }
        None => Ok(false),
    }
}

/// Adds or updates a host key entry (called after user approval).
pub fn accept_host_key(host: &str, port: u16, key_type: &str, fingerprint: &str) {
    ensure_loaded();
    let key_id = format!("{host}:{port}");

    let entry = HostKeyEntry {
        key_type: key_type.to_string(),
        fingerprint: fingerprint.to_string(),
    };

    let mut guard = KNOWN_HOSTS.write().unwrap();
    let store_ref = guard.as_mut().unwrap();
    store_ref.insert(key_id, entry);
    drop(guard);

    save_to_disk();
}

fn load_from_disk() -> HashMap<String, HostKeyEntry> {
    // Try to load from app data directory
    if let Ok(data_dir) = std::env::var("BLUESSH_DATA_DIR") {
        let path = format!("{data_dir}/known_hosts.json");
        if let Ok(contents) = std::fs::read_to_string(&path) {
            if let Ok(map) = serde_json::from_str(&contents) {
                return map;
            }
        }
    }
    HashMap::new()
}

fn save_to_disk() {
    if let Ok(data_dir) = std::env::var("BLUESSH_DATA_DIR") {
        let path = format!("{data_dir}/known_hosts.json");
        let guard = KNOWN_HOSTS.read().unwrap();
        if let Some(ref map) = *guard {
            if let Ok(json) = serde_json::to_string_pretty(map) {
                let _ = std::fs::write(&path, json);
            }
        }
    }
}
