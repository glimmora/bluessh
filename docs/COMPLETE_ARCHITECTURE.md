# BlueSSH - Complete Bitvise-Compatible SSH Client Architecture

## System Overview

BlueSSH is a complete SSH client reproducing all Bitvise SSH Client capabilities with a modular, secure, and maintainable architecture.

## Core Capabilities

### 1. Terminal Emulation
- **xterm**: Full xterm-256color with true color (24-bit)
- **vt100**: DEC VT100 compatibility mode
- **bvterm**: BlueSSH custom terminal with enhanced features

### 2. SFTP Graphical Interface
- Drag-and-drop file transfers
- Dual-pane file browser (local/remote)
- Transfer queue with pause/resume
- File permissions editor
- Remote file editing

### 3. Port Forwarding
- **Dynamic**: SOCKS4, SOCKS4A, SOCKS5, HTTP proxy
- **Static C2S**: Client-to-Server (local forwarding)
- **Static S2C**: Server-to-Client (remote forwarding)
- **RDP Bridge**: Automatic remote desktop forwarding

### 4. Authentication
- Password
- Public Key (RSA, ECDSA, Ed25519)
- Keyboard-Interactive
- GSSAPI/Kerberos
- MFA/TOTP

### 5. CLI Tools
- `sftpc`: SFTP command-line client
- `stermc`: Terminal client
- `sexec`: Remote command execution
- `stnlc`: Tunnel client

### 6. Profile Management
- `.bvc` file format (XML-based)
- Profile inheritance
- Encrypted credentials
- Import/Export

### 7. Advanced Features
- Auto-reconnect with state preservation
- Portable distribution (no installation)
- IPv6 connectivity
- Multi-terminal windows per session
- Single-click RDP launch

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      User Interface Layer                    │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────────┐   │
│  │ Desktop  │ │ Android  │ │   CLI    │ │   Web (opt)  │   │
│  │  (Qt6)   │ │(Kotlin)  │ │  Tools   │ │              │   │
│  └────┬─────┘ └────┬─────┘ └────┬─────┘ └──────┬───────┘   │
└───────┼────────────┼────────────┼──────────────┼────────────┘
        │            │            │              │
┌───────┼────────────┼────────────┼──────────────┼────────────┐
│       │   Application Service Layer            │            │
│  ┌────┴────┐  ┌────┴─────┐  ┌───┴──────┐  ┌──┴─────────┐  │
│  │ Session │  │ Terminal │  │   SFTP   │  │ Forwarding │  │
│  │ Manager │  │ Manager  │  │ Manager  │  │  Manager   │  │
│  └────┬────┘  └────┬─────┘  └────┬─────┘  └─────┬──────┘  │
└───────┼────────────┼─────────────┼──────────────┼──────────┘
        │            │             │              │
┌───────┼────────────┼─────────────┼──────────────┼──────────┐
│       │         Core Engine Layer              │           │
│  ┌────┴──────────┴──────────────┴──────────────┴───────┐   │
│  │              SSH Protocol Engine                     │   │
│  │  - Connection  - Authentication  - Channels         │   │
│  │  - Encryption  - Key Exchange    - Compression      │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
        │            │             │              │
┌───────┼────────────┼─────────────┼──────────────┼──────────┐
│       │      Platform Abstraction Layer        │           │
│  ┌────┴────┐  ┌────┴─────┐  ┌───┴──────┐  ┌──┴─────────┐  │
│  │Network  │  │ Crypto   │  │ Terminal │  │   Storage  │  │
│  │IPv4/IPv6│  │OpenSSL   │  │ libvterm │  │  Encrypted │  │
│  │ Proxy   │  │GSSAPI    │  │ custom   │  │  Config    │  │
│  └─────────┘  └──────────┘  └──────────┘  └────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## Implementation Plan

Each component will be implemented with:
1. Clean interfaces and dependency injection
2. Comprehensive error handling
3. Security best practices (credential zeroization, encrypted storage)
4. Async I/O for performance
5. Platform-specific optimizations
