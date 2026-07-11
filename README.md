# PowerShell Messaging

A secure, encrypted peer-to-peer messaging app written entirely in PowerShell. Supports end-to-end encryption with forward secrecy, file sharing, group chats, and more.

## Features

- **End-to-End Encryption** - RSA-2048 + AES-256 for message encryption
- **Forward Secrecy** - ECDH-P521 ephemeral key exchange per message; past messages stay safe even if keys are compromised
- **Message Signing** - All messages signed with RSA-2048 + SHA256 for authenticity verification
- **File Sharing** - Send files of any size through auto-chunked, encrypted transfers
- **Group Chats** - Create groups, manage members, broadcast encrypted messages
- **History & Search** - Persistent message history searchable by text, sender, or date
- **Rate Limiting** - 10 messages/second to prevent spam
- **Peer-to-Peer** - Direct LAN discovery via UDP broadcast
- **Relay Server** - Optional relay for online/remote communication with TLS + password auth
- **Directory Server** - Optional registry for finding users by code
- **Proxy Support** - SOCKS5/HTTP proxy for relay connections
- **Metadata Obfuscation** - Optional relay metadata hiding

## Quick Start

### Local Chat (LAN)

```powershell
.\launcher.bat
# Or directly:
powershell -ExecutionPolicy Bypass -File Message.ps1
```

### Online Chat (with Relay)

**Person A** (relay host):
```powershell
.\launcher.bat
# Choose option 2 (Start Relay Server), set a password
```

**Person B** (client):
```powershell
.\launcher.bat
# Choose option 3 (Connect to Relay Server), enter the relay address and password
```

## Menu Options

| Option | Description |
|--------|-------------|
| 1 | Send Message (to friend or by code) |
| 2 | View Inbox |
| 3-5 | Friends List management |
| 6-8 | Blocking management |
| 9 | Your Info / Status |
| 10 | Re-Register with Directory |
| 11 | Groups (create, join, chat, manage) |
| 12 | Send File to a friend |
| 13 | Search Message History |
| 14 | View Downloads |

## Security Architecture

- **Key Exchange**: ECDH-P521 (NIST P-521) with ephemeral keys for forward secrecy
- **Encryption**: AES-256-CBC with random IV per message
- **Signing**: RSA-2048 with PKCS#1 v1.5 SHA256
- **Transport**: Optional TLS 1.2 for relay connections
- **Rate Limit**: 10 messages/second

## Files

| File | Description |
|------|-------------|
| `Message.ps1` | Main chat application |
| `Registry.ps1` | Directory/registry server |
| `launcher.bat` | Batch launcher with menu |
| `USE_LAUNCHER_ONLY` | Flag file |

## Requirements

- Windows (PowerShell 5.1+ or PowerShell 7+)
- .NET Framework 4.7+ / .NET Core 3.1+
- Network connectivity (for online features)

## License

MIT
