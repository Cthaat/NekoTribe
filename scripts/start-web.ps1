$ErrorActionPreference = 'Stop'
try {
    Set-Location (Split-Path $PSScriptRoot -Parent)
    $flutter = Get-Command flutter -ErrorAction SilentlyContinue
    if (-not $flutter) { throw 'Flutter SDK missing. Install Flutter and add its bin directory to PATH.' }
    if (-not (Test-Path '.dart_tool/package_config.json')) {
        throw 'Dependencies missing. Run flutter pub get in this project first (network access may be needed).'
    }

    $defaults = (Get-Content 'assets/config/app_config.json' -Raw -Encoding UTF8 | ConvertFrom-Json).defaults
    $endpoints = @{
        API_BASE_URL = $defaults.apiBaseUrl
        WS_BASE_URL = $defaults.wsBaseUrl
        STORAGE_BASE_URL = $defaults.storageBaseUrl
    }
    foreach ($name in @('API_BASE_URL', 'WS_BASE_URL', 'STORAGE_BASE_URL')) {
        $override = [Environment]::GetEnvironmentVariable($name)
        if ($override) { $endpoints[$name] = $override }
        $uri = $null
        $schemes = if ($name -eq 'WS_BASE_URL') { @('ws', 'wss') } else { @('http', 'https') }
        if ($endpoints[$name] -match '\s' -or
            -not [Uri]::TryCreate($endpoints[$name], [UriKind]::Absolute, [ref]$uri) -or
            $uri.Scheme -notin $schemes -or -not $uri.Host -or $uri.UserInfo -or
            $uri.AbsolutePath -ne '/' -or $uri.Query -or $uri.Fragment) {
            throw "$name must be an origin, without /api/v2, /_ws, /storage, credentials, query, or fragment."
        }
    }

    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 30004)
    try { $listener.Start() }
    catch { throw 'Port 30004 is unavailable. Stop the process using it before restarting this script.' }
    finally { $listener.Stop() }

    Write-Host 'Flutter Web: http://127.0.0.1:30004 (open manually once Flutter is ready).'
    Write-Host 'Saved endpoint settings override these build defaults. Nuxt must be started separately.'
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
