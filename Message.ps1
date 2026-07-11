param(
    [int]$ChatPort = 8888,
    [int]$DiscoveryPort = 8889,
    [int]$RelayPort = 0,
    [string]$RelayAddress = "",
    [string]$RelayPassword = "",
    [switch]$RelayObfuscate,
    [string]$RelayProxy = "",
    [int]$RelayObfuscatePort = 0,
    [string]$RegistryAddress = "",
    [int]$RegistryPort = 0,
    [switch]$ShowCode,
    [switch]$DisableSound
)

$DataDir = Join-Path $env:USERPROFILE ".message_app"
$FriendsFile = Join-Path $DataDir "friends.json"
$BlockedFile = Join-Path $DataDir "blocked.json"
$InboxFile = Join-Path $DataDir "inbox.json"
$PrivateKeyFile = Join-Path $DataDir "private.key"
$PublicKeyFile = Join-Path $DataDir "public.key"
$KnownKeysFile = Join-Path $DataDir "known_keys.json"
$RelayMsgsFile = Join-Path $DataDir "relay_inbox.json"
$RegistryFile = Join-Path $DataDir "registry.json"
$GroupsFile = Join-Path $DataDir "groups.json"
$ECDHKeyFile = Join-Path $DataDir "ecdh_private.key"
$ECDHPubFile = Join-Path $DataDir "ecdh_public.key"
$DownloadsDir = Join-Path $DataDir "downloads"
$SentFilesFile = Join-Path $DataDir "sent_files.json"
$IdentityFile = Join-Path $DataDir "identity.json"
$StatusFile = Join-Path $DataDir "status.json"

if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }
if (-not (Test-Path $DownloadsDir)) { New-Item -ItemType Directory -Path $DownloadsDir -Force | Out-Null }

function Load-Data {
    param([string]$Path)
    try {
        if (Test-Path $Path) {
            $content = Get-Content $Path -Raw -ErrorAction Stop
            if ($content) { return ($content | ConvertFrom-Json -ErrorAction Stop) }
        }
    } catch {}
    return @()
}

function Save-Data {
    param([string]$Path, $Data)
    $Data | ConvertTo-Json -Depth 10 | Set-Content $Path -Force -ErrorAction SilentlyContinue
}

$script:RateLimitTimes = @()
$script:PendingFileTransfer = @{}
$script:ChatKeyCache = @{}
$script:FileSendQueue = @{}

function Get-LocalIP {
    try {
        $ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
            $_.InterfaceAlias -notlike '*Loopback*' -and $_.IPAddress -notlike '127.*'
        } | Select-Object -First 1).IPAddress
        if (-not $ip) { $ip = "127.0.0.1" }
    } catch { $ip = "127.0.0.1" }
    return $ip
}

function Get-PersistentCode {
    $code = $null
    if (Test-Path $IdentityFile) {
        try { $idData = Get-Content $IdentityFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop; $code = $idData.Code } catch {}
    }
    if (-not $code) {
        $source = $null
        try {
            $sid = (Get-CimInstance Win32_UserAccount -Filter "Name='$env:USERNAME' AND Domain='$env:COMPUTERNAME'" -ErrorAction Stop).SID
            if ($sid) { $source = $sid }
        } catch {}
        if (-not $source) {
            try { $source = (Get-CimInstance Win32_ComputerSystemProduct -ErrorAction Stop).UUID } catch {}
        }
        if (-not $source) { $source = [System.Guid]::NewGuid().ToString() }
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        $hash = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($source))
        $sha256.Dispose()
        $id = -join ($hash[0..3] | ForEach-Object { $_.ToString("x2") })
        $code = ($id.Substring(0,4) + "-" + $id.Substring(4,4)).ToUpper()
        $identity = [PSCustomObject]@{ Code = $code; Created = (Get-Date -Format "yyyy-MM-dd HH:mm:ss") }
        $identity | ConvertTo-Json -Depth 5 | Set-Content $IdentityFile -Force -ErrorAction SilentlyContinue
    }
    return $code
}

if (-not (Test-Path $PrivateKeyFile)) {
    Write-Host "Generating RSA keys (2048-bit)..." -ForegroundColor DarkYellow
    $rsa = [System.Security.Cryptography.RSA]::Create(2048)
    Set-Content $PrivateKeyFile ($rsa.ToXmlString($true)) -Force
    Set-Content $PublicKeyFile ($rsa.ToXmlString($false)) -Force
    $rsa.Dispose()
}

if (-not (Test-Path $ECDHKeyFile)) {
    Write-Host "Generating ECDH keys (forward secrecy)..." -ForegroundColor DarkYellow
    $ecdh = New-Object System.Security.Cryptography.ECDiffieHellmanCng(521)
    $privBlob = $ecdh.Key.Export([System.Security.Cryptography.CngKeyBlobFormat]::EccPrivateBlob)
    $pubBlob = $ecdh.PublicKey.ToByteArray()
    Set-Content $ECDHKeyFile ([Convert]::ToBase64String($privBlob)) -Force
    Set-Content $ECDHPubFile ([Convert]::ToBase64String($pubBlob)) -Force
    $ecdh.Dispose()
}

$MyIP = Get-LocalIP
$MyCode = Get-PersistentCode
$MyPublicKey = Get-Content $PublicKeyFile -Raw
$MyPublicKeyB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($MyPublicKey))
$MyECDHPubKey = Get-Content $ECDHPubFile -Raw
$MyECDHPubKeyB64 = $MyECDHPubKey

if ($ShowCode) {
    Write-Host "Your Code: $MyCode" -ForegroundColor Green
    Write-Host "E2E: RSA-2048 + ECDH-P521 + AES-256" -ForegroundColor DarkYellow
    exit
}

$script:Friends = @(Load-Data $FriendsFile)
$script:Blocked = @(Load-Data $BlockedFile)
$script:IPCache = @{}
$script:KnownKeys = @(Load-Data $KnownKeysFile)
$script:Groups = @(Load-Data $GroupsFile)

$script:Friends = @($script:Friends | ForEach-Object {
    if ($_.PSObject.Properties.Name -contains "Code") { $_ }
    else { [PSCustomObject]@{ Code = "$_"; Name = "$_"; Added = (Get-Date -Format "yyyy-MM-dd") } }
})

# ========== CRYPTO FUNCTIONS ==========

function Get-PublicKeyForCode {
    param([string]$Code)
    $entry = $script:KnownKeys | Where-Object { $_.Code -eq $Code }
    if ($entry) { return $entry.PublicKey }
    return $null
}

function Get-ECDHKeyForCode {
    param([string]$Code)
    $entry = $script:KnownKeys | Where-Object { $_.Code -eq $Code }
    if ($entry -and $entry.PSObject.Properties.Name -contains "ECDHPubKey") {
        return $entry.ECDHPubKey
    }
    return $null
}

function Save-PublicKey {
    param([string]$Code, [string]$PublicKey)
    $existing = $script:KnownKeys | Where-Object { $_.Code -eq $Code }
    if ($existing) {
        if ($PublicKey -and (-not $existing.PublicKey -or $existing.PublicKey -ne $PublicKey)) {
            $existing.PublicKey = $PublicKey
            Save-Data $KnownKeysFile $script:KnownKeys
        }
    } else {
        $script:KnownKeys += [PSCustomObject]@{ Code = $Code; PublicKey = $PublicKey; ECDHPubKey = "" }
        Save-Data $KnownKeysFile $script:KnownKeys
    }
}

function Save-ECDHKey {
    param([string]$Code, [string]$ECDHPubKey)
    $existing = $script:KnownKeys | Where-Object { $_.Code -eq $Code }
    if ($existing) {
        $existing.ECDHPubKey = $ECDHPubKey
    } else {
        $script:KnownKeys += [PSCustomObject]@{ Code = $Code; PublicKey = ""; ECDHPubKey = $ECDHPubKey }
    }
    Save-Data $KnownKeysFile $script:KnownKeys
}

function Encrypt-For {
    param([string]$TargetCode, [string]$Message)
    $pubKey = Get-PublicKeyForCode $TargetCode
    if (-not $pubKey) { return $null }
    try {
        $rsa = [System.Security.Cryptography.RSA]::Create()
        $rsa.FromXmlString($pubKey)
        $aes = [System.Security.Cryptography.Aes]::Create()
        $aes.KeySize = 256
        $aes.GenerateKey()
        $aes.GenerateIV()
        $aesKey = $aes.Key
        $aesIV = $aes.IV
        $encryptor = $aes.CreateEncryptor()
        $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($Message)
        $cipherBytes = $encryptor.TransformFinalBlock($plainBytes, 0, $plainBytes.Length)
        $encKey = $rsa.Encrypt($aesKey, [System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA256)
        $rsa.Dispose()
        $aes.Dispose()
        return [PSCustomObject]@{
            EncKeyB64 = [Convert]::ToBase64String($encKey)
            IVB64     = [Convert]::ToBase64String($aesIV)
            CipherB64 = [Convert]::ToBase64String($cipherBytes)
        }
    } catch { return $null }
}

function Sign-Message {
    param([string]$Data)
    try {
        $rsa = [System.Security.Cryptography.RSA]::Create()
        $rsa.FromXmlString((Get-Content $PrivateKeyFile -Raw))
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Data)
        $sig = $rsa.SignData($bytes, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $rsa.Dispose()
        return [Convert]::ToBase64String($sig)
    } catch { return $null }
}

function Verify-Signature {
    param([string]$Data, [string]$SignatureB64, [string]$SenderCode)
    try {
        $pubKey = Get-PublicKeyForCode $SenderCode
        if (-not $pubKey) { return $false }
        $rsa = [System.Security.Cryptography.RSA]::Create()
        $rsa.FromXmlString($pubKey)
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Data)
        $sig = [Convert]::FromBase64String($SignatureB64)
        $ok = $rsa.VerifyData($bytes, $sig, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $rsa.Dispose()
        return $ok
    } catch { return $false }
}

function Encrypt-FS {
    param([string]$TargetCode, [string]$Message)
    $ecdhPubB64 = Get-ECDHKeyForCode $TargetCode
    if (-not $ecdhPubB64) { return $null }
    try {
        $pubBlob = [Convert]::FromBase64String($ecdhPubB64)
        $recipientCngKey = [System.Security.Cryptography.CngKey]::Import($pubBlob, [System.Security.Cryptography.CngKeyBlobFormat]::EccPublicBlob)
        $recipientEcdh = New-Object System.Security.Cryptography.ECDiffieHellmanCng($recipientCngKey)
        $ephEcdh = New-Object System.Security.Cryptography.ECDiffieHellmanCng(521)
        $aesKey = $ephEcdh.DeriveKeyMaterial($recipientEcdh.PublicKey)
        $ephPubBlob = $ephEcdh.PublicKey.ToByteArray()
        $ephEcdh.Dispose()
        $recipientEcdh.Dispose()
        $aes = [System.Security.Cryptography.Aes]::Create()
        $aes.KeySize = 256
        $aes.Key = $aesKey
        $aes.GenerateIV()
        $encryptor = $aes.CreateEncryptor()
        $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($Message)
        $cipherBytes = $encryptor.TransformFinalBlock($plainBytes, 0, $plainBytes.Length)
        $ivB64 = [Convert]::ToBase64String($aes.IV)
        $cipherB64 = [Convert]::ToBase64String($cipherBytes)
        $aes.Dispose()
        $ephPubKeyB64 = [Convert]::ToBase64String($ephPubBlob)
        $sigData = "$ephPubKeyB64|$ivB64|$cipherB64"
        $signature = Sign-Message $sigData
        return [PSCustomObject]@{
            EphPubKeyB64 = $ephPubKeyB64
            IVB64        = $ivB64
            CipherB64    = $cipherB64
            SignatureB64 = $signature
        }
    } catch { return $null }
}

function Decrypt-FS {
    param([string]$SenderCode, [string]$EphPubKeyB64, [string]$IVB64, [string]$CipherB64, [string]$SignatureB64)
    try {
        $sigData = "$EphPubKeyB64|$IVB64|$CipherB64"
        $verified = Verify-Signature $sigData $SignatureB64 $SenderCode
        $ephPubBlob = [Convert]::FromBase64String($EphPubKeyB64)
        $myPrivB64 = Get-Content $ECDHKeyFile -Raw
        $myPrivBlob = [Convert]::FromBase64String($myPrivB64)
        $myKey = [System.Security.Cryptography.CngKey]::Import($myPrivBlob, [System.Security.Cryptography.CngKeyBlobFormat]::EccPrivateBlob)
        $myEcdh = New-Object System.Security.Cryptography.ECDiffieHellmanCng($myKey)
        $ephKey = [System.Security.Cryptography.CngKey]::Import($ephPubBlob, [System.Security.Cryptography.CngKeyBlobFormat]::EccPublicBlob)
        $ephEcdh = New-Object System.Security.Cryptography.ECDiffieHellmanCng($ephKey)
        $aesKey = $myEcdh.DeriveKeyMaterial($ephEcdh.PublicKey)
        $myEcdh.Dispose()
        $ephEcdh.Dispose()
        $aes = [System.Security.Cryptography.Aes]::Create()
        $aes.KeySize = 256
        $aes.Key = $aesKey
        $aes.IV = [Convert]::FromBase64String($IVB64)
        $decryptor = $aes.CreateDecryptor()
        $plainBytes = $decryptor.TransformFinalBlock([Convert]::FromBase64String($CipherB64), 0, ([Convert]::FromBase64String($CipherB64)).Length)
        $aes.Dispose()
        $plainText = [System.Text.Encoding]::UTF8.GetString($plainBytes)
        return @{ Text = $plainText; Verified = $verified }
    } catch { return $null }
}

function Decrypt-Message {
    param([string]$EncKeyB64, [string]$IVB64, [string]$CipherB64)
    try {
        $rsa = [System.Security.Cryptography.RSA]::Create()
        $rsa.FromXmlString((Get-Content $PrivateKeyFile -Raw))
        $aesKey = $rsa.Decrypt([Convert]::FromBase64String($EncKeyB64), [System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA256)
        $rsa.Dispose()
        $aes = [System.Security.Cryptography.Aes]::Create()
        $aes.Key = $aesKey
        $aes.IV = [Convert]::FromBase64String($IVB64)
        $decryptor = $aes.CreateDecryptor()
        $plainBytes = $decryptor.TransformFinalBlock([Convert]::FromBase64String($CipherB64), 0, ([Convert]::FromBase64String($CipherB64)).Length)
        $aes.Dispose()
        return [System.Text.Encoding]::UTF8.GetString($plainBytes)
    } catch { return $null }
}

# ========== STATUS / BIO ==========

function Set-MyStatus {
    Write-Host "`n=== Your Status ===" -ForegroundColor Cyan
    Write-Host "Current: $(Get-MyStatus)" -ForegroundColor White
    $newStatus = Read-Host "Enter new status (or blank to clear)"
    if ($newStatus -eq "") {
        Remove-Item $StatusFile -Force -ErrorAction SilentlyContinue
        Write-Host "Status cleared." -ForegroundColor Green
    } else {
        $statusObj = [PSCustomObject]@{ Status = $newStatus; Updated = (Get-Date -Format "yyyy-MM-dd HH:mm:ss") }
        Save-Data $StatusFile $statusObj
        Write-Host "Status set!" -ForegroundColor Green
    }
}

function Get-MyStatus {
    $data = Load-Data $StatusFile
    if ($data -and $data.Status) { return $data.Status }
    return ""
}

function Get-StatusLine {
    $s = Get-MyStatus
    if ($s) { return "Status: $s" }
    return ""
}

# ========== RATE LIMITING ==========

function Check-RateLimit {
    $now = Get-Date
    $script:RateLimitTimes = @($script:RateLimitTimes | Where-Object { ($now - $_).TotalSeconds -lt 1 })
    if ($script:RateLimitTimes.Count -ge 10) {
        $sleepMs = 1000 - ($now - $script:RateLimitTimes[0]).TotalMilliseconds
        if ($sleepMs -gt 0) { Start-Sleep -Milliseconds $sleepMs }
        $now = Get-Date
        $script:RateLimitTimes = @($script:RateLimitTimes | Where-Object { ($now - $_).TotalSeconds -lt 1 })
    }
    $script:RateLimitTimes += $now
}

# ========== IMAGE PREVIEW ==========

function Get-ImageInfo {
    param([string]$FilePath)
    $ext = [System.IO.Path]::GetExtension($FilePath).ToLower()
    $imageExts = @(".png", ".jpg", ".jpeg", ".gif", ".bmp", ".webp", ".tiff")
    if ($imageExts -notcontains $ext) { return $null }
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
        $img = [System.Drawing.Image]::FromFile($FilePath)
        $w = $img.Width; $h = $img.Height
        $fmt = $img.RawFormat.ToString()
        $img.Dispose()
        $sizeKB = [math]::Round((Get-Item $FilePath).Length / 1KB, 1)
        return "[IMG ${w}x${h} $fmt ${sizeKB}KB]"
    } catch { return "[IMG file]" }
}

function Get-ImageInfoBytes {
    param([byte[]]$Data)
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
        $ms = New-Object System.IO.MemoryStream($Data)
        $img = [System.Drawing.Image]::FromStream($ms)
        $w = $img.Width; $h = $img.Height
        $fmt = $img.RawFormat.ToString()
        $img.Dispose(); $ms.Close()
        $sizeKB = [math]::Round($Data.Length / 1KB, 1)
        return "[IMG ${w}x${h} $fmt ${sizeKB}KB]"
    } catch { return null }
}

