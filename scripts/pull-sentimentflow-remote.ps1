param(
  [string]$ComposeFile = 'docker-compose.yml',
  [string[]]$Services = @('app', 'sentimentflow', 'sentimentflow-frontend'),
  [switch]$InspectOnly,
  [switch]$Up
)

$ErrorActionPreference = 'Stop'

$RootDir = Resolve-Path (Join-Path $PSScriptRoot '..')
Set-Location $RootDir

$ComposePath = Join-Path $RootDir $ComposeFile
if (-not (Test-Path $ComposePath)) {
  throw "Compose file not found: $ComposePath"
}

function Invoke-Docker {
  param([string[]]$DockerArgs)

  & docker @DockerArgs
  if ($LASTEXITCODE -ne 0) {
    throw "docker $($DockerArgs -join ' ') failed with exit code $LASTEXITCODE"
  }
}

function Get-ServiceConfig {
  param(
    [object]$Config,
    [string]$ServiceName
  )

  $property = $Config.services.PSObject.Properties[$ServiceName]
  if (-not $property) {
    throw "Service not found in ${ComposeFile}: $ServiceName"
  }

  return $property.Value
}

function Show-ImageLayers {
  param([string]$Image)

  Write-Host ""
  Write-Host "Inspecting remote image: $Image"

  $manifest = Get-RemoteManifest -Image $Image

  if ($manifest.manifests) {
    $platformManifest = @($manifest.manifests) |
      Where-Object { $_.platform.os -eq 'linux' -and $_.platform.architecture -eq 'amd64' } |
      Select-Object -First 1

    if (-not $platformManifest) {
      $platformManifest = @($manifest.manifests) | Select-Object -First 1
    }

    $manifest = Get-RemoteManifest -Image $Image -Reference $platformManifest.digest
  }

  $layers = @($manifest.layers)
  $totalBytes = ($layers | Measure-Object -Property size -Sum).Sum

  Write-Host ("  layers: {0}" -f $layers.Count)
  Write-Host ("  total:  {0:n2} MB" -f ($totalBytes / 1MB))

  $index = 1
  foreach ($layer in $layers) {
    Write-Host ("  layer {0,2}: {1,9:n2} MB  {2}" -f $index, ($layer.size / 1MB), $layer.digest)
    $index++
  }
}

function Get-RemoteManifest {
  param(
    [string]$Image,
    [string]$Reference
  )

  if ($Image -notmatch '^ghcr\.io/(.+?)(?::([^:@]+))?(?:@(.+))?$') {
    $manifestJson = docker manifest inspect $Image
    if ($LASTEXITCODE -ne 0) {
      throw "docker manifest inspect failed for $Image"
    }
    return $manifestJson | ConvertFrom-Json
  }

  $repository = $Matches[1]
  $tag = $Matches[2]
  $digest = $Matches[3]

  if (-not $Reference) {
    if ($digest) {
      $Reference = $digest
    }
    elseif ($tag) {
      $Reference = $tag
    }
    else {
      $Reference = 'latest'
    }
  }

  $tokenUri = "https://ghcr.io/token?scope=repository:${repository}:pull"
  $token = (Invoke-RestMethod -Uri $tokenUri).token
  $headers = @{
    Authorization = "Bearer $token"
    Accept = 'application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'
  }

  return Invoke-RestMethod -Headers $headers -Uri "https://ghcr.io/v2/$repository/manifests/$Reference"
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  throw 'Docker CLI was not found in PATH.'
}

$configJson = docker compose -f $ComposePath config --format json
if ($LASTEXITCODE -ne 0) {
  throw "docker compose config failed for $ComposeFile"
}

$config = $configJson | ConvertFrom-Json
$images = New-Object System.Collections.Generic.List[string]

foreach ($service in $Services) {
  $serviceConfig = Get-ServiceConfig -Config $config -ServiceName $service
  if (-not $serviceConfig.image) {
    Write-Host "Skipping $service because it has no image."
    continue
  }

  if (-not $images.Contains($serviceConfig.image)) {
    $images.Add($serviceConfig.image)
  }
}

Write-Host "Remote images to pull from ${ComposeFile}:"
foreach ($image in $images) {
  Write-Host "  - $image"
}

foreach ($image in $images) {
  Show-ImageLayers -Image $image
}

if ($InspectOnly) {
  return
}

Write-Host ""
Write-Host 'Starting pull with plain progress.'
Write-Host 'If another terminal is already running docker compose up/pull for the same backend image, stop it first; Docker may wait on the existing pull without printing layer progress.'

$env:COMPOSE_PROGRESS = 'plain'
$pullArgs = @('compose', '--progress', 'plain', '-f', $ComposePath, 'pull', '--policy', 'always') + $Services
Invoke-Docker -DockerArgs $pullArgs

if ($Up) {
  Write-Host ""
  Write-Host 'Starting stack without pulling again.'
  $upArgs = @('compose', '-f', $ComposePath, 'up', '-d', '--pull', 'never', '--no-build')
  Invoke-Docker -DockerArgs $upArgs
}
