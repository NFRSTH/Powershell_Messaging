@echo off
setlocal enabledelayedexpansion
title Message App - Secure Chat
color 0A
cls

echo ========================================
echo     Message App v2.0 - Secure Chat
echo ========================================
echo.
echo [1] Start Chat (default)
echo [2] Start Relay Server
echo [3] Connect to Relay Server
echo [4] Start Directory Server
echo [5] Connect to Directory
echo [6] View Your Code
echo [7] Help / Info
echo.
echo Features: FS ECDH-P521 + RSA Signing + AES-256
echo Delivery Receipts + Typing + Chat Export + Persistent ID
echo Rate Limit (10/s), File Sharing, Groups, Search
echo.
set /p choice="Select option (1-7): "

if "%choice%"=="1" goto start
if "%choice%"=="2" goto relay
if "%choice%"=="3" goto connect
if "%choice%"=="4" goto registrysrv
if "%choice%"=="5" goto registrycon
if "%choice%"=="6" goto code
if "%choice%"=="7" goto help

echo Invalid option. Starting default.
timeout /t 2 /nobreak >nul
goto start

:start
powershell.exe -ExecutionPolicy Bypass -File "%~dp0Message.ps1"
goto end

:relay
set /p port="Enter relay port (default 9999): "
if "%port%"=="" set port=9999
set /p relaypass="Enter relay password (leave blank for open): "
set obfuscate=
if not "%relaypass%"=="" (
    set /p obfuscate="Hide metadata (inbox IDs)? (y/n): "
)
set httpport=
if not "%relaypass%"=="" (
    set /p httpport="HTTP wrapper port (0 to disable): "
)
set args=-RelayPort "%port%"
if not "%relaypass%"=="" set "args=!args! -RelayPassword "%relaypass%""
if /i "%obfuscate%"=="y" set "args=!args! -RelayObfuscate"
if not "%httpport%"=="" if not "%httpport%"=="0" set "args=!args! -RelayObfuscatePort "%httpport%""
powershell.exe -ExecutionPolicy Bypass -File "%~dp0Message.ps1" !args!
goto end

:connect
set /p address="Enter relay address (e.g., myserver.com:9999): "
set /p relaypass="Enter relay password (leave blank if none): "
set obfuscate=
set proxyaddr=
set httpport=
if not "%relaypass%"=="" (
    set /p obfuscate="Hide metadata (inbox IDs)? (y/n): "
    set /p proxyaddr="SOCKS5/HTTP proxy (e.g., 127.0.0.1:1080, blank=none): "
    set /p httpport="HTTP wrapper port (0 to disable): "
)
set args=-RelayAddress "%address%"
if not "%relaypass%"=="" set "args=!args! -RelayPassword "%relaypass%""
if /i "%obfuscate%"=="y" set "args=!args! -RelayObfuscate"
if not "%proxyaddr%"=="" set "args=!args! -RelayProxy "%proxyaddr%""
if not "%httpport%"=="" if not "%httpport%"=="0" set "args=!args! -RelayObfuscatePort "%httpport%""
powershell.exe -ExecutionPolicy Bypass -File "%~dp0Message.ps1" !args!
goto end

:registrysrv
set /p regport="Enter directory port (default 8080): "
if "%regport%"=="" set regport=8080
start "Directory Server" powershell.exe -ExecutionPolicy Bypass -File "%~dp0Registry.ps1" -Port "%regport%"
echo Directory server started on port %regport%.
echo Now start the chat with [1] and use -RegistryAddress http://localhost:%regport%
pause
goto end

