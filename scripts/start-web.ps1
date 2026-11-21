$ErrorActionPreference = 'Stop'
try {
    Set-Location (Split-Path $PSScriptRoot -Parent)
    $flutter = Get-Command flutter -ErrorAction SilentlyContinue
    if (-not $flutter) { throw 'Flutter SDK missing. Install Flutter and add its bin directory to PATH.' }
    if (-not (Test-Path '.dart_tool/package_config.json')) {
        throw 'Dependencies missing. Run flutter pub get in this project first (network access may be needed).'
    }

    $defaults = (Get-Content 'assets/config/app_config.json' -Raw -Encoding UTF8 | ConvertFrom-Json).defaults
    $deriveOrigin = [bool]$env:API_BASE_URL
    $endpoints = @{
        API_BASE_URL = $defaults.apiBaseUrl
        WS_BASE_URL = if ($deriveOrigin) { '' } else { $defaults.wsBaseUrl }
        STORAGE_BASE_URL = if ($deriveOrigin) { '' } else { $defaults.storageBaseUrl }
    }
    foreach ($name in @('API_BASE_URL', 'WS_BASE_URL', 'STORAGE_BASE_URL')) {
        $override = [Environment]::GetEnvironmentVariable($name)
        if ($override) { $endpoints[$name] = $override }
        if ($name -ne 'API_BASE_URL' -and -not $endpoints[$name]) { continue }
        [Uri]$uri = $null
        $schemes = if ($name -eq 'WS_BASE_URL') { @('ws', 'wss') } else { @('http', 'https') }
        $address = [string]$endpoints[$name]
        if ($address -match '[\\\s?#]' -or $address -notmatch '^[a-z]+://[^/]+' -or
            $address -match '^[a-z]+://[^/]*@' -or
            -not [Uri]::TryCreate($address, [UriKind]::Absolute, [ref]$uri) -or
            $uri.Scheme -notin $schemes -or -not $uri.Host -or $uri.Port -eq 0) {
            throw "$name must be an absolute base URL without credentials, query, or fragment."
        }
    }

    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 30004)
    try { $listener.Start() }
    catch { throw 'Port 30004 is unavailable. Stop the process using it before restarting this script.' }
    finally { $listener.Stop() }

    Write-Host 'Flutter Web: http://127.0.0.1:30004 (open manually once Flutter is ready).'
    Write-Host 'Saved endpoint settings override these build defaults. Start the selected backend separately.'
    & $flutter.Source run -d web-server --web-hostname 127.0.0.1 --web-port 30004 --no-pub `
        "--dart-define=API_BASE_URL=$($endpoints.API_BASE_URL)" `
        "--dart-define=WS_BASE_URL=$($endpoints.WS_BASE_URL)" `
        "--dart-define=STORAGE_BASE_URL=$($endpoints.STORAGE_BASE_URL)"
    exit $LASTEXITCODE
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
