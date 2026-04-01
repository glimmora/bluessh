//! Comprehensive tests for the BlueSSH engine.

#[cfg(test)]
mod tests {
    use crate::*;
    use std::ffi::CString;
    use std::os::raw::c_char;

    // ═══════════════════════════════════════════════════════════
    //  Engine Initialization
    // ═══════════════════════════════════════════════════════════

    #[test]
    fn engine_init_returns_zero() {
        assert_eq!(engine_init(), 0);
    }

    #[test]
    fn engine_init_idempotent() {
        assert_eq!(engine_init(), 0);
        assert_eq!(engine_init(), 0);
    }

    #[test]
    fn engine_shutdown_returns_zero() {
        engine_init();
        assert_eq!(engine_shutdown(), 0);
    }

    // ═══════════════════════════════════════════════════════════
    //  Session Connection
    // ═══════════════════════════════════════════════════════════

    #[test]
    fn connect_null_config_returns_zero() {
        assert_eq!(unsafe { engine_connect(std::ptr::null()) }, 0);
    }

    #[test]
    fn connect_null_host_returns_zero() {
        engine_init();
        let config = CSessionConfig {
            host: std::ptr::null(),
            port: 22,
            protocol: 0,
            compress_level: 2,
            record_session: false,
        };
        assert_eq!(unsafe { engine_connect(&config as *const _) }, 0);
    }

    #[test]
    fn connect_invalid_protocol_returns_zero() {
        engine_init();
        let host = CString::new("127.0.0.1").unwrap();
        let config = CSessionConfig {
            host: host.as_ptr(),
            port: 22,
            protocol: 255,
            compress_level: 2,
            record_session: false,
        };
        assert_eq!(unsafe { engine_connect(&config as *const _) }, 0);
    }

    #[test]
    fn connect_empty_host_returns_zero() {
        engine_init();
        let host = CString::new("").unwrap();
        let config = CSessionConfig {
            host: host.as_ptr(),
            port: 22,
            protocol: 0,
            compress_level: 2,
            record_session: false,
        };
        assert_eq!(unsafe { engine_connect(&config as *const _) }, 0);
    }

    #[test]
    fn connect_valid_config_returns_nonzero() {
        engine_init();
        let host = CString::new("127.0.0.1").unwrap();
        let config = CSessionConfig {
            host: host.as_ptr(),
            port: 22,
            protocol: 0,
            compress_level: 2,
            record_session: false,
        };
        let sid = unsafe { engine_connect(&config as *const _) };
        assert!(sid > 0, "Session ID should be > 0");
        unsafe { engine_disconnect(sid) };
    }

    // ═══════════════════════════════════════════════════════════
    //  Session Disconnect
    // ═══════════════════════════════════════════════════════════

    #[test]
    fn disconnect_nonexistent_returns_minus_one() {
        engine_init();
        assert_eq!(unsafe { engine_disconnect(99999) }, -1);
    }

    #[test]
    fn disconnect_existing_returns_zero() {
        engine_init();
        let host = CString::new("127.0.0.1").unwrap();
        let config = CSessionConfig {
            host: host.as_ptr(),
            port: 22,
            protocol: 0,
            compress_level: 2,
            record_session: false,
        };
        let sid = unsafe { engine_connect(&config as *const _) };
        assert!(sid > 0);
        assert_eq!(unsafe { engine_disconnect(sid) }, 0);
    }

    #[test]
    fn disconnect_twice_returns_minus_one() {
        engine_init();
        let host = CString::new("127.0.0.1").unwrap();
        let config = CSessionConfig {
            host: host.as_ptr(),
            port: 22,
            protocol: 0,
            compress_level: 2,
            record_session: false,
        };
        let sid = unsafe { engine_connect(&config as *const _) };
        unsafe { engine_disconnect(sid) };
        assert_eq!(unsafe { engine_disconnect(sid) }, -1);
    }

    // ═══════════════════════════════════════════════════════════
    //  Write/Read Null Safety
    // ═══════════════════════════════════════════════════════════

    #[test]
    fn write_null_data_returns_minus_one() {
        assert_eq!(unsafe { engine_write(1, std::ptr::null(), 10) }, -1);
    }

    #[test]
    fn write_zero_len_returns_minus_one() {
        let data = [0u8; 1];
        assert_eq!(unsafe { engine_write(1, data.as_ptr(), 0) }, -1);
    }

    #[test]
    fn read_null_buffer_returns_minus_one() {
        let mut read = 0usize;
        assert_eq!(
            unsafe { engine_read(1, std::ptr::null_mut(), 1024, &mut read as *mut _) },
            -1
        );
    }

