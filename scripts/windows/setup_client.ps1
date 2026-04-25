param(
  [string]$ArtifactDir = "",
  [string]$WireGuardExe = "C:\Program Files\WireGuard\wireguard.exe",
  [switch]$SkipImport
)

$ErrorActionPreference = "Stop"

function Write-Info([string]$Message) {
  Write-Host "[info] $Message"
}

function Write-Warn([string]$Message) {
  Write-Host "[warn] $Message" -ForegroundColor Yellow
}

if ([string]::IsNullOrWhiteSpace($ArtifactDir)) {
  $ArtifactDir = Join-Path -Path $PSScriptRoot -ChildPath "..\..\deploy\artifacts\windows"
}

$ArtifactDir = (Resolve-Path -Path $ArtifactDir).Path
Write-Info "Using artifact directory: $ArtifactDir"

$qsConfig = Join-Path $ArtifactDir "qs_client.json"
$wgConfig = Join-Path $ArtifactDir "wireguard_client.conf"

if (-not (Test-Path $qsConfig)) {
  throw "Missing qs_client.json at $qsConfig. Run: sudo bash scripts/install_server.sh export --target windows"
}

Write-Info "Validating qs_client.json"
Get-Content $qsConfig -Raw | ConvertFrom-Json | Out-Null

if (Test-Path $wgConfig) {
  Write-Info "WireGuard client config found: $wgConfig"
  if (-not $SkipImport) {
    if (Test-Path $WireGuardExe) {
      Write-Info "Attempting to import WireGuard config"
      try {
        $importOutput = & "$WireGuardExe" /importtunnelservice "$wgConfig" 2>&1
        if ($LASTEXITCODE -ne 0) {
          throw "WireGuard import returned exit code $LASTEXITCODE. Output: $importOutput"
        }
        Write-Info "WireGuard config imported. Open WireGuard UI to activate the tunnel."
      }
      catch {
        Write-Warn "WireGuard import failed: $($_.Exception.Message)"
      }
    }
    else {
      Write-Warn "WireGuard executable not found at $WireGuardExe. Import manually in WireGuard UI."
    }
  }
}
else {
  Write-Warn "wireguard_client.conf not found. Skip WireGuard import."
}

Write-Host ""
Write-Host "Next steps:"
Write-Host "1) Fill vless_config or xray_bridge_inbound in qs_client.json."
Write-Host "2) Place qs_client.json next to main_client.py on your Windows machine."
Write-Host "3) Run: python main_client.py"
Write-Host "4) Activate WireGuard profile (if using WireGuard backend)."