:registrycon
set /p regaddr="Enter directory URL (e.g., http://myserver.com:8080): "
set /p relaypass="Enter relay password (leave blank if none): "
set obfuscate=
set proxyaddr=
set httpport=
if not "%relaypass%"=="" (
    set /p obfuscate="Hide metadata (inbox IDs)? (y/n): "
    set /p proxyaddr="SOCKS5/HTTP proxy (e.g., 127.0.0.1:1080, blank=none): "
    set /p httpport="HTTP wrapper port (0 to disable): "
)
setlocal enabledelayedexpansion
set args=-RegistryAddress "%regaddr%"
if not "%relaypass%"=="" set "args=!args! -RelayPassword "%relaypass%""
if /i "%obfuscate%"=="y" set "args=!args! -RelayObfuscate"
if not "%proxyaddr%"=="" set "args=!args! -RelayProxy "%proxyaddr%""
if not "%httpport%"=="" if not "%httpport%"=="0" set "args=!args! -RelayObfuscatePort "%httpport%""
set /p relayaddr="Enter relay address (optional, e.g., myserver.com:9999): "
if not "%relayaddr%"=="" set "args=!args! -RelayAddress "%relayaddr%""
powershell.exe -ExecutionPolicy Bypass -File "%~dp0Message.ps1" !args!
endlocal
goto end

:code
powershell.exe -ExecutionPolicy Bypass -File "%~dp0Message.ps1" -ShowCode
pause
goto end

:help
echo.
echo ========================================
echo          HELP / INFORMATION
echo ========================================
echo.
echo Your Code: Unique ID shown when app starts
echo.
echo To chat locally: Just run the app
echo To chat online: One person runs relay server
echo Others connect with -RelayAddress
echo.
echo === New Features in v2.1 ===
echo.
echo Forward Secrecy (FS):
echo   - ECDH-P521 ephemeral key exchange per message
echo   - Past messages safe if key compromised
echo   - Auto-exchanged when chatting with a friend
echo.
echo Message Signing:
echo   - All messages signed with RSA-2048 + SHA256
echo   - [V] = verified signature, [!] = failed
echo.
echo Rate Limiting:
echo   - Maximum 10 messages per second
echo   - Automatic queuing if exceeded
echo.
echo File Sharing:
echo   - Send any file through chat (auto-chunked)
echo   - Files saved to ~/.message_app/downloads/
echo   - Use in chat session with 'f' command
echo   - Or menu option 12 to send to a friend
echo.
echo Group Chats:
echo   - Menu option 11: Create/Join/Manage groups
echo   - Messages broadcast to all group members
echo   - Works over relay or P2P
echo.
echo History & Search:
echo   - Menu option 13: Search by text, code, date
echo   - 'h' command in chat session for history
echo   - All messages persisted in inbox.json
echo.
echo Relay Security:
echo   - Without password: open relay (plain TCP)
echo   - With password: TLS encrypted + password auth
echo   Same password on server and all clients
echo.
echo Optional Features (password required):
echo   - Hide Metadata: relay never sees sender/recipient codes
echo   - VPN/Proxy: connect via SOCKS5 or HTTP proxy
echo   - Port Obfuscation: wrap relay traffic as HTTP
echo.
echo Directory Server:
echo   [4] Start Directory: registers codes + relay addresses
echo   [5] Connect to Directory: auto-register on startup
echo   Directory helps peers find each other by code
echo.
echo Delivery Receipts:
echo   - [D] badge shows when recipient received your message
echo   - Works over P2P and Relay connections
echo.
echo Typing Indicator:
echo   - See when someone is typing a message
echo   - Automatic when you start typing in chat
echo.
echo Persistent Identity:
echo   - Your code is now tied to your machine (not IP)
echo   - Stays the same across reboots and network changes
echo.
echo Chat Export:
echo   - Menu option 19: Export full chat history with a friend
echo   - Saved to ~/.message_app/chat_export_*.txt
echo.
echo Example:
echo   Person A: launcher.bat [2] - Relay Server (set password)
echo   Person A: launcher.bat [4] - Directory Server
echo   Person B: launcher.bat [5] - Connect to directory, relay
echo   All traffic between them is TLS encrypted
echo.
pause
goto end

:end
endlocal