# ========== FILE SHARING ==========

function Send-File {
    param([string]$TargetCode, [string]$FilePath)
    if (-not (Test-Path $FilePath)) { return $false, "File not found" }
    try {
        $fileBytes = [System.IO.File]::ReadAllBytes($FilePath)
        $fileName = Split-Path $FilePath -Leaf
        $fileNameB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($fileName))
        $totalSize = $fileBytes.Length
        $maxChunkSize = 500KB
        $totalChunks = [math]::Ceiling($totalSize / $maxChunkSize)
        for ($i = 0; $i -lt $totalChunks; $i++) {
            $offset = $i * $maxChunkSize
            $chunkSize = [math]::Min($maxChunkSize, $totalSize - $offset)
            $chunkBytes = $fileBytes[$offset..($offset + $chunkSize - 1)]
            $chunkB64 = [Convert]::ToBase64String($chunkBytes)
            $meta = "FILE|$fileNameB64|$totalChunks|$i|$chunkB64"
            $chunkPayload = "2|$meta"
            $ok = Send-MessageRaw -TargetCode $TargetCode -Payload $chunkPayload
            if (-not $ok) { return $false, "Failed at chunk $i/$totalChunks" }
            $pct = [math]::Round(($i + 1) / $totalChunks * 100)
            Write-Host "  Sent chunk $($i+1)/$totalChunks ($pct%)" -ForegroundColor DarkGray
            Start-Sleep -Milliseconds 50
        }
        return $true, "File sent: $fileName ($totalChunks chunks)"
    } catch { return $false, "Error: $_" }
}

function Receive-FileChunk {
    param([string]$FromCode, [string]$FileNameB64, [int]$TotalChunks, [int]$ChunkIndex, [string]$ChunkB64)
    $fileName = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($FileNameB64))
    $key = "$FromCode`:$fileName"
    if (-not $script:PendingFileTransfer.ContainsKey($key)) {
        $script:PendingFileTransfer[$key] = @{
            FileName = $fileName
            FromCode = $FromCode
            TotalChunks = $TotalChunks
            Chunks = @{}
            Received = (Get-Date)
        }
    }
    $tf = $script:PendingFileTransfer[$key]
    $tf.Chunks[$ChunkIndex] = [Convert]::FromBase64String($ChunkB64)
    if ($tf.Chunks.Count -eq $TotalChunks) {
        $allData = New-Object byte[] 0
        for ($i = 0; $i -lt $TotalChunks; $i++) {
            if ($tf.Chunks.ContainsKey($i)) {
                $allData = $allData + $tf.Chunks[$i]
            }
        }
        $safeName = $tf.FileName -replace '[^\w\.\-]', '_'
        $savePath = Join-Path $DownloadsDir "$($tf.FromCode)_$safeName"
        try {
            [System.IO.File]::WriteAllBytes($savePath, $allData)
            $sizeKB = [math]::Round($allData.Length / 1KB, 1)
            $imgInfo = Get-ImageInfo -FilePath $savePath
            if ($imgInfo) { Write-Host "`n[IMAGE] $($tf.FileName) - $imgInfo" -ForegroundColor Cyan }
            Write-Host "`n[FILE RECEIVED] $($tf.FileName) ($sizeKB KB) saved to $savePath" -ForegroundColor Yellow
        } catch {
            Write-Host "`n[FILE ERROR] Failed to save: $_" -ForegroundColor Red
        }
        $script:PendingFileTransfer.Remove($key)
        return $true
    }
    return $false
}

# ========== MESSAGE SENDING (CORE) ==========

function Send-MessageRaw {
    param([string]$TargetCode, [string]$Payload)
    Check-RateLimit
    $ip = Discover-IP $TargetCode
    if ($ip) {
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $client.Connect($ip, $ChatPort)
            $client.ReceiveTimeout = 3000
            $stream = $client.GetStream()
            $writer = New-Object System.IO.StreamWriter($stream)
            $writer.WriteLine("$MyCode|$MyIP||$Payload")
            $writer.Flush()
            $writer.Close()
            $client.Close()
            return $true
        } catch { }
    }
    if ($script:RelayAddr) {
        return Relay-Send $TargetCode "" $Payload
    }
    $regRelay = Find-User $TargetCode
    if ($regRelay) {
        $savedAddr = $script:RelayAddr
        $savedPort = $script:RelayPortNum
        if ($regRelay -match '^(.+):(\d+)$') {
            $script:RelayAddr = $matches[1]
            $script:RelayPortNum = [int]$matches[2]
            $ok = Relay-Send $TargetCode "" $Payload
            $script:RelayAddr = $savedAddr
            $script:RelayPortNum = $savedPort
            if ($ok) { return $true }
        }
    }
    return $false
}

function Send-Message {
    param([string]$TargetCode, [string]$Message)
    $retryCount = 0
    do {
        Check-RateLimit
        $ecdhKey = Get-ECDHKeyForCode $TargetCode
        $payload = ""
        $sendPubKeyB64 = ""
        $usedFS = $false
        $usedEncryption = $false
        if ($ecdhKey) {
            $fsResult = Encrypt-FS $TargetCode $Message
            if ($fsResult) {
                $payload = "FS|$($fsResult.EphPubKeyB64)|$($fsResult.IVB64)|$($fsResult.CipherB64)|$($fsResult.SignatureB64)"
                $usedFS = $true; $usedEncryption = $true
            }
        }
        if (-not $usedFS) {
            $pubKey = Get-PublicKeyForCode $TargetCode
            if ($pubKey) {
                $encResult = Encrypt-For $TargetCode $Message
                if ($encResult) {
                    $sendPubKeyB64 = ""
                    $payload = "1|$($encResult.EncKeyB64)|$($encResult.IVB64)|$($encResult.CipherB64)"
                    $usedEncryption = $true
                } else {
                    $sendPubKeyB64 = $MyPublicKeyB64
                    $sig = Sign-Message $Message
                    $payload = "0|$Message|$sig"
                }
            } else {
                $sendPubKeyB64 = $MyPublicKeyB64
                $sig = Sign-Message $Message
                $payload = "0|$Message|$sig"
            }
        }
        $ip = Discover-IP $TargetCode
        if ($ip) {
            try {
                $client = New-Object System.Net.Sockets.TcpClient
                $client.Connect($ip, $ChatPort)
                $client.ReceiveTimeout = 3000
                $stream = $client.GetStream()
                $writer = New-Object System.IO.StreamWriter($stream)
                $writer.WriteLine("$MyCode|$MyIP|$sendPubKeyB64|$payload")
                $writer.Flush()
                $writer.Close()
                $client.Close()
                $label = if ($usedFS) { "Sent (P2P, FS)" } else { "Sent (P2P)" }
                Save-MySentMessage $TargetCode $Message $usedFS -Encrypted $usedEncryption
                return $true, $label
            } catch { }
        }
        if ($script:RelayAddr) {
            $ok = Relay-Send $TargetCode $sendPubKeyB64 $payload
            if ($ok) {
                $label = if ($usedFS) { "Sent (Relay, FS)" } else { "Sent (Relay)" }
                Save-MySentMessage $TargetCode $Message $usedFS -Encrypted $usedEncryption
                return $true, $label
            }
            if ($retryCount -eq 0) {
                Start-Sleep -Milliseconds 500
                $retryCount++
                continue
            }
            return $false, "User offline (relay)"
        }
        $regRelay = Find-User $TargetCode
        if ($regRelay) {
            $savedAddr = $script:RelayAddr
            $savedPort = $script:RelayPortNum
            if ($regRelay -match '^(.+):(\d+)$') {
                $script:RelayAddr = $matches[1]
                $script:RelayPortNum = [int]$matches[2]
                $ok = Relay-Send $TargetCode $sendPubKeyB64 $payload
                $script:RelayAddr = $savedAddr
                $script:RelayPortNum = $savedPort
                if ($ok) {
                    $label = if ($usedFS) { "Sent (Dir-Relay, FS)" } else { "Sent (Dir-Relay)" }
                    Save-MySentMessage $TargetCode $Message $usedFS -Encrypted $usedEncryption
                    return $true, $label
                }
            }
        }
        if ($retryCount -eq 0) {
            Start-Sleep -Milliseconds 500
            $retryCount++
            continue
        }
        return $false, "User not found"
    } while ($retryCount -le 1)
    return $false, "User not found"
}

function Save-MySentMessage {
    param([string]$TargetCode, [string]$Message, [bool]$FS, [bool]$Encrypted = $true)
    $now = Get-Date
    $msgObj = [PSCustomObject]@{
        FromCode = $MyCode; ToCode = $TargetCode; Text = $Message
        IsEncrypted = $Encrypted; IsFS = $FS; IsSent = $true
        Date = $now.ToString("yyyy-MM-dd"); Time = $now.ToString("HH:mm:ss"); Read = $true; Acked = $false
    }
    $inbox = @(Load-Data $InboxFile)
    $inbox += $msgObj
    Save-Data $InboxFile $inbox
}

function Send-ECDHKeyExchange {
    param([string]$TargetCode)
    $payload = "KX|$MyECDHPubKeyB64"
    $sendPubKeyB64 = $MyPublicKeyB64
    $ip = Discover-IP $TargetCode
    if ($ip) {
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $client.Connect($ip, $ChatPort)
            $client.ReceiveTimeout = 3000
            $stream = $client.GetStream()
            $writer = New-Object System.IO.StreamWriter($stream)
            $writer.WriteLine("$MyCode|$MyIP|$sendPubKeyB64|$payload")
            $writer.Flush()
            $writer.Close()
            $client.Close()
            return $true
        } catch { }
    }
    if ($script:RelayAddr) {
        return Relay-Send $TargetCode $sendPubKeyB64 $payload
    }
    return $false
}

# ========== GROUP CHATS ==========

function Load-Groups {
    $script:Groups = @(Load-Data $GroupsFile)
}

function Save-Groups {
    Save-Data $GroupsFile $script:Groups
}

function Create-Group {
    param([string]$GroupName)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $idBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("$GroupName`:$MyCode`:$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"))
    $sha.Dispose()
    $groupId = -join ($idBytes[0..3] | ForEach-Object { $_.ToString("x2") })
    $group = [PSCustomObject]@{
        ID = $groupId
        Name = $GroupName
        Members = @($MyCode)
        Owner = $MyCode
        Created = (Get-Date -Format "yyyy-MM-dd HH:mm")
    }
    $script:Groups += $group
    Save-Groups
    return $group
}

function Group-SendMessage {
    param([string]$GroupID, [string]$Message)
    $group = $script:Groups | Where-Object { $_.ID -eq $GroupID }
    if (-not $group) { return $false, "Group not found" }
    $sent = 0
    $failed = 0
    foreach ($member in $group.Members) {
        if ($member -eq $MyCode) { continue }
        $ok, $result = Send-Message -TargetCode $member -Message "[Group: $($group.Name)] $Message"
        if ($ok) { $sent++ } else { $failed++ }
    }
    if ($sent -gt 0) {
        $now = Get-Date
            $msgObj = [PSCustomObject]@{
                FromCode = $MyCode; ToCode = $GroupID; Text = $Message
                IsEncrypted = $true; IsGroup = $true; GroupID = $GroupID; GroupName = $group.Name
                Date = $now.ToString("yyyy-MM-dd"); Time = $now.ToString("HH:mm:ss"); Read = $true; IsSent = $true; Acked = $false
            }
        $inbox = @(Load-Data $InboxFile)
        $inbox += $msgObj
        Save-Data $InboxFile $inbox
    }
    return $true, "Group: sent to $sent member(s), $failed failed"
}

function Add-GroupMember {
    param([string]$GroupID, [string]$MemberCode)
    $group = $script:Groups | Where-Object { $_.ID -eq $GroupID }
    if (-not $group) { return $false, "Group not found" }
    if ($group.Members -contains $MemberCode) { return $false, "Already a member" }
    $group.Members += $MemberCode
    Save-Groups
    return $true, "$MemberCode added to $($group.Name)"
}

function Remove-GroupMember {
    param([string]$GroupID, [string]$MemberCode)
    $group = $script:Groups | Where-Object { $_.ID -eq $GroupID }
    if (-not $group) { return $false, "Group not found" }
    $group.Members = @($group.Members | Where-Object { $_ -ne $MemberCode })
    Save-Groups
    return $true, "$MemberCode removed from $($group.Name)"
}

# ========== MESSAGE HISTORY & SEARCH ==========

function Search-Messages {
    param([string]$Query, [string]$FromCode, [string]$StartDate, [string]$EndDate)
    $inbox = @(Load-Data $InboxFile)
    $results = $inbox
    if ($Query) {
        $escaped = [regex]::Escape($Query)
        $results = @($results | Where-Object { $_.Text -match $escaped })
    }
    if ($FromCode) {
        $results = @($results | Where-Object { $_.FromCode -eq $FromCode -or $_.ToCode -eq $FromCode })
    }
    if ($StartDate) {
        $results = @($results | Where-Object { $_.Date -ge $StartDate })
    }
    if ($EndDate) {
        $results = @($results | Where-Object { $_.Date -le $EndDate })
    }
    return $results
}

