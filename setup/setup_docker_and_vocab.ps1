# =============================================================================
# setup/setup_docker_and_vocab.ps1
#
# Automated Docker and OMOP vocabulary setup for OMOP_Dev environment (Windows).
#
# PURPOSE
# -------
# This script automates the tedious Docker and vocabulary setup steps:
#   1. Creates OMOP_Dev folder structure
#   2. Generates .env file with SA password
#   3. Creates docker-compose.yml
#   4. Starts SQL Server container
#   5. Creates omop_synth database
#   6. Provides guidance for Athena vocabulary download
#
# USAGE
# -----
#   powershell -ExecutionPolicy Bypass -File setup/setup_docker_and_vocab.ps1
#
# PREREQUISITES
# -------------
#   - Docker Desktop installed and running
#   - PowerShell 5.1 or higher
#   - Internet connection
#   - ~35 GB disk space
#
# =============================================================================

# Strict mode
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Color codes for output
function Write-Status {
  Write-Host "[INFO] $args" -ForegroundColor Cyan
}

function Write-Success {
  Write-Host "[✓] $args" -ForegroundColor Green
}

function Write-Warning {
  Write-Host "[!] $args" -ForegroundColor Yellow
}

function Write-Error {
  Write-Host "[✗] $args" -ForegroundColor Red
}

# =============================================================================
# 0. Detect OS and set variables
# =============================================================================

Write-Status "Detecting OS..."
$OS = "Windows"
$DOCKER_IMAGE = "mcr.microsoft.com/mssql/server:2022-latest"
Write-Success "Detected OS: $OS"

# =============================================================================
# 1. Check prerequisites
# =============================================================================

Write-Status "Checking prerequisites..."

# Check Docker
try {
  $dockerVersion = docker --version
  Write-Success "Docker found: $dockerVersion"
} catch {
  Write-Error "Docker is not installed or not in PATH"
  Write-Host "  Install from: https://www.docker.com/products/docker-desktop"
  exit 1
}

# Check Docker running
try {
  docker ps *> $null
  Write-Success "Docker is running"
} catch {
  Write-Error "Docker Desktop is not running"
  Write-Host "  Start Docker Desktop and try again"
  exit 1
}

# =============================================================================
# 2. Create OMOP_Dev folder structure
# =============================================================================

Write-Status "Setting up OMOP_Dev folder structure..."

$PARENT_DIR = "$env:USERPROFILE\OMOP_Dev"

# Check if already exists
if (Test-Path $PARENT_DIR) {
  Write-Warning "OMOP_Dev folder already exists at: $PARENT_DIR"
  $response = Read-Host "Use existing folder? (y/n)"
  if ($response -ne "y" -and $response -ne "Y") {
    Write-Error "Aborting setup"
    exit 1
  }
} else {
  New-Item -ItemType Directory -Path $PARENT_DIR -Force | Out-Null
  Write-Success "Created OMOP_Dev folder: $PARENT_DIR"
}

# =============================================================================
# 3. Create .env file with SA password
# =============================================================================

Write-Status "Creating .env file with SQL Server SA password..."

$ENV_FILE = "$PARENT_DIR\.env"

if (Test-Path $ENV_FILE) {
  Write-Warning ".env file already exists"
  $response = Read-Host "Use existing password? (y/n)"
  if ($response -eq "y" -or $response -eq "Y") {
    $SA_PASSWORD = (Get-Content $ENV_FILE | Select-String "MSSQL_SA_PASSWORD=" | ForEach-Object { $_.ToString().Split("=")[1] })
    Write-Success "Using existing password from .env"
  } else {
    # Generate new password
    $timestamp = (Get-Date).AddDays(0).GetHashCode().ToString().Substring(0, 5)
    $SA_PASSWORD = "SqlServer@2024$timestamp"
    "MSSQL_SA_PASSWORD=$SA_PASSWORD" | Out-File -FilePath $ENV_FILE -Encoding ASCII
    Write-Success "Created .env with new password"
  }
} else {
  # Generate strong password
  $timestamp = (Get-Date).Ticks.ToString().Substring(0, 5)
  $SA_PASSWORD = "SqlServer@2024"
  "MSSQL_SA_PASSWORD=$SA_PASSWORD" | Out-File -FilePath $ENV_FILE -Encoding ASCII
  Write-Success "Created .env with generated password: $SA_PASSWORD"
}

