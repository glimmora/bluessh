//! Per-session SSH connection handler using russh.

use std::sync::Arc;
use tokio::sync::mpsc;
use tracing::{info, warn};
use zeroize::Zeroize;

/// Events sent from the SSH session back to the FFI layer.
#[derive(Debug)]
pub enum SessionEvent {
    Connected,
    Authenticated,
    Data(Vec<u8>),
    Disconnected(String),
    Error(String),
    HostKeyReceived {
        key_type: String,
        fingerprint: String,
    },
}

/// Commands sent from the FFI layer to the SSH session.
#[derive(Debug)]
pub enum SessionCommand {
    Write(Vec<u8>),
    Resize { cols: u16, rows: u16 },
    Disconnect,
}

/// Configuration for a new SSH connection.
pub struct SshConfig {
    pub host: String,
    pub port: u16,
    pub username: String,
    pub password: Option<String>,
    pub key_path: Option<String>,
    pub passphrase: Option<String>,
    /// Connection timeout in seconds. 0 means use default (30s).
    pub timeout_secs: u64,
}

impl Default for SshConfig {
    fn default() -> Self {
        Self {
            host: String::new(),
            port: 22,
            username: String::new(),
            password: None,
            key_path: None,
            passphrase: None,
            timeout_secs: 30,
        }
    }
}

/// Handle to an active SSH session.
pub struct SshSessionHandle {
    pub event_rx: mpsc::UnboundedReceiver<SessionEvent>,
    pub command_tx: mpsc::UnboundedSender<SessionCommand>,
}

/// Client handler for russh.
pub struct ClientHandler {
    pub event_tx: mpsc::UnboundedSender<SessionEvent>,
}

impl russh::client::Handler for ClientHandler {
    type Error = anyhow::Error;

    async fn check_server_key(
        &mut self,
        server_public_key: &russh::keys::PublicKey,
    ) -> Result<bool, Self::Error> {
        let key_type = format!("{:?}", server_public_key.algorithm());
        let fingerprint = format!("{:?}", server_public_key);

        let _ = self.event_tx.send(SessionEvent::HostKeyReceived {
            key_type,
            fingerprint,
        });

        // Accept all keys for now — host key verification is a future enhancement
        Ok(true)
    }
}

/// Establishes an SSH connection and returns a handle for I/O.
///
/// This function:
/// 1. Opens a TCP connection to the target host
/// 2. Performs the SSH handshake
/// 3. Authenticates (password or key-based)
/// 4. Opens a PTY shell channel
/// 5. Spawns async I/O loops for bidirectional data flow
pub async fn connect_ssh(config: SshConfig) -> Result<SshSessionHandle, String> {
    let (event_tx, event_rx) = mpsc::unbounded_channel();
    let (command_tx, mut command_rx) = mpsc::unbounded_channel();

    let handler = ClientHandler {
        event_tx: event_tx.clone(),
    };

    let addr = (config.host.as_str(), config.port);
    let timeout = if config.timeout_secs == 0 {
        std::time::Duration::from_secs(30)
    } else {
        std::time::Duration::from_secs(config.timeout_secs)
    };

    // Step 1+2: TCP connect and SSH handshake with timeout
    let ssh_config = Arc::new(russh::client::Config::default());
    let mut session = match tokio::time::timeout(
        timeout,
        russh::client::connect(ssh_config, addr, handler),
    ).await {
        Ok(Ok(s)) => s,
        Ok(Err(e)) => return Err(format!("SSH connect failed: {e}")),
        Err(_) => return Err(format!("Connection timed out after {}s", config.timeout_secs)),
    };

    let _ = event_tx.send(SessionEvent::Connected);

    // Step 3: Authenticate
    let auth_success = if let Some(password) = &config.password {
        let mut pw = password.clone();
        let result = session
            .authenticate_password(&config.username, &pw)
            .await
            .map_err(|e| format!("Password auth failed: {e}"))?;
        pw.zeroize();
        result
    } else if let Some(key_path) = &config.key_path {
        let key_pair = russh::keys::load_secret_key(key_path, config.passphrase.as_deref())
            .map_err(|e| format!("Key load failed: {e}"))?;
        let key_with_alg = russh::keys::PrivateKeyWithHashAlg::new(
            Arc::new(key_pair),
            None,
        );
        session
            .authenticate_publickey(&config.username, key_with_alg)
            .await
            .map_err(|e| format!("Key auth failed: {e}"))?
    } else {
        return Err("No authentication method provided".into());
    };

    if !auth_success.success() {
        return Err("Authentication rejected by server".into());
    }

    let _ = event_tx.send(SessionEvent::Authenticated);
    info!("SSH session authenticated for {}", config.username);

    // Step 4: Open channel and request PTY + shell
    let mut channel = session
        .channel_open_session()
        .await
        .map_err(|e| format!("Channel open failed: {e}"))?;

    channel
        .request_pty(true, "xterm-256color", 80, 24, 0, 0, &[])
        .await
        .map_err(|e| format!("PTY request failed: {e}"))?;

    channel
        .request_shell(true)
        .await
        .map_err(|e| format!("Shell request failed: {e}"))?;

    info!("SSH shell channel established");

    // Step 5: Spawn I/O loop
    let event_tx_clone = event_tx.clone();
    tokio::spawn(async move {
        loop {
            tokio::select! {
                // Read data from server
                msg = channel.wait() => {
                    match msg {
                        Some(russh::ChannelMsg::Data { ref data }) => {
                            let _ = event_tx_clone
                                .send(SessionEvent::Data(data.to_vec()));
                        }
                        Some(russh::ChannelMsg::ExtendedData { ref data, .. }) => {
                            let _ = event_tx_clone
                                .send(SessionEvent::Data(data.to_vec()));
                        }
                        Some(russh::ChannelMsg::Eof) => {
                            let _ = event_tx_clone
                                .send(SessionEvent::Disconnected("Server closed connection".into()));
                            break;
                        }
                        Some(russh::ChannelMsg::Close) => {
                            let _ = event_tx_clone
                                .send(SessionEvent::Disconnected("Channel closed".into()));
                            break;
                        }
                        None => {
                            let _ = event_tx_clone
                                .send(SessionEvent::Disconnected("Session ended".into()));
                            break;
                        }
                        _ => {}
                    }
                }

                // Read commands from FFI layer
                cmd = command_rx.recv() => {
                    match cmd {
                        Some(SessionCommand::Write(data)) => {
                            if let Err(e) = channel.data(&data[..]).await {
                                warn!("Write failed: {e}");
                                let _ = event_tx_clone
                                    .send(SessionEvent::Error(format!("Write failed: {e}")));
                            }
                        }
                        Some(SessionCommand::Resize { cols, rows }) => {
                            if let Err(e) = channel
                                .window_change(cols as u32, rows as u32, 0, 0)
                                .await
                            {
                                warn!("Resize failed: {e}");
                            }
                        }
                        Some(SessionCommand::Disconnect) => {
                            let _ = channel.close().await;
                            let _ = event_tx_clone
                                .send(SessionEvent::Disconnected("User disconnected".into()));
                            break;
                        }
                        None => break,
                    }
                }
            }
        }

        info!("SSH I/O loop ended");
    });

    Ok(SshSessionHandle {
        event_rx,
        command_tx,
    })
}