function Show-History {
    param([string]$TargetCode)
    $inbox = @(Load-Data $InboxFile)
    $msgs = @($inbox | Where-Object {
        ($_.FromCode -eq $TargetCode -and $_.ToCode -eq $MyCode) -or ($_.FromCode -eq $MyCode -and $_.ToCode -eq $TargetCode)
    })
    if ($msgs.Count -eq 0) { return $false }
    $msgs = $msgs | Sort-Object { "$($_.Date) $($_.Time)" }
    Write-Host "`n=== History ===" -ForegroundColor Cyan
    foreach ($m in $msgs) {
        $who = if ($m.FromCode -eq $MyCode -or $m.IsSent) { "You" } else { $m.FromCode }
        $fsTag = if ($m.IsFS) { "[FS] " } else { "" }
        $encTag = if ($m.IsEncrypted -and -not $m.IsFS) { "[E] " } else { "" }
        Write-Host "[$($m.Date) $($m.Time)] ${encTag}${fsTag}$who : $($m.Text)" -ForegroundColor White
    }
    return $true
}

# ========== TCP LISTENER (background job) ==========

$tcpListenerScript = {
    param($ChatPort, $InboxFile, $BlockedFile, $PrivateKeyFile, $KnownKeysFile, $MyCode, $ECDHKeyFile, $DownloadsDir, $DisableSound)
    $script:MyCode = $MyCode
    $script:ChatPort = $ChatPort

    function Load-JData {
        param([string]$Path)
        try {
            if (Test-Path $Path) {
                $c = Get-Content $Path -Raw -ErrorAction Stop
                if ($c) { return ($c | ConvertFrom-Json -ErrorAction Stop) }
            }
        } catch {}
        return @()
    }

    function Save-JData {
        param([string]$Path, $Data)
        $Data | ConvertTo-Json -Depth 10 | Set-Content $Path -Force -ErrorAction SilentlyContinue
    }

    function Get-ImageInfo {
        param([string]$FilePath)
        $ext = [System.IO.Path]::GetExtension($FilePath).ToLower()
        $imageExts = @(".png", ".jpg", ".jpeg", ".gif", ".bmp", ".webp", ".tiff")
        if ($imageExts -notcontains $ext) { return $null }
        try {
            Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
            $img = [System.Drawing.Image]::FromFile($FilePath)
            $w = $img.Width; $h = $img.Height
            $fmt = $img.RawFormat.ToString()
            $img.Dispose()
            $sizeKB = [math]::Round((Get-Item $FilePath).Length / 1KB, 1)
            return "[IMG ${w}x${h} $fmt ${sizeKB}KB]"
        } catch { return "[IMG file]" }
    }

    function Decrypt-Incoming {
        param([string]$EncKeyB64, [string]$IVB64, [string]$CipherB64)
        try {
            $rsa = [System.Security.Cryptography.RSA]::Create()
            $rsa.FromXmlString((Get-Content $PrivateKeyFile -Raw))
            $aesKey = $rsa.Decrypt([Convert]::FromBase64String($EncKeyB64), [System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA256)
            $rsa.Dispose()
            $aes = [System.Security.Cryptography.Aes]::Create()
            $aes.Key = $aesKey
            $aes.IV = [Convert]::FromBase64String($IVB64)
            $d = $aes.CreateDecryptor()
            $p = $d.TransformFinalBlock([Convert]::FromBase64String($CipherB64), 0, ([Convert]::FromBase64String($CipherB64)).Length)
            $aes.Dispose()
            return [System.Text.Encoding]::UTF8.GetString($p)
        } catch { return $null }
    }

    function Save-KnownKey {
        param([string]$Code, [string]$PubKey)
        $keys = @(Load-JData $KnownKeysFile)
        $existing = $keys | Where-Object { $_.Code -eq $Code }
        if ($existing) {
            if ($PubKey -and (-not $existing.PublicKey -or $existing.PublicKey -ne $PubKey)) {
                $existing.PublicKey = $PubKey
                Save-JData $KnownKeysFile $keys
            }
        } else {
            $keys += [PSCustomObject]@{ Code = $Code; PublicKey = $PubKey; ECDHPubKey = "" }
            Save-JData $KnownKeysFile $keys
        }
    }

    function Save-ECDHKey {
        param([string]$Code, [string]$ECDHPubKey)
        $keys = @(Load-JData $KnownKeysFile)
        $existing = $keys | Where-Object { $_.Code -eq $Code }
        if ($existing) {
            $existing.ECDHPubKey = $ECDHPubKey
        } else {
            $keys += [PSCustomObject]@{ Code = $Code; PublicKey = ""; ECDHPubKey = $ECDHPubKey }
        }
        Save-JData $KnownKeysFile $keys
    }

    function Verify-Signature {
        param([string]$Data, [string]$SignatureB64, [string]$SenderCode)
        try {
            $keys = @(Load-JData $KnownKeysFile)
            $entry = $keys | Where-Object { $_.Code -eq $SenderCode }
            if (-not $entry -or -not $entry.PublicKey) { return $false }
            $pubKey = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($entry.PublicKey))
            $rsa = [System.Security.Cryptography.RSA]::Create()
            $rsa.FromXmlString($pubKey)
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($Data)
            $sig = [Convert]::FromBase64String($SignatureB64)
            $ok = $rsa.VerifyData($bytes, $sig, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
            $rsa.Dispose()
            return $ok
        } catch { return $false }
    }

    function Decrypt-FS {
        param([string]$SenderCode, [string]$EphPubKeyB64, [string]$IVB64, [string]$CipherB64, [string]$SignatureB64)
        try {
            $sigData = "$EphPubKeyB64|$IVB64|$CipherB64"
            $verified = Verify-Signature $sigData $SignatureB64 $SenderCode
            $ephPubBlob = [Convert]::FromBase64String($EphPubKeyB64)
            $myPrivB64 = Get-Content $ECDHKeyFile -Raw
            $myPrivBlob = [Convert]::FromBase64String($myPrivB64)
            $myKey = [System.Security.Cryptography.CngKey]::Import($myPrivBlob, [System.Security.Cryptography.CngKeyBlobFormat]::EccPrivateBlob)
            $myEcdh = New-Object System.Security.Cryptography.ECDiffieHellmanCng($myKey)
            $ephKey = [System.Security.Cryptography.CngKey]::Import($ephPubBlob, [System.Security.Cryptography.CngKeyBlobFormat]::EccPublicBlob)
            $ephEcdh = New-Object System.Security.Cryptography.ECDiffieHellmanCng($ephKey)
            $aesKey = $myEcdh.DeriveKeyMaterial($ephEcdh.PublicKey)
            $myEcdh.Dispose()
            $ephEcdh.Dispose()
            $aes = [System.Security.Cryptography.Aes]::Create()
            $aes.KeySize = 256
            $aes.Key = $aesKey
            $aes.IV = [Convert]::FromBase64String($IVB64)
            $decryptor = $aes.CreateDecryptor()
            $plainBytes = $decryptor.TransformFinalBlock([Convert]::FromBase64String($CipherB64), 0, ([Convert]::FromBase64String($CipherB64)).Length)
            $aes.Dispose()
            $plainText = [System.Text.Encoding]::UTF8.GetString($plainBytes)
            return @{ Text = $plainText; Verified = $verified }
        } catch { return $null }
    }

    function Receive-FileChunk {
        param([string]$FromCode, [string]$FileNameB64, [int]$TotalChunks, [int]$ChunkIndex, [string]$ChunkB64, [string]$DownloadsDir)
        $fileName = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($FileNameB64))
        $key = "$FromCode`:$fileName"
        if (-not $script:PendingFileTransfer.ContainsKey($key)) {
            $script:PendingFileTransfer[$key] = @{
                FileName = $fileName
                FromCode = $FromCode
                TotalChunks = $TotalChunks
                Chunks = @{}
                Received = (Get-Date)
            }
        }
        $tf = $script:PendingFileTransfer[$key]
        $tf.Chunks[$ChunkIndex] = [Convert]::FromBase64String($ChunkB64)
        if ($tf.Chunks.Count -eq $TotalChunks) {
            $allData = New-Object byte[] 0
            for ($i = 0; $i -lt $TotalChunks; $i++) {
                if ($tf.Chunks.ContainsKey($i)) {
                    $allData = $allData + $tf.Chunks[$i]
                }
            }
            $safeName = $tf.FileName -replace '[^\w\.\-]', '_'
            $savePath = Join-Path $DownloadsDir "$($tf.FromCode)_$safeName"
            try {
                [System.IO.File]::WriteAllBytes($savePath, $allData)
                $imgInfo = Get-ImageInfo -FilePath $savePath
                if ($imgInfo) { Write-Host "`n[IMAGE] $($tf.FileName) - $imgInfo" -ForegroundColor Cyan }
                Write-Host "`n[FILE] Received: $($tf.FileName) -> $savePath" -ForegroundColor Yellow
            } catch {
                Write-Host "`n[FILE ERROR] $_" -ForegroundColor Red
            }
            $script:PendingFileTransfer.Remove($key)
            return $true
        }
        return $false
    }

    $script:PendingFileTransfer = @{}
    $script:VoiceChunks = @{}

    function Receive-VoiceChunk {
        param([string]$FromCode, [string]$FileNameB64, [int]$TotalChunks, [int]$ChunkIndex, [string]$ChunkB64, [int]$Duration)
        $key = "$FromCode`_voice"
        if (-not $script:VoiceChunks.ContainsKey($key)) {
            $script:VoiceChunks[$key] = @{ Chunks = @{}; Total = $TotalChunks; Duration = $Duration }
        }
        $vb = $script:VoiceChunks[$key]
        $vb.Chunks[$ChunkIndex] = [Convert]::FromBase64String($ChunkB64)
        if ($vb.Chunks.Count -eq $TotalChunks) {
            $allData = New-Object byte[] 0
            for ($i = 0; $i -lt $TotalChunks; $i++) { if ($vb.Chunks.ContainsKey($i)) { $allData = $allData + $vb.Chunks[$i] } }
            $script:VoiceChunks.Remove($key)
            $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) "voice_note_$FromCode.wav"
            try { [System.IO.File]::WriteAllBytes($tempFile, $allData); Write-Host "`n[VOICE] $($vb.Duration)sec from $FromCode saved to $tempFile" -ForegroundColor Magenta } catch {}
            return $allData
        }
        return $null
    }

    try {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $ChatPort)
        $listener.Start()
        while ($true) {
            try {
                $client = $listener.AcceptTcpClient()
                $stream = $client.GetStream()
                $reader = New-Object System.IO.StreamReader($stream)
                $raw = $reader.ReadLine()
                if ($raw) {
                    $parts = $raw -split '\|', 5
                    if ($parts.Count -ge 4) {
                        $senderCode = $parts[0]
                        $senderIP = $parts[1]
                        $pubKeyB64 = $parts[2]
                        $type = $parts[3]
                        $content = if ($parts.Count -ge 5) { $parts[4] } else { "" }
                        if ($pubKeyB64) {
                            try {
                                $decodedKey = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($pubKeyB64))
                                Save-KnownKey $senderCode $decodedKey
                            } catch {}
                        }
                        $blocked = @(Load-JData $BlockedFile)
                        $isBlocked = $blocked -contains $senderCode
                        if (-not $isBlocked) {
                            $displayMsg = ""
                            $isEncrypted = $false
                            $isFS = $false
                            $isVerified = $false
                            $isFile = $false
                            $isVoice = $false
                            $isKeyEx = $false
                            $tag = ""

                            if ($type -eq "TYP" -and $content) {
                                $friendName = $senderCode
                                $fEntry = @(Load-JData $KnownKeysFile) | Where-Object { $_.Code -eq $senderCode }
                                Write-Host "`n[TYPING] $senderCode is typing..." -ForegroundColor DarkYellow
                                Write-Host -NoNewline "> " -ForegroundColor Green
                                continue
                            } elseif ($type -eq "ACK" -and $content) {
                                $ackedCode = $content
                                $inboxAck = @(Load-JData $InboxFile)
                                $updated = $false
                                for ($ai = $inboxAck.Count - 1; $ai -ge 0; $ai--) {
                                    if ($inboxAck[$ai].ToCode -eq $ackedCode -and $inboxAck[$ai].IsSent -and -not $inboxAck[$ai].Acked) {
                                        $inboxAck[$ai].Acked = $true
                                        Write-Host "`n[DELIVERED] $ackedCode received your message" -ForegroundColor Green
                                        Write-Host -NoNewline "> " -ForegroundColor Green
                                        $updated = $true
                                        break
                                    }
                                }
                                if ($updated) { Save-JData $InboxFile $inboxAck }
                                continue
                            } elseif ($type -eq "KX" -and $content) {
                                $isKeyEx = $true
                                try {
                                    Save-ECDHKey $senderCode $content
                                    Write-Host "`n[KEY EX] ECDH key received from $senderCode" -ForegroundColor Green
                                } catch {}
                            } elseif ($type -eq "FS" -and $content -match '^([A-Za-z0-9+/=]+)\|([A-Za-z0-9+/=]+)\|([A-Za-z0-9+/=]+)\|([A-Za-z0-9+/=]+)$') {
                                $fsResult = Decrypt-FS $senderCode $matches[1] $matches[2] $matches[3] $matches[4]
                                if ($fsResult) {
                                    $displayMsg = $fsResult.Text
                                    $isEncrypted = $true
                                    $isFS = $true
                                    $isVerified = $fsResult.Verified
                                    $tag = "[FS]"
                                    if ($isVerified) { $tag += "[V] " } else { $tag += "[!] " }
                                } else {
                                    $displayMsg = "[Decryption failed]"
                                    $tag = "[FS ERR] "
                                }
                            } elseif ($type -eq "1" -and $content -match '^([A-Za-z0-9+/=]+)\|([A-Za-z0-9+/=]+)\|([A-Za-z0-9+/=]+)$') {
                                $decrypted = Decrypt-Incoming $matches[1] $matches[2] $matches[3]
                                if ($decrypted) { $displayMsg = $decrypted; $isEncrypted = $true; $tag = "[E] " }
                                else { $displayMsg = "[Decryption failed]"; $tag = "[ERR] " }
                            } elseif ($type -eq "2" -and $content -match '^FILE\|(.+)\|(\d+)\|(\d+)\|(.+)$') {
                                $isFile = $true
                                $fileNameB64 = $matches[1]
                                $totalChunks = [int]$matches[2]
                                $chunkIndex = [int]$matches[3]
                                $chunkB64 = $matches[4]
                                Receive-FileChunk $senderCode $fileNameB64 $totalChunks $chunkIndex $chunkB64 $DownloadsDir | Out-Null
                                $displayMsg = "[File chunk $($chunkIndex+1)/$totalChunks]"
                                $tag = "[FILE] "
                            } elseif ($type -eq "VN" -and $content -match '^(\d+)\|(.+)\|(\d+)\|(\d+)\|(.+)$') {
                                $voiceDuration = [int]$matches[1]
                                $voiceNameB64 = $matches[2]
                                $voiceTotal = [int]$matches[3]
                                $voiceIdx = [int]$matches[4]
                                $voiceB64 = $matches[5]
                                $isVoice = $true
                                Receive-VoiceChunk $senderCode $voiceNameB64 $voiceTotal $voiceIdx $voiceB64 $voiceDuration | Out-Null
                                $displayMsg = "[Voice $($voiceDuration)sec chunk $($voiceIdx+1)/$voiceTotal]"
                                $tag = "[VN] "
                            } elseif ($type -eq "0") {
                                $parts0 = $content -split '\|', 2
                                $displayMsg = $parts0[0]
                                if ($parts0.Count -ge 2 -and $parts0[1]) {
                                    $verified = Verify-Signature $parts0[0] $parts0[1] $senderCode
                                    $isVerified = $verified
                                    if ($verified) { $tag = "[V] " } else { $tag = "[!] " }
                                }
                            } else { $displayMsg = $content }

                            if (-not $isFile -and -not $isKeyEx) {
                                $now = Get-Date
                                $msgObj = [PSCustomObject]@{
                                    FromCode = $senderCode; FromIP = $senderIP; Text = $displayMsg
                                    IsEncrypted = $isEncrypted; IsFS = $isFS; IsVerified = $isVerified
                                    Date = $now.ToString("yyyy-MM-dd"); Time = $now.ToString("HH:mm:ss"); Read = $false
                                    IsGroup = $false; IsSent = $false; IsFile = $isFile; IsVoice = $isVoice; Acked = $false
                                }
                                $inbox = @(Load-JData $InboxFile)
                                $inbox += $msgObj
                                Save-JData $InboxFile $inbox
                                if ($displayMsg) {
                                    if (-not $DisableSound) { [System.Console]::Beep(600, 120) }
                                    Write-Host "`n${tag}$senderCode : $displayMsg" -ForegroundColor Cyan
                                    Write-Host -NoNewline "> " -ForegroundColor Green
                                }
                                try {
                                    $ackClient = New-Object System.Net.Sockets.TcpClient
                                    $ackClient.Connect($senderIP, $script:ChatPort)
                                    $ackStream = $ackClient.GetStream()
                                    $ackWriter = New-Object System.IO.StreamWriter($ackStream)
                                    $ackWriter.WriteLine("$script:MyCode|$senderIP||ACK|$senderCode")
                                    $ackWriter.Flush()
                                    $ackWriter.Close()
                                    $ackClient.Close()
                                } catch {}
                            }
                        }
                    }
                }
                $reader.Close()
                $client.Close()
            } catch { Start-Sleep -Milliseconds 100 }
        }
    } catch { Write-Host "`n[!] TCP Listener error: $_" -ForegroundColor Red }
}