# =============================================================================
# 4. Create docker-compose.yml
# =============================================================================

Write-Status "Creating docker-compose.yml..."

$COMPOSE_FILE = "$PARENT_DIR\docker-compose.yml"

if (Test-Path $COMPOSE_FILE) {
  Write-Warning "docker-compose.yml already exists"
} else {
  $composeContent = @"
version: '3.9'

services:
  mssql:
    # Use mssql/server:2022-latest on Windows (AMD64)
    image: mcr.microsoft.com/mssql/server:2022-latest
    container_name: mssql_dev
    restart: unless-stopped
    ports:
      - "`${MSSQL_PORT:-1433}:1433"
    environment:
      ACCEPT_EULA: "1"
      MSSQL_SA_PASSWORD: "`${MSSQL_SA_PASSWORD}"
    volumes:
      - mssql_data:/var/opt/mssql
    healthcheck:
      test: ["CMD", "/opt/mssql-tools/bin/sqlcmd", "-S", "localhost", "-U", "sa", "-P", "`${MSSQL_SA_PASSWORD}", "-Q", "SELECT 1"]
      interval: 15s
      timeout: 10s
      retries: 5
      start_period: 30s
    networks:
      - omop_dev_network

volumes:
  mssql_data:
    name: mssql_dev_data

networks:
  omop_dev_network:
    name: omop_dev_network
"@
  $composeContent | Out-File -FilePath $COMPOSE_FILE -Encoding UTF8
  Write-Success "Created docker-compose.yml"
}

# =============================================================================
# 5. Start SQL Server container
# =============================================================================

Write-Status "Starting SQL Server container..."

Push-Location $PARENT_DIR