    #[test]
    fn read_zero_len_returns_minus_one() {
        let mut buf = [0u8; 10];
        let mut read = 0usize;
        assert_eq!(
            unsafe { engine_read(1, buf.as_mut_ptr(), 0, &mut read as *mut _) },
            -1
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  Resize Null Safety
    // ═══════════════════════════════════════════════════════════

    #[test]
    fn resize_zero_cols_returns_minus_one() {
        assert_eq!(unsafe { engine_resize(1, 0, 24) }, -1);
    }

    #[test]
    fn resize_zero_rows_returns_minus_one() {
        assert_eq!(unsafe { engine_resize(1, 80, 0) }, -1);
    }

    // ═══════════════════════════════════════════════════════════
    //  Auth Null Safety
    // ═══════════════════════════════════════════════════════════

    #[test]
    fn auth_password_null_returns_minus_one() {
        assert_eq!(unsafe { engine_auth_password(1, std::ptr::null()) }, -1);
    }

    #[test]
    fn auth_key_null_returns_minus_one() {
        assert_eq!(unsafe { engine_auth_key(1, std::ptr::null()) }, -1);
    }

    #[test]
    fn auth_mfa_null_returns_minus_one() {
        assert_eq!(unsafe { engine_auth_mfa(1, std::ptr::null()) }, -1);
    }

    // ═══════════════════════════════════════════════════════════
    //  Recording Null Safety
    // ═══════════════════════════════════════════════════════════

    #[test]
    fn recording_start_null_returns_minus_one() {
        assert_eq!(unsafe { engine_recording_start(1, std::ptr::null()) }, -1);
    }

    // ═══════════════════════════════════════════════════════════
    //  Key Generation Null Safety
    // ═══════════════════════════════════════════════════════════

    #[test]
    fn keygen_null_path_returns_minus_one() {
        let mut pk = [0u8; 1024];
        assert_eq!(
            unsafe {
                engine_key_generate(
                    0,
                    std::ptr::null(),
                    std::ptr::null(),
                    pk.as_mut_ptr() as *mut _,
                    1024,
                )
            },
            -1
        );
    }

    #[test]
    fn keygen_null_pubkey_returns_minus_one() {
        let path = CString::new("/tmp/test_key").unwrap();
        assert_eq!(
            unsafe {
                engine_key_generate(
                    0,
                    path.as_ptr(),
                    std::ptr::null(),
                    std::ptr::null_mut(),
                    1024,
                )
            },
            -1
        );
    }

    #[test]
    fn keygen_zero_buf_returns_minus_one() {
        let path = CString::new("/tmp/test_key").unwrap();
        let mut pk = [0u8; 1024];
        assert_eq!(
            unsafe {
                engine_key_generate(
                    0,
                    path.as_ptr(),
                    std::ptr::null(),
                    pk.as_mut_ptr() as *mut _,
                    0,
                )
            },
            -1
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  TOTP Null Safety
    // ═══════════════════════════════════════════════════════════

    #[test]
    fn totp_null_secret_returns_minus_one() {
        let mut code = [0u8; 7];
        assert_eq!(
            unsafe { engine_totp_generate(std::ptr::null(), code.as_mut_ptr() as *mut _, 7) },
            -1
        );
    }

    #[test]
    fn totp_small_buf_returns_minus_one() {
        let secret = CString::new("JBSWY3DPEHPK3PXP").unwrap();
        let mut code = [0u8; 3];
        assert_eq!(
            unsafe { engine_totp_generate(secret.as_ptr(), code.as_mut_ptr() as *mut _, 3) },
            -1
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  SFTP Null Safety
    // ═══════════════════════════════════════════════════════════

    #[test]
    fn sftp_list_null_path_returns_minus_one() {
        let mut json = [0u8; 4096];
        assert_eq!(
            unsafe { engine_sftp_list(1, std::ptr::null(), json.as_mut_ptr() as *mut _, 4096) },
            -1
        );
    }

    #[test]
    fn sftp_list_null_buffer_returns_minus_one() {
        let path = CString::new("/tmp").unwrap();
        assert_eq!(
            unsafe { engine_sftp_list(1, path.as_ptr(), std::ptr::null_mut(), 4096) },
            -1
        );
    }

    #[test]
    fn sftp_upload_null_returns_minus_one() {
        assert_eq!(
            unsafe { engine_sftp_upload(1, std::ptr::null(), std::ptr::null()) },
            -1
        );
    }

    #[test]
    fn sftp_download_null_returns_minus_one() {
        assert_eq!(
            unsafe { engine_sftp_download(1, std::ptr::null(), std::ptr::null()) },
            -1
        );
    }

    #[test]
    fn sftp_mkdir_null_returns_minus_one() {
        assert_eq!(unsafe { engine_sftp_mkdir(1, std::ptr::null()) }, -1);
    }

    #[test]
    fn sftp_delete_null_returns_minus_one() {
        assert_eq!(unsafe { engine_sftp_delete(1, std::ptr::null()) }, -1);
    }

    #[test]
    fn sftp_rename_null_returns_minus_one() {
        assert_eq!(
            unsafe { engine_sftp_rename(1, std::ptr::null(), std::ptr::null()) },
            -1
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  Type Values
    // ═══════════════════════════════════════════════════════════

    #[test]
    fn protocol_type_values() {
        assert_eq!(ProtocolType::Ssh as u8, 0);
        assert_eq!(ProtocolType::Vnc as u8, 1);
        assert_eq!(ProtocolType::Rdp as u8, 2);
    }

    #[test]
    fn compression_level_values() {
        assert_eq!(CompressionLevel::None as u8, 0);
        assert_eq!(CompressionLevel::Low as u8, 1);
        assert_eq!(CompressionLevel::Med as u8, 2);
        assert_eq!(CompressionLevel::High as u8, 3);
    }
}