$udpListenerScript = {
    param($DiscoveryPort, $MyCode, $MyIP, $MyPublicKeyB64)
    try {
        $udp = New-Object System.Net.Sockets.UdpClient($DiscoveryPort)
        $udp.Client.ReceiveTimeout = 1000
        while ($true) {
            try {
                $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
                $data = $udp.Receive([ref]$remote)
                $msg = [System.Text.Encoding]::UTF8.GetString($data)
                if ($msg) {
                    $parts = $msg -split '\|', 3
                    if ($parts.Count -ge 3 -and $parts[0] -eq "FIND") {
                        if ($parts[2] -eq $MyCode) {
                            $response = "HERE|$MyCode|$MyIP|$MyPublicKeyB64"
                            $respBytes = [System.Text.Encoding]::UTF8.GetBytes($response)
                            $respondEP = New-Object System.Net.IPEndPoint($remote.Address, $remote.Port)
                            $udp.Send($respBytes, $respBytes.Length, $respondEP) | Out-Null
                        }
                    }
                }
            } catch { Start-Sleep -Milliseconds 100 }
        }
    } catch { Write-Host "`n[!] UDP Listener error: $_" -ForegroundColor Red }
}

function Get-InboxID {
    param([string]$Code, [string]$Password)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes("$Code`:$Password")
    $hash = $sha.ComputeHash($bytes)
    $sha.Dispose()
    return -join ($hash[0..7] | ForEach-Object { $_.ToString("x2") })
}

function Register-User {
    if (-not $RegistryAddress) { return $false }
    try {
        $relayAddr = if ($script:RelayAddr) { "$($script:RelayAddr):$($script:RelayPortNum)" } else { "" }
        $body = @{
            Code = $MyCode
            PublicKey = $MyPublicKeyB64
            RelayAddress = $relayAddr
            DirectAddress = "$MyIP`:$ChatPort"
            IP = $MyIP
        } | ConvertTo-Json
        $result = Invoke-RestMethod -Uri "$RegistryAddress/register" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 5
        return ($result.status -eq "ok")
    } catch { return $false }
}

function Find-User {
    param([string]$Code)
    if (-not $RegistryAddress) { return $null }
    try {
        $result = Invoke-RestMethod -Uri "$RegistryAddress/find?code=$Code" -Method Get -TimeoutSec 5
        if ($result.status -eq "not_found") { return $null }
        $pubKeyB64 = $result.PublicKey
        if ($pubKeyB64) { try { Save-PublicKey $Code ([System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($pubKeyB64))) } catch {} }
        if ($result.RelayAddress) { return $result.RelayAddress }
        if ($result.IP) { return "$($result.IP):$ChatPort" }
        return $null
    } catch { return $null }
}

function Connect-viaProxy {
    param([string]$Proxy, [string]$TargetHost, [int]$TargetPort)
    $parts = $Proxy -split '://', 2
    $proto = $parts[0].ToLower()
    $addrParts = $parts[1] -split ':', 2
    $proxyHost = $addrParts[0]
    $proxyPort = [int]$addrParts[1]
    $tcp = New-Object System.Net.Sockets.TcpClient
    $tcp.Connect($proxyHost, $proxyPort)
    $ns = $tcp.GetStream()
    if ($proto -eq "socks5") {
        $ns.Write([byte[]]@(5,1,0),0,3)
        $rb = New-Object byte[] 2; $ns.Read($rb,0,2)
        $ab = [System.Text.Encoding]::UTF8.GetBytes($TargetHost)
        $pb = [BitConverter]::GetBytes([uint16]$TargetPort)
        if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($pb) }
        $req = [byte[]]@(5,1,0,3,[byte]$ab.Length) + $ab + $pb
        $ns.Write($req,0,$req.Length)
        $rb = New-Object byte[] 10; $ns.Read($rb,0,10)
    } elseif ($proto -eq "http") {
        $w = New-Object System.IO.StreamWriter($ns)
        $r = New-Object System.IO.StreamReader($ns)
        $w.WriteLine("CONNECT $TargetHost`:$TargetPort HTTP/1.1")
        $w.WriteLine("Host: $TargetHost`:$TargetPort")
        $w.WriteLine(""); $w.Flush()
        do { $resp = $r.ReadLine() } while ($resp -eq "" -or $resp -match '^HTTP/1.[01] 1\d{2}')
        if ($resp -notmatch '^HTTP/1.[01] 2\d{2}') { $tcp.Close(); return $null }
        while ($r.ReadLine() -ne "") { }
    }
    return $tcp
}

function Wrap-Http {
    param([string]$Body)
    $b = [System.Text.Encoding]::UTF8.GetBytes($Body)
    return "POST /relay HTTP/1.1`r`nHost: relay`r`nContent-Length: $($b.Length)`r`nContent-Type: application/octet-stream`r`n`r`n$Body"
}

function Unwrap-Http {
    param([string]$Raw)
    $idx = $Raw.IndexOf("`r`n`r`n")
    if ($idx -ge 0) { return $Raw.Substring($idx + 4) }
    $idx = $Raw.IndexOf("`n`n")
    if ($idx -ge 0) { return $Raw.Substring($idx + 2) }
    return $Raw
}

$relayServerScript = {
    param($RelayPort, $RelayMsgsFile, $RelayPassword, $DataDir)
    function Save-RData {
        param([string]$Path, $Data)
        $Data | ConvertTo-Json -Depth 10 | Set-Content $Path -Force -ErrorAction SilentlyContinue
    }
    function Load-RData {
        param([string]$Path)
        try {
            if (Test-Path $Path) { $c = Get-Content $Path -Raw -ErrorAction Stop; if ($c) { return ($c | ConvertFrom-Json -ErrorAction Stop) } }
        } catch {}
        return @{}
    }
    $hasAuth = $RelayPassword -ne ""
    $cert = $null
    if ($hasAuth) {
        $certPath = Join-Path $DataDir "relay_cert.pfx"
        $rsaGen = [System.Security.Cryptography.RSA]::Create(4096)
        $dn = New-Object System.Security.Cryptography.X509Certificates.X500DistinguishedName("CN=MessageAppRelay")
        try {
            if (Test-Path $certPath) { $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($certPath, $RelayPassword) }
            if (-not $cert) {
                $req = New-Object System.Security.Cryptography.X509Certificates.CertificateRequest($dn, $rsaGen, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
                $cert = $req.CreateSelfSigned([DateTimeOffset]::Now, [DateTimeOffset]::Now.AddYears(10))
                $bytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $RelayPassword)
                Set-Content $certPath -Value $bytes -Encoding Byte -Force
            }
        } catch { Write-Host "TLS cert generation failed: $_" -ForegroundColor Red }
    }
    try {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $RelayPort)
        $listener.Start()
        $mode = if ($hasAuth) { " (TLS + password)" } else { " (open)" }
        Write-Host "Relay server running on port $RelayPort$mode" -ForegroundColor Green
        while ($true) {
            try {
                $client = $listener.AcceptTcpClient()
                $ns = $client.GetStream()
                if ($hasAuth -and $cert) {
                    $ssl = New-Object System.Net.Security.SslStream($ns, $false)
                    $ssl.AuthenticateAsServer($cert, $false, [System.Security.Authentication.SslProtocols]::Tls12, $false)
                    $ns = $ssl
                }
                $reader = New-Object System.IO.StreamReader($ns)
                $writer = New-Object System.IO.StreamWriter($ns)
                $raw = $reader.ReadToEnd()
                if (-not $raw) { $reader.Close(); $writer.Close(); $client.Close(); continue }
                $isHttp = $raw -match '^(POST|GET|PUT) '
                if ($isHttp) { $raw = (Unwrap-Http $raw) }
                $lines = $raw -split "`n" | ForEach-Object { $_.Trim("`r") }
                $authenticated = !$hasAuth
                foreach ($line in $lines) {
                    if (-not $line) { continue }
                    $resp = ""
                    if ($hasAuth -and $line -match '^AUTH\|(.+)$') {
                        if ($matches[1] -eq $RelayPassword) { $authenticated = $true; $resp = "AUTH_OK" }
                        else { $resp = "AUTH_FAIL" }
                    } elseif ($authenticated -and $line -match '^SEND\|(.+)\|(.+)\|(.*)\|(.+)$') {
                        $toCode = $matches[2]; $pubKey = $matches[3]; $payload = $matches[4]
                        $msgs = @(Load-RData $RelayMsgsFile)
                        if (-not $msgs.ContainsKey($toCode)) { $msgs[$toCode] = @() }
                        $msgs[$toCode] += @{ From = $matches[1]; PubKey = $pubKey; Payload = $payload; Time = (Get-Date).ToString("o") }
                        if ($msgs[$toCode].Count -gt 1000) { $msgs[$toCode] = $msgs[$toCode][-1000..-1] }
                        Save-RData $RelayMsgsFile $msgs; $resp = "OK"
                    } elseif ($authenticated -and $line -match '^SENDI\|(.+)\|(.+)\|(.*)\|(.+)$') {
                        $toInbox = $matches[1]; $fromInbox = $matches[2]; $pubKey = $matches[3]; $payload = $matches[4]
                        $msgs = @(Load-RData $RelayMsgsFile)
                        if (-not $msgs.ContainsKey($toInbox)) { $msgs[$toInbox] = @() }
                        $msgs[$toInbox] += @{ From = $fromInbox; PubKey = $pubKey; Payload = $payload; Time = (Get-Date).ToString("o") }
                        if ($msgs[$toInbox].Count -gt 1000) { $msgs[$toInbox] = $msgs[$toInbox][-1000..-1] }
                        Save-RData $RelayMsgsFile $msgs; $resp = "OK"
                    } elseif ($authenticated -and $line -match '^RECV\|(.+)$') {
                        $code = $matches[1]
                        $msgs = @(Load-RData $RelayMsgsFile); $pending = @()
                        if ($msgs.ContainsKey($code)) { $pending = $msgs[$code]; $msgs.Remove($code); Save-RData $RelayMsgsFile $msgs }
                        if ($pending.Count -gt 0) { foreach ($m in $pending) { $resp += "MSG|$($m.From)|$($m.PubKey)|$($m.Payload)`n" } }
                        if (-not $resp) { $resp = "NONE" }
                    } elseif ($authenticated -and $line -eq "PING") { $resp = "PONG" }
                    elseif (-not $authenticated) { $resp = "AUTH_REQUIRED" }
                    if ($resp) {
                        $final = if ($isHttp) { Wrap-Http $resp } else { $resp }
                        $writer.Write($final)
                        if (-not $isHttp) { $writer.Write("`n") }
                    }
                }
                $writer.Flush()
                $reader.Close(); $writer.Close(); $client.Close()
            } catch { Start-Sleep -Milliseconds 50 }
        }
    } catch { Write-Host "`n[!] Relay Server error: $_" -ForegroundColor Red }
}

Write-Host "Starting services..." -ForegroundColor DarkGray
$tcpJob = Start-Job -Name "TCPListener" -ScriptBlock $tcpListenerScript -ArgumentList $ChatPort, $InboxFile, $BlockedFile, $PrivateKeyFile, $KnownKeysFile, $MyCode, $ECDHKeyFile, $DownloadsDir, $DisableSound
$udpJob = Start-Job -Name "UDPDiscovery" -ScriptBlock $udpListenerScript -ArgumentList $DiscoveryPort, $MyCode, $MyIP, $MyPublicKeyB64

$script:RelayAddr = ""
$script:RelayPortNum = 0
$relayServerJob = $null

if ($RelayPort -gt 0) {
    $relayServerJob = Start-Job -Name "RelayServer" -ScriptBlock $relayServerScript -ArgumentList $RelayPort, $RelayMsgsFile, $RelayPassword, $DataDir
}

if ($RelayAddress -match '^(.+):(\d+)$') {
    $script:RelayAddr = $matches[1]
    $script:RelayPortNum = [int]$matches[2]
}

if ($RegistryAddress) {
    Write-Host "Registering with directory: $RegistryAddress ..." -ForegroundColor DarkYellow
    $regOk = Register-User
    if ($regOk) { Write-Host "Registered at directory." -ForegroundColor Green }
    else { Write-Host "Directory registration failed (will retry)." -ForegroundColor Yellow }
}

Start-Sleep -Milliseconds 500

function Get-RelayConn {
    $tcp = $null
    if ($RelayProxy) {
        $tcp = Connect-viaProxy $RelayProxy $script:RelayAddr $script:RelayPortNum
        if (-not $tcp) { return $null }
        $tcp.ReceiveTimeout = 5000
    } else {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect($script:RelayAddr, $script:RelayPortNum)
        $tcp.ReceiveTimeout = 5000
    }
    $ns = $tcp.GetStream()
    if ($RelayPassword) {
        $ssl = New-Object System.Net.Security.SslStream($ns, $false, { param($s,$c,$ch,$err) $true })
        $ssl.AuthenticateAsClient("MessageAppRelay", $null, [System.Security.Authentication.SslProtocols]::Tls12, $false)
        $ns = $ssl
    }
    return @{ Tcp = $tcp; Stream = $ns }
}

