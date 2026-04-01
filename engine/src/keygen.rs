//! SSH key pair generation.

use rand::rngs::OsRng;
use ssh_key::{Algorithm, LineEnding, PrivateKey};
use tracing::info;

/// Supported key types.
#[repr(u8)]
pub enum KeyType {
    Ed25519 = 0,
    Ecdsa = 1,
    Rsa = 2,
}

/// Generates an SSH key pair and writes the private key to `output_path`.
///
/// The public key is written to `output_path.pub`.
///
/// Returns the public key in OpenSSH format on success, or an error string.
pub fn generate_key_pair(
    key_type: KeyType,
    output_path: &str,
    _passphrase: Option<&str>,
) -> Result<String, String> {
    let private_key = match key_type {
        KeyType::Ed25519 => PrivateKey::random(&mut OsRng, Algorithm::Ed25519)
            .map_err(|e| format!("Ed25519 generation failed: {e}"))?,
        KeyType::Ecdsa => {
            return Err("ECDSA key generation not supported in this version".into());
        }
        KeyType::Rsa => {
            return Err("RSA key generation requires additional dependencies".into());
        }
    };

    // Write private key (unencrypted for now — passphrase encryption
    // requires ssh_key >= 0.7 which adds PrivateKey::encrypt())
    let pem = private_key
        .to_openssh(LineEnding::LF)
        .map_err(|e| format!("PEM encoding failed: {e}"))?;
    let pem_str: &str = pem.as_ref();
    std::fs::write(output_path, pem_str).map_err(|e| format!("Write private key failed: {e}"))?;

    // Set permissions (Unix only)
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(output_path, std::fs::Permissions::from_mode(0o600));
    }

    // Write public key
    let public_key = private_key.public_key();
    let pub_openssh = public_key
        .to_openssh()
        .map_err(|e| format!("Public key encoding failed: {e}"))?;
    let pub_path = format!("{output_path}.pub");
    let pub_str: &str = pub_openssh.as_ref();
    std::fs::write(&pub_path, pub_str).map_err(|e| format!("Write public key failed: {e}"))?;

    info!("Key pair generated: {output_path}");

    Ok(pub_openssh.to_string())
}