try {
  # Check if container is already running
  $runningContainer = docker ps --format "{{.Names}}" | Where-Object { $_ -eq "mssql_dev" }
  if ($runningContainer) {
    Write-Success "SQL Server container (mssql_dev) is already running"
  } else {
    # Check if container exists but is stopped
    $existingContainer = docker ps -a --format "{{.Names}}" | Where-Object { $_ -eq "mssql_dev" }
    if ($existingContainer) {
      Write-Status "Starting existing container..."
    } else {
      Write-Status "Creating and starting new container..."
    }
    
    docker compose up -d
    
    # Wait for container to be healthy
    Write-Status "Waiting for SQL Server to be ready (~30 seconds)..."
    $SA_PASSWORD = (Get-Content $ENV_FILE | Select-String "MSSQL_SA_PASSWORD=" | ForEach-Object { $_.ToString().Split("=")[1] })
    
    $maxAttempts = 20
    $attempt = 0
    while ($attempt -lt $maxAttempts) {
      try {
        docker exec mssql_dev `
          /opt/mssql-tools/bin/sqlcmd `
          -S localhost -U SA -P "$SA_PASSWORD" `
          -Q "SELECT 1" *> $null
        Write-Success "SQL Server is ready!"
        break
      } catch {
        Write-Host -NoNewline "."
        Start-Sleep -Seconds 2
        $attempt++
      }
    }
    
    if ($attempt -eq $maxAttempts) {
      Write-Error "SQL Server failed to start after 60 seconds"
      Write-Host "  Check logs: docker compose logs mssql"
      exit 1
    }
  }
} finally {
  Pop-Location
}

# =============================================================================
# 6. Create omop_synth database
# =============================================================================

Write-Status "Creating omop_synth database..."

$SA_PASSWORD = (Get-Content $ENV_FILE | Select-String "MSSQL_SA_PASSWORD=" | ForEach-Object { $_.ToString().Split("=")[1] })

docker exec mssql_dev `
  /opt/mssql-tools/bin/sqlcmd `
  -S localhost -U SA -P "$SA_PASSWORD" `
  -Q "IF DB_ID('omop_synth') IS NULL CREATE DATABASE omop_synth;" *> $null

Write-Success "omop_synth database created (or already exists)"

# =============================================================================
# 7. Create omop_vocab folder structure
# =============================================================================

Write-Status "Creating omop_vocab folder structure..."

$VOCAB_DIR = "$PARENT_DIR\omop_vocab"
if (!(Test-Path $VOCAB_DIR)) {
  New-Item -ItemType Directory -Path $VOCAB_DIR -Force | Out-Null
}

if (!(Test-Path "$VOCAB_DIR\CONCEPT.csv")) {
  Write-Warning "OMOP vocabulary files not found in $VOCAB_DIR"
}

# =============================================================================
# 8. Summary and next steps
# =============================================================================

Write-Host ""
Write-Host "╔════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║                 Docker Setup Complete!                              ║" -ForegroundColor Green
Write-Host "╚════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Green

Write-Host ""
Write-Host "✓ Setup Summary:" -ForegroundColor Cyan
Write-Host "  • OS detected: $OS"
Write-Host "  • OMOP_Dev folder: $PARENT_DIR"
Write-Host "  • .env file: $ENV_FILE"
Write-Host "  • Docker Compose: $COMPOSE_FILE"
Write-Host "  • SQL Server container: mssql_dev (running)"
Write-Host "  • Database: omop_synth (created)"

Write-Host ""
Write-Host "→ Next Steps:" -ForegroundColor Yellow

Write-Host ""
Write-Host "1. " -ForegroundColor Cyan -NoNewline
Write-Host "Download OMOP Vocabulary from Athena:"
Write-Host "   • Go to https://athena.ohdsi.org"
Write-Host "   • Download vocabulary bundle (SNOMED, RxNorm, LOINC, etc.)"
Write-Host "   • Extract to: $VOCAB_DIR"

Write-Host ""
Write-Host "2. " -ForegroundColor Cyan -NoNewline
Write-Host "Rebuild CPT-4 codes (optional, requires UMLS API key):"
Write-Host "   • Get free UMLS API key: https://uts.nlm.nih.gov"
Write-Host "   • Run: cd $VOCAB_DIR && cpt.bat YOUR_UMLS_API_KEY"

Write-Host ""
Write-Host "3. " -ForegroundColor Cyan -NoNewline
Write-Host "Verify SQL Server connection:"
Write-Host "   • Install VS Code mssql extension"
Write-Host "   • Server: localhost,1433"
Write-Host "   • Username: SA"
Write-Host "   • Password: $SA_PASSWORD"

Write-Host ""
Write-Host "4. " -ForegroundColor Cyan -NoNewline
Write-Host "Clone your study repository:"
Write-Host "   • cd $PARENT_DIR"
Write-Host "   • git clone https://github.com/<your-org>/<your-study>.git"
Write-Host "   • cd <your-study>"
Write-Host "   • Open in VS Code → Reopen in Container"

Write-Host ""
Write-Host "Important Notes:" -ForegroundColor Yellow
Write-Host "  • Keep .env file secure (contains SA password)"
Write-Host "  • Never commit .env to version control"
Write-Host "  • Vocabulary load takes 30-60 minutes (one-time cost)"
Write-Host "  • This setup is reusable for multiple studies"

Write-Host ""
Write-Host "For more details:" -ForegroundColor Cyan
Write-Host "  • See: OMOP_Dev\docs\SETUP.md"
Write-Host "  • Or run: Rscript workflow\01_setup_synthea_etl_qc_env.R"

Write-Host ""
Write-Success "Setup script completed successfully!"