function Relay-Send {
    param([string]$ToCode, [string]$PubKeyB64, [string]$Payload)
    if (-not $script:RelayAddr) { return $false }
    try {
        $conn = Get-RelayConn
        if (-not $conn) { return $false }
        $ns = $conn.Stream
        $writer = New-Object System.IO.StreamWriter($ns)
        $reader = New-Object System.IO.StreamReader($ns)

        $encodedPayload = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Payload))
        $cmd = ""
        if ($RelayPassword) {
            $cmd += "AUTH|$RelayPassword`n"
        }
        if ($RelayObfuscate -and $RelayPassword) {
            $inboxID = Get-InboxID $ToCode $RelayPassword
            $myInboxID = Get-InboxID $MyCode $RelayPassword
            $cmd += "SENDI|$inboxID|$myInboxID|$PubKeyB64|$encodedPayload"
        } else {
            $cmd += "SEND|$MyCode|$ToCode|$PubKeyB64|$encodedPayload"
        }
        $body = $cmd
        if ($RelayObfuscatePort) { $body = Wrap-Http $body }
        $writer.Write($body)
        if (-not $RelayObfuscatePort) { $writer.Write("`n") }
        $writer.Flush()

        $rawResp = $reader.ReadToEnd()
        $resp = if ($RelayObfuscatePort) { (Unwrap-Http $rawResp).Trim("`r`n") } else { $rawResp.Trim("`r`n") }

        $reader.Close(); $writer.Close(); $conn.Tcp.Close()
        $firstLine = ($resp -split "`n" | Select-Object -First 1).Trim("`r")
        $ok = $false
        if ($firstLine -eq "OK") { $ok = $true }
        elseif ($firstLine -eq "AUTH_OK") {
            $secondLine = ($resp -split "`n" | Select-Object -Skip 1 | Select-Object -First 1).Trim("`r")
            if ($secondLine -eq "OK") { $ok = $true }
        }
        return $ok
    } catch { return $false }
}

function Relay-Recv {
    if (-not $script:RelayAddr) { return @() }
    try {
        $conn = Get-RelayConn
        if (-not $conn) { return @() }
        $ns = $conn.Stream
        $writer = New-Object System.IO.StreamWriter($ns)
        $reader = New-Object System.IO.StreamReader($ns)

        $cmd = ""
        if ($RelayPassword) {
            $cmd += "AUTH|$RelayPassword`n"
        }
        $recvID = if ($RelayObfuscate -and $RelayPassword) { Get-InboxID $MyCode $RelayPassword } else { $MyCode }
        $cmd += "RECV|$recvID"

        $body = $cmd
        if ($RelayObfuscatePort) { $body = Wrap-Http $body }
        $writer.Write($body)
        if (-not $RelayObfuscatePort) { $writer.Write("`n") }
        $writer.Flush()

        $rawResp = $reader.ReadToEnd()
        $resp = if ($RelayObfuscatePort) { Unwrap-Http $rawResp } else { $rawResp }
        $reader.Close(); $writer.Close(); $conn.Tcp.Close()

        $results = @()
        $lines = $resp -split "`n" | ForEach-Object { $_.Trim("`r") }
        foreach ($line in $lines) {
            if (-not $line -or $line -eq "NONE") { continue }
            if ($line -eq "AUTH_OK") { continue }
            if ($line -match '^MSG\|(.*)\|(.*)\|(.+)$') {
                $decodedPayload = try { [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($matches[3])) } catch { $matches[3] }
                $results += [PSCustomObject]@{ From = $matches[1]; PubKey = $matches[2]; Payload = $decodedPayload }
            }
        }
        return $results
    } catch { return @() }
}

function Discover-IP {
    param([string]$TargetCode)
    if ($script:IPCache.ContainsKey($TargetCode)) { return $script:IPCache[$TargetCode] }
    try {
        $udp = New-Object System.Net.Sockets.UdpClient
        $localEP = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $udp.Client.Bind($localEP)
        $udp.Client.ReceiveTimeout = 2000
        $broadcast = [System.Net.IPAddress]::Broadcast
        $sendEP = New-Object System.Net.IPEndPoint($broadcast, $DiscoveryPort)
        $findMsg = "FIND|$MyCode|$TargetCode"
        $findBytes = [System.Text.Encoding]::UTF8.GetBytes($findMsg)
        $udp.Send($findBytes, $findBytes.Length, $sendEP) | Out-Null
        $timeout = [DateTime]::Now.AddSeconds(3)
        while ([DateTime]::Now -lt $timeout) {
            try {
                $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
                $data = $udp.Receive([ref]$remote)
                $response = [System.Text.Encoding]::UTF8.GetString($data)
                $rParts = $response -split '\|', 4
                if ($rParts.Count -ge 3 -and $rParts[0] -eq "HERE" -and $rParts[1] -eq $TargetCode) {
                    $ip = $rParts[2]
                    $script:IPCache[$TargetCode] = $ip
                    if ($rParts.Count -ge 4 -and $rParts[3]) {
                        try { Save-PublicKey $TargetCode ([System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($rParts[3]))) } catch {}
                    }
                    $udp.Close()
                    return $ip
                }
            } catch { break }
        }
        $udp.Close()
    } catch {}
    return $null
}

function Resolve-InboxID {
    param([string]$InboxID)
    if (-not $RelayPassword) { return $null }
    foreach ($f in $script:Friends) {
        $fid = Get-InboxID $f.Code $RelayPassword
        if ($fid -eq $InboxID) { return $f.Code }
    }
    return $null
}

function Push-RelayMessages {
    $msgs = Relay-Recv
    foreach ($m in $msgs) {
        $senderCode = $m.From
        $relayPubKey = $m.PubKey

        if ($senderCode -and -not (Get-PublicKeyForCode $senderCode) -and $RelayPassword) {
            $resolved = Resolve-InboxID $senderCode
            if ($resolved) { $senderCode = $resolved }
        }

        if ($relayPubKey) {
            try { Save-PublicKey $senderCode ([System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($relayPubKey))) } catch {}
        }

        $pParts = $m.Payload -split '\|', 2
        $type = if ($pParts.Count -ge 1) { $pParts[0] } else { "" }
        $content = if ($pParts.Count -ge 2) { $pParts[1] } else { $m.Payload }

        $displayMsg = ""
        $isEncrypted = $false
        $isFS = $false
        $isVerified = $false
        $isVoice = $false
        $tag = ""

        if ($type -eq "ACK") {
            $inboxAck = @(Load-Data $InboxFile)
            $updated = $false
            for ($ai = $inboxAck.Count - 1; $ai -ge 0; $ai--) {
                if ($inboxAck[$ai].ToCode -eq $senderCode -and $inboxAck[$ai].IsSent -and -not $inboxAck[$ai].Acked) {
                    $inboxAck[$ai].Acked = $true
                    Write-Host "`n[DELIVERED] $senderCode received your message" -ForegroundColor Green
                    Write-Host -NoNewline "> " -ForegroundColor Green
                    $updated = $true
                    break
                }
            }
            if ($updated) { Save-Data $InboxFile $inboxAck }
            continue
        } elseif ($type -eq "KX") {
            try {
                Save-ECDHKey $senderCode $content
                Write-Host "`n[KEY EX] ECDH key from $senderCode" -ForegroundColor Green
            } catch {}
            continue
        } elseif ($type -eq "FS" -and $content -match '^([A-Za-z0-9+/=]+)\|([A-Za-z0-9+/=]+)\|([A-Za-z0-9+/=]+)\|([A-Za-z0-9+/=]+)$') {
            $fsResult = Decrypt-FS $senderCode $matches[1] $matches[2] $matches[3] $matches[4]
            if ($fsResult) {
                $displayMsg = $fsResult.Text
                $isEncrypted = $true; $isFS = $true; $isVerified = $fsResult.Verified
                $tag = "[FS]"
                if ($isVerified) { $tag += "[V] " } else { $tag += "[!] " }
            } else { $displayMsg = "[Decryption failed]"; $tag = "[FS ERR] " }
        } elseif ($type -eq "1" -and $content -match '^([A-Za-z0-9+/=]+)\|([A-Za-z0-9+/=]+)\|([A-Za-z0-9+/=]+)$') {
            $decrypted = Decrypt-Message $matches[1] $matches[2] $matches[3]
            if ($decrypted) { $displayMsg = $decrypted; $isEncrypted = $true; $tag = "[E] " }
            else { $displayMsg = "[Decryption failed]"; $tag = "[ERR] " }
        } elseif ($type -eq "2" -and $content -match '^FILE\|(.+)\|(\d+)\|(\d+)\|(.+)$') {
            $fileNameB64 = $matches[1]
            $totalChunks = [int]$matches[2]
            $chunkIndex = [int]$matches[3]
            $chunkB64 = $matches[4]
            $fileName = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($fileNameB64))
            $key = "$senderCode`:$fileName"
            if (-not $script:PendingFileTransfer.ContainsKey($key)) {
                $script:PendingFileTransfer[$key] = @{ FileName = $fileName; FromCode = $senderCode; TotalChunks = $totalChunks; Chunks = @{}; Received = (Get-Date) }
            }
            $tf = $script:PendingFileTransfer[$key]
            $tf.Chunks[$chunkIndex] = [Convert]::FromBase64String($chunkB64)
            if ($tf.Chunks.Count -eq $totalChunks) {
                $allData = New-Object byte[] 0
                for ($i = 0; $i -lt $totalChunks; $i++) { if ($tf.Chunks.ContainsKey($i)) { $allData = $allData + $tf.Chunks[$i] } }
                $safeName = $tf.FileName -replace '[^\w\.\-]', '_'
                $savePath = Join-Path $DownloadsDir "$($tf.FromCode)_$safeName"
                try { [System.IO.File]::WriteAllBytes($savePath, $allData); $imgInfo = Get-ImageInfo -FilePath $savePath; if ($imgInfo) { Write-Host "`n[IMAGE] $($tf.FileName) - $imgInfo" -ForegroundColor Cyan }; Write-Host "`n[FILE] Received: $($tf.FileName) -> $savePath" -ForegroundColor Yellow }
                catch { Write-Host "`n[FILE ERROR] $_" -ForegroundColor Red }
                $script:PendingFileTransfer.Remove($key)
            }
            $displayMsg = "[File: $fileName chunk $($chunkIndex+1)/$totalChunks]"
            $tag = "[FILE] "
        } elseif ($type -eq "VN" -and $content -match '^(\d+)\|(.+)\|(\d+)\|(\d+)\|(.+)$') {
            $isVoice = $true
            $voiceDuration = [int]$matches[1]
            $voiceNameB64 = $matches[2]
            $voiceTotal = [int]$matches[3]
            $voiceIdx = [int]$matches[4]
            $voiceB64 = $matches[5]
            $vkey = "$senderCode`_voice"
            if (-not $script:VoiceChunkBuffer.ContainsKey($vkey)) {
                $script:VoiceChunkBuffer[$vkey] = @{ Chunks = @{}; Total = $voiceTotal; Duration = $voiceDuration; Received = (Get-Date) }
            }
            $vb = $script:VoiceChunkBuffer[$vkey]
            $vb.Chunks[$voiceIdx] = [Convert]::FromBase64String($voiceB64)
            if ($vb.Chunks.Count -eq $voiceTotal) {
                $allData = New-Object byte[] 0
                for ($i = 0; $i -lt $voiceTotal; $i++) { if ($vb.Chunks.ContainsKey($i)) { $allData = $allData + $vb.Chunks[$i] } }
                $script:VoiceChunkBuffer.Remove($vkey)
                Write-Host "`n[VOICE NOTE] $($vb.Duration)sec from $senderCode. Playing..." -ForegroundColor Magenta
                $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) "voice_relay_$senderCode.wav"
                try { [System.IO.File]::WriteAllBytes($tempFile, $allData); $player = New-Object System.Media.SoundPlayer($tempFile); $player.PlaySync(); $player.Dispose(); Remove-Item $tempFile -Force -ErrorAction SilentlyContinue } catch {}
            }
            $displayMsg = "[Voice $voiceDuration sec chunk $($voiceIdx+1)/$voiceTotal]"
            $tag = "[VN] "
        } elseif ($type -eq "0") {
            $parts0 = $content -split '\|', 2
            $displayMsg = $parts0[0]
            if ($parts0.Count -ge 2 -and $parts0[1]) {
                $verified = $false
                $keys = @(Load-Data $KnownKeysFile)
                $entry = $keys | Where-Object { $_.Code -eq $senderCode }
                if ($entry -and $entry.PublicKey) {
                    $pubKeyXml = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($entry.PublicKey))
                    $rsa = [System.Security.Cryptography.RSA]::Create()
                    $rsa.FromXmlString($pubKeyXml)
                    $sig = [Convert]::FromBase64String($parts0[1])
                    $verified = $rsa.VerifyData([System.Text.Encoding]::UTF8.GetBytes($parts0[0]), $sig, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
                    $rsa.Dispose()
                }
                $isVerified = $verified
                $tag = if ($verified) { "[V] " } else { "[!] " }
            }
        } else { $displayMsg = $m.Payload }

        if ($displayMsg) {
            $now = Get-Date
            $msgObj = [PSCustomObject]@{
                FromCode = $senderCode; FromIP = "(relay)"; Text = $displayMsg
                IsEncrypted = $isEncrypted; IsFS = $isFS; IsVerified = $isVerified
                IsVoice = $isVoice; Acked = $false
                Date = $now.ToString("yyyy-MM-dd"); Time = $now.ToString("HH:mm:ss"); Read = $false
            }
            $inbox = @(Load-Data $InboxFile)
            $inbox += $msgObj
            Save-Data $InboxFile $inbox
            if (-not $DisableSound) { [System.Console]::Beep(600, 120) }
            Write-Host "`n${tag}[Relay] $senderCode : $displayMsg" -ForegroundColor Magenta
            Write-Host -NoNewline "> " -ForegroundColor Green
        }
    }
}

$script:PendingFileTransfer = @{}

# ========== VOICE RECORDER (C# P/Invoke via winmm.dll) ==========

