<#
  Windows (native PowerShell) entry point. Same job as ./start.sh: bring up
  Paperless, the reactor, Connect and the wiring, then open the browser.

      .\start.ps1

  If you use WSL2, prefer ./start.sh inside the distro -- it is the path that
  gets exercised most. This script exists so Windows without WSL works too.

  docker compose down     stops everything (add -v to wipe data)
#>
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot

function Fail($msg) { Write-Host ""; Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }

# --- .env -------------------------------------------------------------------
# Compose reads .env by itself. This script must read the SAME file or the URLs
# it probes and opens drift from the ports the containers actually publish.
$envVars = @{}
if (Test-Path .env) {
  Get-Content .env | ForEach-Object {
    if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
      $envVars[$Matches[1]] = $Matches[2].Trim().Trim('"').Trim("'")
    }
  }
}
function Cfg($name, $fallback) {
  if ($envVars.ContainsKey($name) -and $envVars[$name]) { return $envVars[$name] }
  return $fallback
}

$connectPort     = Cfg 'CONNECT_HOST_PORT'     '3000'
$switchboardPort = Cfg 'SWITCHBOARD_HOST_PORT' '4001'
$paperlessPort   = Cfg 'PAPERLESS_HOST_PORT'   '8000'
$driveUrl    = "http://localhost:$connectPort/?driveUrl=http://localhost:$switchboardPort/d/billing"
$paperlessUi = "http://localhost:$paperlessPort"

# --- preflight --------------------------------------------------------------
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  Fail "Docker is not installed. Install Docker Desktop: https://docs.docker.com/desktop/install/windows-install/"
}
docker info *> $null
if ($LASTEXITCODE -ne 0) { Fail "Docker is installed but the daemon is not running -- start Docker Desktop, then re-run." }

if (-not (Test-Path .env)) {
  Copy-Item .env.example .env
  Write-Host "Created .env from .env.example."
  Write-Host "Fill in PAPERLESS_AI_API_KEY, then run this again."
  exit 1
}
if (-not (Cfg 'PAPERLESS_AI_API_KEY' '')) {
  Fail "PAPERLESS_AI_API_KEY is empty in .env -- fill it in, then run this again."
}

New-Item -ItemType Directory -Force -Path .local\consume | Out-Null

# --- up ---------------------------------------------------------------------
# --wait blocks until every service is healthy AND the one-shot bootstrap has
# exited successfully, so when this returns the stack is genuinely wired.
Write-Host "==> Starting the stack (first run pulls ~2.6 GB and installs packages)"
docker compose up -d --wait
if ($LASTEXITCODE -ne 0) {
  Write-Host ""
  Write-Host "Bring-up failed. If the message mentions ports, something already holds"
  Write-Host "one of: switchboard $switchboardPort, connect $connectPort, paperless $paperlessPort."
  Write-Host "Find the owner and either stop it or pick another port in .env:"
  Write-Host "  Get-NetTCPConnection -LocalPort $switchboardPort | Select-Object LocalPort,OwningProcess"
  Write-Host "  Get-Process -Id <pid> | Select-Object ProcessName"
  Write-Host "Connect's default-drive URL follows SWITCHBOARD_HOST_PORT automatically."
  exit 1
}

# --- assert the reactor really loaded the packages ---------------------------
# Packages load from the registry CDN at startup, and both failure modes are
# quiet: a bad package list logs "Loading packages: , /app" and registers
# nothing, and an image tag that does not match the reactor line the packages
# were built against fails supergraph composition for EVERY subgraph. Either
# way you would get an empty drive with no obvious cause.
Write-Host "==> Verifying the reactor loaded the invoice document model"
$ok = $false
try {
  $body = '{"query":"{ __schema { types { name } } }"}'
  $resp = Invoke-WebRequest -Uri "http://localhost:$switchboardPort/graphql" -Method Post `
            -ContentType 'application/json' -Body $body -TimeoutSec 20 -UseBasicParsing
  $ok = $resp.Content -match '"Invoice"'
} catch { $ok = $false }

if (-not $ok) {
  Write-Host ""
  Write-Host "ERROR: the reactor is not serving the Invoice type." -ForegroundColor Red
  Write-Host ""
  Write-Host "  Check, in this order:"
  Write-Host "    1. did the packages load?"
  Write-Host "         docker compose logs switchboard | Select-String 'Loaded document models'"
  Write-Host "    2. did supergraph composition fail?"
  Write-Host "         docker compose logs switchboard | Select-String 'Unknown type'"
  Write-Host "       That means PH_IMAGE_TAG does not match the reactor line the"
  Write-Host "       packages were built against (billing targets 6.2.2-dev.53)."
  Write-Host "    3. is it crash-looping?"
  Write-Host "         docker inspect paperless-billing-switchboard-1 --format '{{.RestartCount}}'"
  exit 1
}

# --- browser ----------------------------------------------------------------
Write-Host "==> Opening Paperless ($paperlessUi, admin/paperless) and Connect"
Start-Process $paperlessUi
Start-Process $driveUrl

Write-Host ""
Write-Host "Everything is up."
Write-Host ""
Write-Host "  Paperless    $paperlessUi   (admin / paperless)"
Write-Host "  Connect      http://localhost:$connectPort"
Write-Host "  Reactor API  http://localhost:$switchboardPort/graphql"
Write-Host ""
Write-Host "Upload a PDF containing the word ""invoice"" at $paperlessUi, or drop it"
Write-Host "into .local\consume\ -- it appears in the Billing drive once OCR and"
Write-Host "extraction finish. PDFs only: Office formats need tika + gotenberg"
Write-Host "(commented out in docker-compose.yml)."
Write-Host ""
Write-Host "  Follow the pipeline   docker compose logs -f switchboard"
Write-Host "  Re-run the wiring     docker compose run --rm bootstrap"
Write-Host "  Stop                  docker compose down"
