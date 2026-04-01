//! TOTP code generation for MFA.

use totp_rs::{Algorithm, TOTP};

/// Generates a TOTP code from a base32-encoded secret.
///
/// Returns `Some(code)` on success, `None` if the secret is invalid.
pub fn generate_totp(secret_base32: &str) -> Option<String> {
    let totp = TOTP::new(Algorithm::SHA1, 6, 1, 30, secret_base32.as_bytes().to_vec()).ok()?;

    totp.generate_current().ok()
}