$script:VoiceRecorderLoaded = $false
try {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.IO;

public class VoiceRecorder
{
    private const int MM_WIM_DATA = 0x3C0;
    private const int WAVE_FORMAT_PCM = 1;
    private const int CALLBACK_FUNCTION = 0x30000;

    [DllImport("winmm.dll")]
    private static extern int waveInOpen(out IntPtr hWaveIn, int uDeviceID, ref WAVEFORMATEX lpFormat, WaveDelegate dwCallback, IntPtr dwInstance, int fdwOpen);

    [DllImport("winmm.dll")]
    private static extern int waveInClose(IntPtr hWaveIn);

    [DllImport("winmm.dll")]
    private static extern int waveInPrepareHeader(IntPtr hWaveIn, ref WAVEHDR lpWaveInHdr, int uSize);

    [DllImport("winmm.dll")]
    private static extern int waveInUnprepareHeader(IntPtr hWaveIn, ref WAVEHDR lpWaveInHdr, int uSize);

    [DllImport("winmm.dll")]
    private static extern int waveInAddBuffer(IntPtr hWaveIn, ref WAVEHDR lpWaveInHdr, int uSize);

    [DllImport("winmm.dll")]
    private static extern int waveInStart(IntPtr hWaveIn);

    [DllImport("winmm.dll")]
    private static extern int waveInStop(IntPtr hWaveIn);

    [DllImport("winmm.dll")]
    private static extern int waveInGetNumDevs();

    [StructLayout(LayoutKind.Sequential)]
    private struct WAVEFORMATEX
    {
        public ushort wFormatTag;
        public ushort nChannels;
        public uint nSamplesPerSec;
        public uint nAvgBytesPerSec;
        public ushort nBlockAlign;
        public ushort wBitsPerSample;
        public ushort cbSize;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct WAVEHDR
    {
        public IntPtr lpData;
        public uint dwBufferLength;
        public uint dwBytesRecorded;
        public IntPtr dwUser;
        public uint dwFlags;
        public uint dwLoops;
        public IntPtr lpNext;
        public IntPtr reserved;
    }

    private delegate void WaveDelegate(IntPtr hWaveIn, int uMsg, IntPtr dwInstance, IntPtr dwParam1, IntPtr dwParam2);

    private static IntPtr waveInHandle;
    private static byte[] recordedBuffer;
    private static bool recordingComplete;
    private static object lockObj = new object();

    private static void WaveCallback(IntPtr hWaveIn, int uMsg, IntPtr dwInstance, IntPtr dwParam1, IntPtr dwParam2)
    {
        if (uMsg == MM_WIM_DATA)
        {
            lock (lockObj) { recordingComplete = true; }
        }
    }

    public static int GetDeviceCount() { return waveInGetNumDevs(); }

    public static byte[] Record(int durationSeconds, int sampleRate = 44100, int bitsPerSample = 16, int channels = 1)
    {
        if (waveInGetNumDevs() == 0) return null;
        recordingComplete = false;
        WAVEFORMATEX fmt = new WAVEFORMATEX();
        fmt.wFormatTag = WAVE_FORMAT_PCM;
        fmt.nChannels = (ushort)channels;
        fmt.nSamplesPerSec = (uint)sampleRate;
        fmt.wBitsPerSample = (ushort)bitsPerSample;
        fmt.nBlockAlign = (ushort)(channels * bitsPerSample / 8);
        fmt.nAvgBytesPerSec = (uint)(sampleRate * channels * bitsPerSample / 8);
        fmt.cbSize = 0;

        int totalBytes = (int)(sampleRate * channels * (bitsPerSample / 8) * durationSeconds);
        recordedBuffer = new byte[totalBytes];
        GCHandle bufHandle = GCHandle.Alloc(recordedBuffer, GCHandleType.Pinned);

        WAVEHDR header = new WAVEHDR();
        header.lpData = bufHandle.AddrOfPinnedObject();
        header.dwBufferLength = (uint)totalBytes;

        WaveDelegate callback = new WaveDelegate(WaveCallback);
        GCHandle cbHandle = GCHandle.Alloc(callback);

        int result = waveInOpen(out waveInHandle, 0, ref fmt, callback, IntPtr.Zero, CALLBACK_FUNCTION);
        if (result != 0) { bufHandle.Free(); cbHandle.Free(); return null; }

        waveInPrepareHeader(waveInHandle, ref header, System.Runtime.InteropServices.Marshal.SizeOf(header));
        waveInAddBuffer(waveInHandle, ref header, System.Runtime.InteropServices.Marshal.SizeOf(header));
        waveInStart(waveInHandle);

        int waited = 0;
        while (waited < (durationSeconds + 2) * 10)
        {
            System.Threading.Thread.Sleep(100);
            waited++;
            lock (lockObj) { if (recordingComplete) break; }
        }

        waveInStop(waveInHandle);
        waveInUnprepareHeader(waveInHandle, ref header, System.Runtime.InteropServices.Marshal.SizeOf(header));
        waveInClose(waveInHandle);

        uint bytesRecorded = header.dwBytesRecorded;
        if (bytesRecorded == 0) bytesRecorded = (uint)totalBytes;

        bufHandle.Free();
        cbHandle.Free();

        byte[] wavData = BuildWavFile(recordedBuffer, (int)bytesRecorded, sampleRate, bitsPerSample, channels);
        return wavData;
    }

    private static byte[] BuildWavFile(byte[] audioData, int dataSize, int sampleRate, int bitsPerSample, int channels)
    {
        int byteRate = sampleRate * channels * bitsPerSample / 8;
        int blockAlign = channels * bitsPerSample / 8;
        int headerSize = 44;
        int fileSize = headerSize + dataSize;
        using (MemoryStream ms = new MemoryStream(fileSize))
        using (BinaryWriter bw = new BinaryWriter(ms))
        {
            bw.Write(new char[] { 'R', 'I', 'F', 'F' });
            bw.Write(fileSize - 8);
            bw.Write(new char[] { 'W', 'A', 'V', 'E' });
            bw.Write(new char[] { 'f', 'm', 't', ' ' });
            bw.Write(16);
            bw.Write((short)WAVE_FORMAT_PCM);
            bw.Write((short)channels);
            bw.Write(sampleRate);
            bw.Write(byteRate);
            bw.Write((short)blockAlign);
            bw.Write((short)bitsPerSample);
            bw.Write(new char[] { 'd', 'a', 't', 'a' });
            bw.Write(dataSize);
            bw.Write(audioData, 0, dataSize);
            bw.Flush();
            return ms.ToArray();
        }
    }
}
"@ -ErrorAction SilentlyContinue
    $script:VoiceRecorderLoaded = $true
    Write-Host "Voice recorder initialized (microphone supported)" -ForegroundColor DarkGray
} catch { Write-Host "Voice recorder not available (microphone features disabled)" -ForegroundColor DarkGray }

function Record-Audio {
    param([int]$Duration = 5)
    if (-not $script:VoiceRecorderLoaded) { return $null }
    try {
        $devices = [VoiceRecorder]::GetDeviceCount()
        if ($devices -eq 0) { Write-Host "No microphone found." -ForegroundColor Red; return $null }
        Write-Host "Recording for $Duration seconds... (speak now)" -ForegroundColor Yellow
        $wavBytes = [VoiceRecorder]::Record($Duration)
        if ($wavBytes -and $wavBytes.Length -gt 44) {
            $sizeKB = [math]::Round($wavBytes.Length / 1KB, 1)
            Write-Host "Recording complete ($sizeKB KB)" -ForegroundColor Green
            return $wavBytes
        }
        Write-Host "Recording failed." -ForegroundColor Red
    } catch { Write-Host "Recording error: $_" -ForegroundColor Red }
    return $null
}

function Send-VoiceNote {
    param([string]$TargetCode, [int]$Duration = 5)
    $wavBytes = Record-Audio -Duration $Duration
    if (-not $wavBytes) { return $false, "Recording failed" }
    try {
        $fileNameB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("voice.wav"))
        $totalSize = $wavBytes.Length
        $maxChunkSize = 250KB
        $totalChunks = [math]::Ceiling($totalSize / $maxChunkSize)
        for ($i = 0; $i -lt $totalChunks; $i++) {
            $offset = $i * $maxChunkSize
            $chunkSize = [math]::Min($maxChunkSize, $totalSize - $offset)
            $chunkBytes = $wavBytes[$offset..($offset + $chunkSize - 1)]
            $chunkB64 = [Convert]::ToBase64String($chunkBytes)
            $meta = "VN|$Duration|$fileNameB64|$totalChunks|$i|$chunkB64"
            $ok = Send-MessageRaw -TargetCode $TargetCode -Payload $meta
            if (-not $ok) { return $false, "Failed at chunk $i/$totalChunks" }
            $pct = [math]::Round(($i + 1) / $totalChunks * 100)
            Write-Host "  Sent voice chunk $($i+1)/$totalChunks ($pct%)" -ForegroundColor DarkGray
            Start-Sleep -Milliseconds 50
        }
        return $true, "Voice note sent ($Duration sec, $totalChunks chunks)"
    } catch { return $false, "Error: $_" }
}

function Play-VoiceNote {
    param([byte[]]$WavData)
    try {
        $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) "voice_note.wav"
        [System.IO.File]::WriteAllBytes($tempFile, $WavData)
        $player = New-Object System.Media.SoundPlayer($tempFile)
        $player.PlaySync()
        $player.Dispose()
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    } catch { Write-Host "Playback error: $_" -ForegroundColor Red }
}

$script:VoiceChunkBuffer = @{}

function Receive-VoiceChunk {
    param([string]$FromCode, [string]$FileNameB64, [int]$TotalChunks, [int]$ChunkIndex, [string]$ChunkB64, [int]$Duration)
    $key = "$FromCode`_voice"
    if (-not $script:VoiceChunkBuffer.ContainsKey($key)) {
        $script:VoiceChunkBuffer[$key] = @{ Chunks = @{}; Total = $TotalChunks; Duration = $Duration; FileName = $FromCode; Received = (Get-Date) }
    }
    $vb = $script:VoiceChunkBuffer[$key]
    $vb.Chunks[$ChunkIndex] = [Convert]::FromBase64String($ChunkB64)
    if ($vb.Chunks.Count -eq $TotalChunks) {
        $allData = New-Object byte[] 0
        for ($i = 0; $i -lt $TotalChunks; $i++) { if ($vb.Chunks.ContainsKey($i)) { $allData = $allData + $vb.Chunks[$i] } }
        $script:VoiceChunkBuffer.Remove($key)
        Write-Host "`n[VOICE NOTE] $($vb.Duration)sec from $FromCode. Playing..." -ForegroundColor Magenta
        Play-VoiceNote -WavData $allData
        return $allData
    }
    return $null
}

# ========== MESSAGE DELETE & EDIT ==========

function Delete-Message {
    param([int]$Index)
    $inbox = @(Load-Data $InboxFile)
    if ($Index -lt 0 -or $Index -ge $inbox.Count) { return $false, "Invalid index" }
    $msg = $inbox[$Index]
    if (-not $msg.IsSent -and $msg.FromCode -ne $MyCode) { return $false, "Can only delete your own messages" }
    $inbox = @($inbox[0..($Index-1)] + $inbox[($Index+1)..($inbox.Count-1)])
    Save-Data $InboxFile $inbox
    return $true, "Message deleted"
}

function Edit-Message {
    param([int]$Index, [string]$NewText)
    $inbox = @(Load-Data $InboxFile)
    if ($Index -lt 0 -or $Index -ge $inbox.Count) { return $false, "Invalid index" }
    $msg = $inbox[$Index]
    if (-not $msg.IsSent -and $msg.FromCode -ne $MyCode) { return $false, "Can only edit your own messages" }
    $inbox[$Index].Text = $NewText
    $inbox[$Index].Edited = $true
    Save-Data $InboxFile $inbox
    return $true, "Message edited"
}

function Clear-Chat {
    param([string]$TargetCode)
    $inbox = @(Load-Data $InboxFile)
    $before = $inbox.Count
    $inbox = @($inbox | Where-Object {
        -not (($_.FromCode -eq $TargetCode -and $_.ToCode -eq $MyCode) -or ($_.FromCode -eq $MyCode -and $_.ToCode -eq $TargetCode))
    })
    $after = $inbox.Count
    Save-Data $InboxFile $inbox
    return $before - $after
}

function Pin-Message {
    param([int]$Index)
    $inbox = @(Load-Data $InboxFile)
    if ($Index -lt 0 -or $Index -ge $inbox.Count) { return $false, "Invalid index" }
    $inbox[$Index].Pinned = (-not $inbox[$Index].Pinned)
    $action = if ($inbox[$Index].Pinned) { "pinned" } else { "unpinned" }
    Save-Data $InboxFile $inbox
    return $true, "Message $action"
}

function Get-PinnedMessages {
    param([string]$TargetCode)
    $inbox = @(Load-Data $InboxFile)
    return @($inbox | Where-Object {
        $_.Pinned -and (($_.FromCode -eq $TargetCode -and $_.ToCode -eq $MyCode) -or ($_.FromCode -eq $MyCode -and $_.ToCode -eq $TargetCode))
    })
}

function Show-Header {
    Clear-Host
    Write-Host "===== Message App v2.0 =====" -ForegroundColor Cyan
    Write-Host "Your Code: $MyCode" -ForegroundColor Green
    $statusLine = Get-StatusLine
    if ($statusLine) { Write-Host $statusLine -ForegroundColor DarkYellow }
    $relayInfo = ""
    if ($script:RelayAddr) {
        $relayInfo = "Relay: $($script:RelayAddr):$($script:RelayPortNum)"
        if ($RelayPassword) { $relayInfo += " [auth]" }
        if ($RelayObfuscate) { $relayInfo += " [hidden meta]" }
        if ($RelayProxy) { $relayInfo += " [proxy: $RelayProxy]" }
        if ($RelayObfuscatePort) { $relayInfo += " [HTTP:$RelayObfuscatePort]" }
        Write-Host $relayInfo -ForegroundColor DarkYellow
    }
    if ($RelayPort -gt 0) {
        $srvInfo = "Relay Server: port $RelayPort"
        if ($RelayPassword) { $srvInfo += " [password required]" }
        if ($RelayObfuscate) { $srvInfo += " + obfuscation" }
        Write-Host $srvInfo -ForegroundColor DarkYellow
    }
    if ($RegistryAddress) { Write-Host "Directory: $RegistryAddress" -ForegroundColor DarkYellow }
    $onlineCount = 0
    foreach ($f in $script:Friends) { if (Discover-IP $f.Code) { $onlineCount++ } }
    Write-Host "[FS: ECDH-P521 + RSA-2048 signing + AES-256]" -ForegroundColor DarkYellow
    Write-Host "[Friends online: $onlineCount/$($script:Friends.Count) | Voice | Groups | Files | Search]" -ForegroundColor DarkGray
    Write-Host "============================" -ForegroundColor Cyan
}

function Show-MainMenu {
    Write-Host ""
    Write-Host "-- Main Menu --" -ForegroundColor White
    Write-Host "1. Send Message" -ForegroundColor White
    $inboxLabel = "2. View Inbox"
    if ($script:HasNewMessages) { $inboxLabel += " {NEW}" }
    Write-Host $inboxLabel -ForegroundColor White
    Write-Host "3. Friends List" -ForegroundColor White
    Write-Host "4. Add Friend" -ForegroundColor White
    Write-Host "5. Remove Friend" -ForegroundColor White
    Write-Host "6. Blocked Users" -ForegroundColor White
    Write-Host "7. Block a Code" -ForegroundColor White
    Write-Host "8. Unblock a Code" -ForegroundColor White
    Write-Host "9. Your Info" -ForegroundColor White
    Write-Host "10. Re-Register with Directory" -ForegroundColor White
    Write-Host "11. Groups" -ForegroundColor White
    Write-Host "12. Send File" -ForegroundColor White
    Write-Host "13. Search History" -ForegroundColor White
    Write-Host "14. View Downloads" -ForegroundColor White
    Write-Host "15. Delete a Message" -ForegroundColor White
    Write-Host "16. Edit a Message" -ForegroundColor White
    Write-Host "17. Send Voice Note" -ForegroundColor White
    Write-Host "18. Clear Chat" -ForegroundColor White
    Write-Host "19. Export Chat History" -ForegroundColor White
    Write-Host "20. Set Your Status" -ForegroundColor White
    Write-Host "0. Exit" -ForegroundColor Red
}

