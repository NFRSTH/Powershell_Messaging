param(
    [int]$Port = 8080,
    [string]$DataDir = "",
    [switch]$ShowCode
)

if (-not $DataDir) { $DataDir = Join-Path $env:USERPROFILE ".message_app" }
if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }
$RegistryFile = Join-Path $DataDir "registry.json"

function Load-Registry {
    try { if (Test-Path $RegistryFile) { $c = Get-Content $RegistryFile -Raw -ErrorAction Stop; if ($c) { return ($c | ConvertFrom-Json -ErrorAction Stop) } } } catch {}
    return @()
}

function Save-Registry {
    param($Data)
    $Data | ConvertTo-Json -Depth 10 | Set-Content $RegistryFile -Force -ErrorAction SilentlyContinue
}

if ($ShowCode) {
    Write-Host "Registry Server Code: REG-SRV-$(Get-Random -Maximum 99999)" -ForegroundColor Green
    exit
}

try {
    $listener = New-Object System.Net.HttpListener
    try {
        $listener.Prefixes.Add("http://+:$Port/")
        $listener.Start()
        Write-Host "Registry server running on http://0.0.0.0:$Port" -ForegroundColor Green
    } catch {
        Write-Host "Could not bind to all interfaces (admin required). Binding to localhost only." -ForegroundColor Yellow
        $listener = New-Object System.Net.HttpListener
        $listener.Prefixes.Add("http://localhost:$Port/")
        $listener.Start()
        Write-Host "Registry server running on http://localhost:$Port" -ForegroundColor Green
    }
    Write-Host "Data stored in: $RegistryFile" -ForegroundColor DarkGray

    while ($true) {
        $ctx = $listener.GetContext()
        $req = $ctx.Request
        $resp = $ctx.Response

        try {
            $reader = New-Object System.IO.StreamReader($req.InputStream)
            $body = $reader.ReadToEnd()
            $reader.Close()

            $path = $req.Url.AbsolutePath
            $status = 200
            $result = ""

            if ($req.HttpMethod -eq "POST" -and $path -eq "/register") {
                try {
                    $data = $body | ConvertFrom-Json
                    $reg = Load-Registry
                    $existing = $reg | Where-Object { $_.Code -eq $data.Code }
                    if ($existing -and -not $data.Signature) {
                        $status = 403
                        $result = '{"status":"error","message":"Signature required to update registration"}'
                    } else {
                        $entry = [PSCustomObject]@{
                            Code = $data.Code
                            PublicKey = $data.PublicKey
                            RelayAddress = $data.RelayAddress
                            DirectAddress = $data.DirectAddress
                            IP = $data.IP
                            LastSeen = (Get-Date).ToString("o")
                        }
                        if ($existing) {
                            $reg = @($reg | Where-Object { $_.Code -ne $data.Code })
                        }
                        $reg += $entry
                        Save-Registry $reg
                        $result = '{"status":"ok"}'
                    }
                } catch { $status = 400; $result = '{"status":"error","message":"Invalid JSON"}' }

            } elseif ($req.HttpMethod -eq "GET" -and $path -eq "/find") {
                $code = $req.QueryString["code"]
                if ($code) {
                    $reg = Load-Registry
                    $entry = $reg | Where-Object { $_.Code -eq $code }
                    if ($entry) {
                        $result = ($entry | ConvertTo-Json -Depth 5)
                    } else { $status = 200; $result = '{"status":"not_found"}' }
                } else { $status = 400; $result = '{"status":"error","message":"Missing code param"}' }

            } elseif ($req.HttpMethod -eq "GET" -and $path -eq "/list") {
                $reg = Load-Registry
                $codes = $reg | ForEach-Object { $_.Code }
                $result = (@{ codes = @($codes); count = $codes.Count } | ConvertTo-Json)

            } elseif ($req.HttpMethod -eq "GET" -and $path -eq "/ping") {
                $result = '{"status":"pong"}'

            } else { $status = 404; $result = '{"status":"error","message":"Not found"}' }

            $buffer = [System.Text.Encoding]::UTF8.GetBytes($result)
            $resp.ContentType = "application/json"
            $resp.StatusCode = $status
            $resp.ContentLength64 = $buffer.Length
            $resp.OutputStream.Write($buffer, 0, $buffer.Length)
        } catch {
            $result = @{ status = "error"; message = "Internal server error" } | ConvertTo-Json
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($result)
            $resp.ContentType = "application/json"
            $resp.StatusCode = 500
            $resp.ContentLength64 = $buffer.Length
            $resp.OutputStream.Write($buffer, 0, $buffer.Length)
        }
        $resp.OutputStream.Close()
    }
} catch { Write-Host "`n[!] Registry Server error: $_" -ForegroundColor Red }
