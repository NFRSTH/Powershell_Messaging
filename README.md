# PowerShell Messaging

A secure, encrypted peer-to-peer messaging app written entirely in PowerShell. Supports end-to-end encryption with forward secrecy, file sharing, group chats, AI assistant, self-destructing messages, and more.

## Why Choose This Over WhatsApp / Discord?

| Feature | This App | WhatsApp | Discord |
|---------|----------|----------|---------|
| **AI Assistant in Chat** (`/ai`) | ✅ Native | ❌ | ❌ (no built-in) |
| **End-to-End Encryption** | ✅ RSA-2048 + AES-256 | ✅ | ❌ (in most DMs) |
| **Forward Secrecy** | ✅ ECDH-P521 | ❌ | ❌ |
| **Self-Destructing Messages** | ✅ Timed auto-delete | ✅ | ❌ |
| **Message Scheduling** | ✅ `/schedule` | ❌ | ❌ |
| **Broadcast Channels** | ✅ `/broadcast` | ❌ | ❌ |
| **Message Translation** | ✅ `/tl` (AI-powered) | ✅ | ❌ |
| **Quote Reply** | ✅ `/r <idx>` | ✅ | ✅ |
| **Undo Send / Recall** | ✅ `/recall` (30s) | ✅ | ❌ |
| **Per-Contact Mute** | ✅ `/mute` | ✅ | ✅ |
| **Voice Notes** | ✅ Record & Send | ✅ | ✅ |
| **File Sharing** | ✅ Encrypted chunks | ✅ | ✅ |
| **Delivery Receipts** | ✅ [D] badge | ✅ | ✅ |
| **Typing Indicator** | ✅ | ✅ | ✅ |
| **Message Reactions** | ✅ Emoji reactions | ✅ | ✅ |
| **Open Source** | ✅ Full source | ❌ | ❌ |
| **No Account Required** | ✅ Peer-to-peer | ❌ | ❌ |
| **Zero Data Collection** | ✅ 100% private | ❌ | ❌ |

## Features

### 🤖 AI Assistant
- Use `/ai <prompt>` in any chat to ask an AI (OpenAI-compatible API)
- Set your API key with `/ai key <key>`, endpoint with `/ai endpoint <url>`
- AI-powered translation with `/tl <lang> <text>`

### 💣 Self-Destructing Messages
- `!s <seconds> <message>` for one-off self-destructing messages
- `/ephemeral` to toggle ephemeral mode (all messages auto-delete after N seconds)
- Messages are replaced with "[Self-destructed message]" after expiry

### ⏰ Message Scheduling
- `/schedule <YYYY-MM-DD HH:mm> <message>` to schedule messages
- Messages auto-send at the specified time, even if you're offline

### 📢 Broadcast
- `/broadcast <message>` to send a message to all friends at once
- Great for announcements or group updates

### 🌍 Message Translation
- `/tl <lang> <text>` to translate any text
- `/tl set <lang>` to set your default translation language
- Powered by AI for natural translations

### 🔇 Per-Contact Mute
- `/mute` in a chat to silence notifications from that contact
- Muted contacts show `[MUTED]` in your friends list
- Mute/unmute from menu option 23

### 💬 Quote Reply
- `/r <index> <reply>` to reply to a specific message with quoted context
- Great for keeping conversations organized

### ↩️ Message Recall
- `/recall` to undo your last sent message (within 30 seconds)
- Recalled messages show as "[Recalled message]"

### Core Features
- **End-to-End Encryption** - RSA-2048 + AES-256 for message encryption
- **Forward Secrecy** - ECDH-P521 ephemeral key exchange per message
- **Message Signing** - All messages signed with RSA-2048 + SHA256
- **File Sharing** - Send files of any size through auto-chunked encrypted transfers
- **Group Chats** - Create groups, manage members, broadcast encrypted messages
- **Voice Notes** - Record and send voice messages (C# P/Invoke via winmm.dll)
- **Emoji Reactions** - React to messages with emojis and shortcodes
- **Message Pinning** - Pin important messages for quick reference
- **History & Search** - Full-text search by sender, date, and content
- **Chat Export** - Export conversation history to text files
- **Message Editing/Deletion** - Edit or delete your sent messages
- **Delivery Receipts** - See when your messages are delivered [D]
- **Typing Indicator** - See when someone is typing
- **Rate Limiting** - 10 messages/second to prevent spam
- **Peer-to-Peer** - Direct LAN discovery via UDP broadcast
- **Relay Server** - TLS-encrypted relay for online/remote communication
- **Directory Server** - Find users by code
- **Metadata Obfuscation** - Hide sender/recipient from relay
- **Proxy Support** - SOCKS5/HTTP proxy for relay connections

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

## Slash Commands (in chat)

| Command | Description |
|---------|-------------|
| `/ai <prompt>` | Ask the AI assistant |
| `/ai key <key>` | Set your OpenAI API key |
| `/ai endpoint <url>` | Set custom AI endpoint |
| `/ai model <name>` | Set AI model |
| `/schedule <time> <msg>` | Schedule a message |
| `/broadcast <msg>` | Send to all friends |
| `/tl <lang> <text>` | Translate text |
| `/tl set <lang>` | Set default translation language |
| `/mute` | Toggle mute for this contact |
| `/recall` | Undo last sent message (30s) |
| `/r <idx> <reply>` | Reply with quote |
| `/ephemeral` | Toggle self-destruct mode |
| `/s <query>` | Search messages |
| `/e` | Show emoji list |
| `/help` | Show all commands |
| `!s <sec> <msg>` | Send self-destructing message |

## Menu Options

| Option | Description |
|--------|-------------|
| 1 | Send Message |
| 2 | View Inbox |
| 3-5 | Friends List management |
| 6-8 | Blocking management |
| 9 | Your Info / Status |
| 10 | Re-Register with Directory |
| 11 | Groups |
| 12 | Send File |
| 13 | Search History |
| 14 | View Downloads |
| 15 | Delete a Message |
| 16 | Edit a Message |
| 17 | Send Voice Note |
| 18 | Clear Chat |
| 19 | Export Chat History |
| 20 | Set Your Status |
| 21 | Message Stats |
| 22 | AI Configuration |
| 23 | Mute/Unmute Friend |
| 24 | Broadcast Message |
| 25 | Scheduled Messages |

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