function Show-Inbox {
    $inbox = @(Load-Data $InboxFile)
    if ($inbox.Count -eq 0) { Write-Host "`nInbox is empty." -ForegroundColor Yellow; return }
    Write-Host "`n=== Inbox ===" -ForegroundColor Cyan
    for ($i = 0; $i -lt $inbox.Count; $i++) {
        $m = $inbox[$i]
        $name = $m.FromCode
        $friend = $script:Friends | Where-Object { $_.Code -eq $m.FromCode }
        if ($friend) { $name = "$($friend.Name) ($($m.FromCode))" } elseif ($m.FromCode -eq $MyCode) { $name = "You" }
        $tag = ""
        if ($m.IsFS) { $tag += "[FS]" }
        if ($m.IsVerified) { $tag += "[V]" }
        if ($m.IsEncrypted -and -not $m.IsFS) { $tag += "[E]" }
        if ($m.IsGroup) { $tag += "[G]" }
        if ($m.IsVoice) { $tag += "[VN]" }
        if ($m.Edited) { $tag += "[ED]" }
        if ($m.IsSent -and $m.Acked) { $tag += "[D]" }
        if ($m.Pinned) { $tag += "[PIN]" }
        if ($tag) { $tag = "$tag " }
        $newTag = if (-not $m.Read) { " {NEW}" } else { "" }
        $who = if ($m.IsSent -or $m.FromCode -eq $MyCode) { "You -> $($m.ToCode)" } else { $name }
        Write-Host "[$i] [$($m.Date) $($m.Time)] ${tag}$who : $($m.Text)$newTag" -ForegroundColor White
        $inbox[$i].Read = $true
    }
    Write-Host "" -ForegroundColor DarkGray
    Write-Host "d# delete | e# edit | p# pin/unpin" -ForegroundColor DarkGray
    $action = Read-Host "Action (Enter to continue)"
    if ($action -match '^d(\d+)$') {
        $ok, $result = Delete-Message -Index ([int]$matches[1])
        Write-Host $result -ForegroundColor $(if ($ok) { "Green" } else { "Red" })
        Show-Inbox
        return
    } elseif ($action -match '^p(\d+)$') {
        $ok, $result = Pin-Message -Index ([int]$matches[1])
        Write-Host $result -ForegroundColor $(if ($ok) { "Green" } else { "Red" })
        Show-Inbox
        return
    } elseif ($action -match '^e(\d+)$') {
        $newText = Read-Host "New text"
        $ok, $result = Edit-Message -Index ([int]$matches[1]) -NewText $newText
        Write-Host $result -ForegroundColor $(if ($ok) { "Green" } else { "Red" })
        Show-Inbox
        return
    }
    Save-Data $InboxFile $inbox
    $script:HasNewMessages = $false
}

function Chat-Session {
    param([string]$TargetCode, [string]$TargetName)

    $displayName = if ($TargetName) { $TargetName } else { $TargetCode }
    $hasFSKey = [bool](Get-ECDHKeyForCode $TargetCode)
    $hasRSAKey = [bool](Get-PublicKeyForCode $TargetCode)

    if ($hasFSKey) { Write-Host "`nChatting with $displayName ($TargetCode) [FS + Signing]" -ForegroundColor Green }
    elseif ($hasRSAKey) { Write-Host "`nChatting with $displayName ($TargetCode) [RSA E2E]" -ForegroundColor Yellow }
    else { Write-Host "`nChatting with $displayName ($TargetCode) [no key - first msg plaintext + signed]" -ForegroundColor Yellow }

    Send-ECDHKeyExchange $TargetCode | Out-Null
    $pinnedMsgs = Get-PinnedMessages -TargetCode $TargetCode
    if ($pinnedMsgs.Count -gt 0) {
        Write-Host "--- Pinned ---" -ForegroundColor DarkYellow
        foreach ($pm in $pinnedMsgs) {
            $pwho = if ($pm.IsSent) { "You" } else { $displayName }
            Write-Host "[PIN] $pwho : $($pm.Text)" -ForegroundColor DarkYellow
        }
    }
    Write-Host "'r' refresh, 'h' history, 'f' file, 'v' voice, '/s' search, 'p' pin, 'd' delete, 'e' edit, 'back' return" -ForegroundColor DarkGray

    while ($true) {
        $input = Read-Host "You"
        if ($input -eq "back") { break }
        if ($input -match '^/s (.+)$') {
            $sq = $matches[1]
            $sResults = Search-Messages -Query $sq -FromCode $TargetCode
            if ($sResults.Count -eq 0) { Write-Host "No matches." -ForegroundColor Yellow }
            else {
                Write-Host "--- Search: '$sq' ($($sResults.Count) results) ---" -ForegroundColor Cyan
                $sResults | Sort-Object { "$($_.Date) $($_.Time)" } | ForEach-Object {
                    $swho = if ($_.IsSent) { "You" } else { $displayName }
                    Write-Host "[$($_.Date) $($_.Time)] $swho : $($_.Text)" -ForegroundColor White
                }
            }
            continue
        }
        if ($input -ne "" -and $input -ne "r" -and $input -ne "h" -and $input -ne "f" -and $input -ne "v" -and $input -ne "d" -and $input -ne "e" -and $input -ne "p") {
            $ip = Discover-IP $TargetCode
            if ($ip) {
                try {
                    $typClient = New-Object System.Net.Sockets.TcpClient
                    $typClient.Connect($ip, $ChatPort)
                    $typClient.ReceiveTimeout = 1000
                    $typStream = $typClient.GetStream()
                    $typWriter = New-Object System.IO.StreamWriter($typStream)
                    $typWriter.WriteLine("$MyCode|$MyIP||TYP|$TargetCode")
                    $typWriter.Flush()
                    $typWriter.Close()
                    $typClient.Close()
                } catch {}
            }
        }
        if ($input -eq "r") {
            $inbox = @(Load-Data $InboxFile)
            $convo = $inbox | Where-Object { ($_.FromCode -eq $TargetCode -and $_.ToCode -eq $MyCode) -or ($_.FromCode -eq $MyCode -and $_.ToCode -eq $TargetCode) } | Select-Object -Last 10
            if ($convo) {
                Write-Host "--- Recent ---" -ForegroundColor DarkGray
                $convo | ForEach-Object {
                    $who = if ($_.FromCode -eq $MyCode -or $_.IsSent) { "You" } else { $displayName }
                    $t = ""
                    if ($_.IsFS) { $t += "[FS]" }
                    if ($_.IsVerified) { $t += "[V]" }
                    if ($_.IsEncrypted -and -not $_.IsFS) { $t += "[E]" }
                    if ($_.Edited) { $t += "[ED]" }
                    if ($t) { $t = "$t " }
                    Write-Host ("[$($_.Time)] ${t}" + $who + ": $($_.Text)") -ForegroundColor White
                }
            } else { Write-Host "No messages yet." -ForegroundColor Yellow }
            continue
        }
        if ($input -eq "h") {
            Show-History -TargetCode $TargetCode | Out-Null
            continue
        }
        if ($input -eq "f") {
            $path = Read-Host "File path"
            if ($path) {
                $ok, $result = Send-File -TargetCode $TargetCode -FilePath $path
                Write-Host $result -ForegroundColor $(if ($ok) { "Green" } else { "Red" })
            }
            continue
        }
        if ($input -eq "v") {
            $dur = Read-Host "Duration in seconds (default 5)"
            if ($dur -eq "") { $dur = 5 }
            $ok, $result = Send-VoiceNote -TargetCode $TargetCode -Duration ([int]$dur)
            Write-Host $result -ForegroundColor $(if ($ok) { "Green" } else { "Red" })
            continue
        }
        if ($input -eq "d") {
            $idx = Read-Host "Message index to delete"
            try { $ok, $result = Delete-Message -Index ([int]$idx); Write-Host $result -ForegroundColor $(if ($ok) { "Green" } else { "Red" }) } catch { Write-Host "Invalid index" -ForegroundColor Red }
            continue
        }
        if ($input -eq "e") {
            $idx = Read-Host "Message index to edit"
            $newText = Read-Host "New text"
            try { $ok, $result = Edit-Message -Index ([int]$idx) -NewText $newText; Write-Host $result -ForegroundColor $(if ($ok) { "Green" } else { "Red" }) } catch { Write-Host "Invalid" -ForegroundColor Red }
            continue
        }
        if ($input -eq "p") {
            $inboxP = @(Load-Data $InboxFile)
            $convoP = @($inboxP | Where-Object { ($_.FromCode -eq $TargetCode -and $_.ToCode -eq $MyCode) -or ($_.FromCode -eq $MyCode -and $_.ToCode -eq $TargetCode) })
            if ($convoP.Count -eq 0) { Write-Host "No messages to pin." -ForegroundColor Yellow; continue }
            Write-Host "--- Messages (select index to pin/unpin) ---" -ForegroundColor DarkGray
            for ($pi = 0; $pi -lt $convoP.Count; $pi++) {
                $mp = $convoP[$pi]
                $pwho = if ($mp.IsSent -or $mp.FromCode -eq $MyCode) { "You" } else { $displayName }
                $pinTag = if ($mp.Pinned) { "[PIN] " } else { "" }
                Write-Host "[$pi] ${pinTag}$pwho : $($mp.Text)" -ForegroundColor White
            }
            $pIdx = Read-Host "Index to pin/unpin (c to cancel)"
            if ($pIdx -ne "c") {
                try { $actualIdx = [array]::IndexOf($inboxP, $convoP[[int]$pIdx]); $okP, $resultP = Pin-Message -Index $actualIdx; Write-Host $resultP -ForegroundColor $(if ($okP) { "Green" } else { "Red" }) } catch { Write-Host "Invalid" -ForegroundColor Red }
            }
            continue
        }
        if ($input -eq "") { continue }
        $ok, $result = Send-Message -TargetCode $TargetCode -Message $input
        if ($ok) {
            Write-Host $result -ForegroundColor Green
            $hasFSKey = [bool](Get-ECDHKeyForCode $TargetCode)
            $hasRSAKey = [bool](Get-PublicKeyForCode $TargetCode)
        } else { Write-Host $result -ForegroundColor Red }
    }
}

function Get-FriendStatus {
    param([string]$Code)
    $ip = Discover-IP $Code
    if ($ip) { return "Online" }
    if ($script:RelayAddr) { return "Relay" }
    return "Offline"
}

function Show-FriendsList {
    if ($script:Friends.Count -eq 0) { Write-Host "`nNo friends in your list." -ForegroundColor Yellow; return }
    Write-Host "`n=== Friends List ===" -ForegroundColor Cyan
    $myBio = Get-MyStatus
    if ($myBio) { Write-Host "Your status: $myBio" -ForegroundColor DarkYellow }
    for ($i = 0; $i -lt $script:Friends.Count; $i++) {
        $f = $script:Friends[$i]
        $keyStatus = ""
        if (Get-ECDHKeyForCode $f.Code) { $keyStatus = "[FS+E2E]" }
        elseif (Get-PublicKeyForCode $f.Code) { $keyStatus = "[RSA-E2E]" }
        else { $keyStatus = "[no key]" }
        $status = Get-FriendStatus $f.Code
        $statusColor = if ($status -eq "Online") { "Green" } elseif ($status -eq "Relay") { "Yellow" } else { "DarkGray" }
        Write-Host "[$i] $($f.Name)  |  $($f.Code)  $keyStatus  " -NoNewline -ForegroundColor White
        Write-Host "($status)" -ForegroundColor $statusColor
        $pinned = Get-PinnedMessages -TargetCode $f.Code
        if ($pinned.Count -gt 0) { Write-Host "      Pin: $($pinned[0].Text)" -ForegroundColor DarkYellow }
    }
}

function Add-NewFriend {
    Write-Host "`n=== Add Friend ===" -ForegroundColor Cyan
    $name = Read-Host "Enter friend's name"
    $code = Read-Host "Enter friend's code"
    $exists = $script:Friends | Where-Object { $_.Code -eq $code }
    if ($exists) { Write-Host "Already in friends." -ForegroundColor Yellow; return }
    $friend = [PSCustomObject]@{ Code = $code; Name = $name; Added = (Get-Date -Format "yyyy-MM-dd") }
    $script:Friends += $friend
    Save-Data $FriendsFile $script:Friends
    $discovered = Discover-IP $code
    Send-ECDHKeyExchange $code | Out-Null
    if ($discovered) { Write-Host "Friend added (online)" -ForegroundColor Green }
    else { Write-Host "Friend added (offline/relay)" -ForegroundColor Yellow }
}

function Remove-Friend {
    if ($script:Friends.Count -eq 0) { Write-Host "No friends." -ForegroundColor Yellow; return }
    Show-FriendsList
    $idx = Read-Host "`nNumber to remove (c to cancel)"
    if ($idx -eq "c") { return }
    $idx = [int]$idx
    if ($idx -ge 0 -and $idx -lt $script:Friends.Count) {
        $name = $script:Friends[$idx].Name
        $script:Friends = @($script:Friends[0..($idx-1)] + $script:Friends[($idx+1)..($script:Friends.Count-1)])
        Save-Data $FriendsFile $script:Friends
        Write-Host "'$name' removed." -ForegroundColor Green
    }
}

function Show-BlockedList {
    $blocked = @(Load-Data $BlockedFile)
    if ($blocked.Count -eq 0) { Write-Host "`nNo blocked users." -ForegroundColor Yellow; return }
    Write-Host "`n=== Blocked Codes ===" -ForegroundColor Red
    for ($i = 0; $i -lt $blocked.Count; $i++) { Write-Host "[$i] $($blocked[$i])" -ForegroundColor White }
}

function Block-Code {
    Write-Host "`n=== Block User ===" -ForegroundColor Red
    $code = Read-Host "Enter code to block"
    $blocked = @(Load-Data $BlockedFile)
    if ($blocked -contains $code) { Write-Host "Already blocked." -ForegroundColor Yellow; return }
    $blocked += $code
    Save-Data $BlockedFile $blocked
    Write-Host "Code $code blocked." -ForegroundColor Red
}

function Unblock-Code {
    $blocked = @(Load-Data $BlockedFile)
    if ($blocked.Count -eq 0) { Write-Host "None blocked." -ForegroundColor Yellow; return }
    Show-BlockedList
    $idx = Read-Host "`nNumber to unblock (c to cancel)"
    if ($idx -eq "c") { return }
    $idx = [int]$idx
    if ($idx -ge 0 -and $idx -lt $blocked.Count) {
        $code = $blocked[$idx]
        $blocked = @($blocked[0..($idx-1)] + $blocked[($idx+1)..($blocked.Count-1)])
        Save-Data $BlockedFile $blocked
        Write-Host "Code $code unblocked." -ForegroundColor Green
    }
}

# ========== GROUP UI ==========

function Show-GroupsMenu {
    $script:Groups = @(Load-Data $GroupsFile)
    Write-Host "`n=== Groups ===" -ForegroundColor Cyan
    if ($script:Groups.Count -eq 0) { Write-Host "No groups." -ForegroundColor Yellow }
    else {
        for ($i = 0; $i -lt $script:Groups.Count; $i++) {
            $g = $script:Groups[$i]
            Write-Host "[$i] $($g.Name)  |  Members: $($g.Members.Count)  |  ID: $($g.ID)" -ForegroundColor White
        }
    }
    Write-Host ""
    Write-Host "1. Create Group" -ForegroundColor White
    Write-Host "2. Join Group (enter ID)" -ForegroundColor White
    Write-Host "3. Chat in Group" -ForegroundColor White
    Write-Host "4. Manage Group Members" -ForegroundColor White
    Write-Host "0. Back" -ForegroundColor Red
    $choice = Read-Host "`nSelect"
    switch ($choice) {
        "1" {
            $name = Read-Host "Group name"
            if ($name) { $g = Create-Group $name; Write-Host "Created: $($g.Name) (ID: $($g.ID))" -ForegroundColor Green }
        }
        "2" {
            $gid = Read-Host "Group ID"
            $existing = $script:Groups | Where-Object { $_.ID -eq $gid }
            if (-not $existing) {
                $g = [PSCustomObject]@{ ID = $gid; Name = "Group-$gid"; Members = @($MyCode); Owner = ""; Created = (Get-Date -Format "yyyy-MM-dd HH:mm") }
                $script:Groups += $g
                Save-Groups
                Write-Host "Joined group ID $gid" -ForegroundColor Green
            } else { Write-Host "Already in this group." -ForegroundColor Yellow }
        }
        "3" {
            if ($script:Groups.Count -eq 0) { Write-Host "No groups." -ForegroundColor Yellow; break }
            for ($i = 0; $i -lt $script:Groups.Count; $i++) { Write-Host "[$i] $($script:Groups[$i].Name)" -ForegroundColor White }
            $gi = Read-Host "Select group"
            try { $g = $script:Groups[[int]$gi] } catch { break }
            Write-Host "`nGroup Chat: $($g.Name)" -ForegroundColor Cyan
            Write-Host "'back' to return, 'r' refresh" -ForegroundColor DarkGray
            while ($true) {
                $input = Read-Host "$($g.Name)>"
                if ($input -eq "back") { break }
                if ($input -eq "r") { continue }
                if ($input -eq "") { continue }
                $ok, $result = Group-SendMessage $g.ID $input
                Write-Host $result -ForegroundColor $(if ($ok) { "Green" } else { "Red" })
            }
        }
        "4" {
            if ($script:Groups.Count -eq 0) { Write-Host "No groups." -ForegroundColor Yellow; break }
            for ($i = 0; $i -lt $script:Groups.Count; $i++) { Write-Host "[$i] $($script:Groups[$i].Name)" -ForegroundColor White }
            $gi = Read-Host "Select group"
            try { $g = $script:Groups[[int]$gi] } catch { break }
            Write-Host "Members of $($g.Name): $($g.Members -join ', ')" -ForegroundColor Cyan
            Write-Host "1. Add member" -ForegroundColor White
            Write-Host "2. Remove member" -ForegroundColor White
            $sc = Read-Host "Choice"
            if ($sc -eq "1") {
                $code = Read-Host "Code to add"
                $ok, $result = Add-GroupMember $g.ID $code
                Write-Host $result -ForegroundColor $(if ($ok) { "Green" } else { "Red" })
            } elseif ($sc -eq "2") {
                $code = Read-Host "Code to remove"
                $ok, $result = Remove-GroupMember $g.ID $code
                Write-Host $result -ForegroundColor $(if ($ok) { "Green" } else { "Red" })
            }
        }
    }
    Read-Host "`nPress Enter"
}

# ========== SEARCH UI ==========

function Show-SearchUI {
    Write-Host "`n=== Search History ===" -ForegroundColor Cyan
    $query = Read-Host "Search text (or blank for all)"
    $fromCode = Read-Host "Filter by code (or blank)"
    $startDate = Read-Host "Start date (YYYY-MM-DD, or blank)"
    $endDate = Read-Host "End date (YYYY-MM-DD, or blank)"
    $results = Search-Messages -Query $query -FromCode $fromCode -StartDate $startDate -EndDate $endDate
    if ($results.Count -eq 0) { Write-Host "No results." -ForegroundColor Yellow }
    else {
        Write-Host "`nFound $($results.Count) message(s):" -ForegroundColor Green
        $results = $results | Sort-Object { "$($_.Date) $($_.Time)" }
        foreach ($m in $results) {
            $who = if ($m.IsSent -or $m.FromCode -eq $MyCode) { "You -> $($m.ToCode)" } else { $m.FromCode }
            $tag = ""
            if ($m.IsFS) { $tag += "[FS]" }
            if ($m.IsVerified) { $tag += "[V]" }
            if ($m.IsGroup) { $tag += "[G]" }
            if ($tag) { $tag = "$tag " }
            Write-Host "[$($m.Date) $($m.Time)] ${tag}$who : $($m.Text)" -ForegroundColor White
        }
    }
    Read-Host "`nPress Enter"
}

function Show-Downloads {
    Write-Host "`n=== Downloads ===" -ForegroundColor Cyan
    if (-not (Test-Path $DownloadsDir)) { Write-Host "No downloads." -ForegroundColor Yellow; return }
    $files = Get-ChildItem $DownloadsDir
    if ($files.Count -eq 0) { Write-Host "No downloads." -ForegroundColor Yellow }
    else {
        $files | ForEach-Object {
            $sizeKB = [math]::Round($_.Length / 1KB, 1)
            Write-Host "$($_.Name)  ($sizeKB KB, $($_.LastWriteTime.ToString('yyyy-MM-dd HH:mm')))" -ForegroundColor White
        }
    }
    Read-Host "`nPress Enter"
}

function Export-Chat {
    param([string]$TargetCode)
    $inbox = @(Load-Data $InboxFile)
    $msgs = @($inbox | Where-Object {
        ($_.FromCode -eq $TargetCode -and $_.ToCode -eq $MyCode) -or ($_.FromCode -eq $MyCode -and $_.ToCode -eq $TargetCode)
    })
    if ($msgs.Count -eq 0) { Write-Host "No messages to export." -ForegroundColor Yellow; return }
    $msgs = $msgs | Sort-Object { "$($_.Date) $($_.Time)" }
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $exportFile = Join-Path $DataDir "chat_export_${TargetCode}_${timestamp}.txt"
    $lines = @()
    $lines += "========================================"
    $lines += " Message App Chat Export"
    $lines += " Exported: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $lines += " Between: $MyCode and $TargetCode"
    $lines += "========================================"
    $lines += ""
    foreach ($m in $msgs) {
        $who = if ($m.IsSent -or $m.FromCode -eq $MyCode) { "You" } else { $TargetCode }
        $tag = ""
        if ($m.IsFS) { $tag += "[FS] " }
        if ($m.IsEncrypted -and -not $m.IsFS) { $tag += "[E] " }
        if ($m.IsVerified) { $tag += "[V] " }
        if ($m.IsVoice) { $tag += "[VN] " }
        if ($m.Edited) { $tag += "[ED] " }
        $lines += "[$($m.Date) $($m.Time)] ${tag}$who : $($m.Text)"
    }
    $lines += ""
    $lines += "--- End of export ($($msgs.Count) messages) ---"
    $lines -join "`r`n" | Set-Content $exportFile -Force
    Write-Host "Chat exported to: $exportFile ($($msgs.Count) messages)" -ForegroundColor Green
}

# ========== MAIN LOOP ==========

function Cleanup-StaleTransfers {
    $cutoff = (Get-Date).AddMinutes(-5)
    $staleFileKeys = @($script:PendingFileTransfer.Keys | Where-Object { $script:PendingFileTransfer[$_].Received -lt $cutoff })
    foreach ($k in $staleFileKeys) { $script:PendingFileTransfer.Remove($k) }
    $staleVoiceKeys = @($script:VoiceChunkBuffer.Keys | Where-Object { $script:VoiceChunkBuffer[$_].Received -lt $cutoff })
    foreach ($k in $staleVoiceKeys) { $script:VoiceChunkBuffer.Remove($k) }
}

try {
    $lastRelayPoll = [DateTime]::MinValue
    $lastNewMsgCheck = [DateTime]::MinValue
    $lastTransferCleanup = [DateTime]::MinValue
    $script:HasNewMessages = $false
    while ($true) {
        if ($script:RelayAddr -and ([DateTime]::Now - $lastRelayPoll).TotalSeconds -ge 3) {
            Push-RelayMessages
            $lastRelayPoll = [DateTime]::Now
        }

        if (([DateTime]::Now - $lastNewMsgCheck).TotalSeconds -ge 10) {
            $checkInbox = @(Load-Data $InboxFile)
            $script:HasNewMessages = ($checkInbox | Where-Object { -not $_.Read }).Count -gt 0
            $lastNewMsgCheck = [DateTime]::Now
        }

        if (([DateTime]::Now - $lastTransferCleanup).TotalSeconds -ge 60) {
            Cleanup-StaleTransfers
            $lastTransferCleanup = [DateTime]::Now
        }

        Show-Header
        Show-MainMenu
        $choice = Read-Host "`nSelect option"

        switch ($choice) {
            "1" {
                Write-Host "`n1. Message a friend" -ForegroundColor White
                Write-Host "2. Message by code" -ForegroundColor White
                $sub = Read-Host "Choice"
                if ($sub -eq "1") {
                    if ($script:Friends.Count -eq 0) { Write-Host "No friends. Add one first!" -ForegroundColor Yellow; Read-Host "Press Enter"; continue }
                    Show-FriendsList
                    $fIdx = Read-Host "`nSelect friend number"
                    try { $f = $script:Friends[[int]$fIdx]; Chat-Session -TargetCode $f.Code -TargetName $f.Name }
                    catch { Write-Host "Invalid." -ForegroundColor Red; Read-Host "Press Enter" }
                } elseif ($sub -eq "2") { $code = Read-Host "Enter target code"; Chat-Session -TargetCode $code }
            }
            "2" { Show-Inbox; Read-Host "`nPress Enter" }
            "3" { Show-FriendsList; Read-Host "`nPress Enter" }
            "4" { Add-NewFriend; Read-Host "`nPress Enter" }
            "5" { Remove-Friend; Read-Host "`nPress Enter" }
            "6" { Show-BlockedList; Read-Host "`nPress Enter" }
            "7" { Block-Code; Read-Host "`nPress Enter" }
            "8" { Unblock-Code; Read-Host "`nPress Enter" }
            "9" {
                Write-Host "`n=== Your Info ===" -ForegroundColor Cyan
                Write-Host "User:  $env:USERNAME" -ForegroundColor White
                Write-Host "Code:  $MyCode" -ForegroundColor White
                Write-Host "Friends: $($script:Friends.Count)" -ForegroundColor White
                $blockedCount = @(Load-Data $BlockedFile).Count
                Write-Host "Blocked: $blockedCount" -ForegroundColor White
                Write-Host "Known keys: $($script:KnownKeys.Count)" -ForegroundColor White
                $groupsCount = @(Load-Data $GroupsFile).Count
                Write-Host "Groups: $groupsCount" -ForegroundColor White
                $inboxCount = @(Load-Data $InboxFile).Count
                Write-Host "Total messages: $inboxCount" -ForegroundColor White
                $relayStatus = if ($script:RelayAddr) { "Connected to $($script:RelayAddr):$($script:RelayPortNum)" } else { "Not configured (-RelayAddress)" }
                Write-Host "Relay: $relayStatus" -ForegroundColor DarkYellow
                if ($RelayPort -gt 0) { Write-Host "Relay Server: Active on port $RelayPort" -ForegroundColor DarkYellow }
                if ($RelayPassword) { Write-Host "Relay: TLS + password auth" -ForegroundColor DarkYellow }
                if ($RelayObfuscate) { Write-Host "Obfuscation: metadata hidden (inbox IDs)" -ForegroundColor DarkYellow }
                if ($RelayProxy) { Write-Host "Proxy: $RelayProxy" -ForegroundColor DarkYellow }
                if ($RelayObfuscatePort) { Write-Host "HTTP Wrapper: active on port $RelayObfuscatePort" -ForegroundColor DarkYellow }
                if ($RegistryAddress) {
                    Write-Host "Directory: $RegistryAddress" -ForegroundColor DarkYellow
                    $regOk = Register-User
                    if ($regOk) { Write-Host "Directory status: registered" -ForegroundColor Green }
                    else { Write-Host "Directory status: unreachable" -ForegroundColor Red }
                }
                Write-Host "E2E: RSA-2048 + ECDH-P521 + AES-256 + RSA-SHA256" -ForegroundColor DarkYellow
                Write-Host "Rate limit: 10 messages/second" -ForegroundColor DarkYellow
                Write-Host "Downloads: $DownloadsDir" -ForegroundColor DarkYellow
                Read-Host "`nPress Enter"
            }
            "10" {
                if ($RegistryAddress) {
                    Write-Host "Re-registering with directory..." -ForegroundColor Yellow
                    $regOk = Register-User
                    if ($regOk) { Write-Host "Registered at $RegistryAddress" -ForegroundColor Green }
                    else { Write-Host "Registration failed." -ForegroundColor Red }
                } else { Write-Host "No directory address configured (-RegistryAddress)." -ForegroundColor Yellow }
                Read-Host "`nPress Enter"
            }
            "11" { Show-GroupsMenu }
            "12" {
                if ($script:Friends.Count -eq 0) { Write-Host "No friends." -ForegroundColor Yellow; Read-Host "Press Enter"; continue }
                Show-FriendsList
                $fIdx = Read-Host "`nSend file to friend number"
                try {
                    $f = $script:Friends[[int]$fIdx]
                    $path = Read-Host "File path"
                    if ($path) {
                        $ok, $result = Send-File -TargetCode $f.Code -FilePath $path
                        Write-Host $result -ForegroundColor $(if ($ok) { "Green" } else { "Red" })
                    }
                } catch { Write-Host "Invalid." -ForegroundColor Red }
                Read-Host "`nPress Enter"
            }
            "13" { Show-SearchUI }
            "14" { Show-Downloads }
            "15" {
                Show-Inbox; Read-Host "`nPress Enter"
            }
            "16" {
                Show-Inbox; Read-Host "`nPress Enter"
            }
            "17" {
                if ($script:Friends.Count -eq 0) { Write-Host "No friends." -ForegroundColor Yellow; Read-Host "Press Enter"; continue }
                Show-FriendsList
                $fIdx = Read-Host "`nSend voice note to friend number"
                try {
                    $f = $script:Friends[[int]$fIdx]
                    $dur = Read-Host "Duration in seconds (default 5)"
                    if ($dur -eq "") { $dur = 5 }
                    $ok, $result = Send-VoiceNote -TargetCode $f.Code -Duration ([int]$dur)
                    Write-Host $result -ForegroundColor $(if ($ok) { "Green" } else { "Red" })
                } catch { Write-Host "Invalid." -ForegroundColor Red }
                Read-Host "`nPress Enter"
            }
            "18" {
                if ($script:Friends.Count -eq 0) { Write-Host "No friends." -ForegroundColor Yellow; Read-Host "Press Enter"; continue }
                Show-FriendsList
                $fIdx = Read-Host "`nClear chat with friend number (c to cancel)"
                if ($fIdx -eq "c") { continue }
                try {
                    $f = $script:Friends[[int]$fIdx]
                    $deleted = Clear-Chat -TargetCode $f.Code
                    Write-Host "Cleared $deleted message(s) with $($f.Name)" -ForegroundColor Green
                } catch { Write-Host "Invalid." -ForegroundColor Red }
                Read-Host "`nPress Enter"
            }
            "19" {
                if ($script:Friends.Count -eq 0) { Write-Host "No friends." -ForegroundColor Yellow; Read-Host "Press Enter"; continue }
                Show-FriendsList
                $fIdx = Read-Host "`nExport chat with friend number (c to cancel)"
                if ($fIdx -eq "c") { continue }
                try {
                    $f = $script:Friends[[int]$fIdx]
                    Export-Chat -TargetCode $f.Code
                } catch { Write-Host "Invalid." -ForegroundColor Red }
                Read-Host "`nPress Enter"
            }
            "20" {
                Set-MyStatus
                Read-Host "`nPress Enter"
            }
            "0" { break }
            default { Write-Host "Invalid." -ForegroundColor Red; Start-Sleep -Seconds 1 }
        }
    }
} finally {
    foreach ($job in @($tcpJob, $udpJob, $relayServerJob)) {
        if ($job -and $job.State -eq "Running") { Stop-Job $job -ErrorAction SilentlyContinue; Remove-Job $job -ErrorAction SilentlyContinue }
    }
    Write-Host "`nGoodbye!" -ForegroundColor Cyan
}
