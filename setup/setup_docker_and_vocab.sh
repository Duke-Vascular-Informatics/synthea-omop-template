#!/usr/bin/env bash
# =============================================================================
# setup/setup_docker_and_vocab.sh
#
# Automated Docker and OMOP vocabulary setup for OMOP_Dev environment.
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
#   bash setup/setup_docker_and_vocab.sh
#
# PREREQUISITES
# -------------
#   - Docker Desktop installed and running
#   - Internet connection
#   - ~35 GB disk space
#
# =============================================================================

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'  # No Color

# Helper functions
print_status() {
  echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
  echo -e "${GREEN}[✓]${NC} $1"
}

print_warning() {
  echo -e "${YELLOW}[!]${NC} $1"
}

print_error() {
  echo -e "${RED}[✗]${NC} $1"
}

# =============================================================================
# 0. Detect OS and set variables
# =============================================================================

OS_TYPE=$(uname -s)
case "$OS_TYPE" in
  Darwin*)
    OS="macOS"
    DOCKER_IMAGE="mcr.microsoft.com/azure-sql-edge:latest"  # ARM64 native on M1/M2/M3
    ;;
  Linux*)
    OS="Linux"
    DOCKER_IMAGE="mcr.microsoft.com/azure-sql-edge:latest"  # or mssql/server:2022-latest
    ;;
  MINGW*|MSYS*|CYGWIN*)
    OS="Windows"
    DOCKER_IMAGE="mcr.microsoft.com/mssql/server:2022-latest"
    ;;
  *)
    print_error "Unknown OS: $OS_TYPE"
    exit 1
    ;;
esac

print_status "Detected OS: $OS"

# =============================================================================
# 1. Check prerequisites
# =============================================================================

print_status "Checking prerequisites..."

if ! command -v docker &> /dev/null; then
  print_error "Docker is not installed or not in PATH"
  echo "  Install from: https://www.docker.com/products/docker-desktop"
  exit 1
fi
print_success "Docker found: $(docker --version)"

if ! docker ps &> /dev/null; then
  print_error "Docker Desktop is not running"
  echo "  Start Docker Desktop and try again"
  exit 1
fi
print_success "Docker is running"

# =============================================================================
# 2. Create OMOP_Dev folder structure
# =============================================================================

print_status "Setting up OMOP_Dev folder structure..."

# Determine parent folder location
PARENT_DIR="${HOME}/OMOP_Dev"
if [ "$OS" = "Windows" ]; then
  PARENT_DIR="${USERPROFILE}/OMOP_Dev"
fi

# Check if already exists
if [ -d "$PARENT_DIR" ]; then
  print_warning "OMOP_Dev folder already exists at: $PARENT_DIR"
  read -p "Use existing folder? (y/n) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    print_error "Aborting setup"
    exit 1
  fi
else
  mkdir -p "$PARENT_DIR"
  print_success "Created OMOP_Dev folder: $PARENT_DIR"
fi

# =============================================================================
# 3. Create .env file with SA password
# =============================================================================

print_status "Creating .env file with SQL Server SA password..."

ENV_FILE="$PARENT_DIR/.env"

if [ -f "$ENV_FILE" ]; then
  print_warning ".env file already exists"
  read -p "Use existing password? (y/n) " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    EXISTING_PASSWORD=$(grep MSSQL_SA_PASSWORD "$ENV_FILE" | cut -d'=' -f2)
    print_success "Using existing password from .env"
  else
    # Generate new password
    SA_PASSWORD="SqlServer@$(date +%s | tail -c 6)"
    echo "MSSQL_SA_PASSWORD=$SA_PASSWORD" > "$ENV_FILE"
    print_success "Created .env with new password"
  fi
else
  # Generate strong password
  SA_PASSWORD="SqlServer@$(date +%s | tail -c 6)"
  echo "MSSQL_SA_PASSWORD=$SA_PASSWORD" > "$ENV_FILE"
  print_success "Created .env with generated password: $SA_PASSWORD"
fi

# =============================================================================
# 4. Create docker-compose.yml
# =============================================================================

print_status "Creating docker-compose.yml..."

COMPOSE_FILE="$PARENT_DIR/docker-compose.yml"

if [ -f "$COMPOSE_FILE" ]; then
  print_warning "docker-compose.yml already exists"
else
  cat > "$COMPOSE_FILE" << 'DOCKER_COMPOSE_EOF'
version: '3.9'

services:
  mssql:
    # azure-sql-edge provides native linux/arm64 support for Apple Silicon.
    # Swap for mcr.microsoft.com/mssql/server:2022-latest on amd64 hardware only.
    image: mcr.microsoft.com/azure-sql-edge:latest
    container_name: mssql_dev
    restart: unless-stopped
    ports:
      - "${MSSQL_PORT:-1433}:1433"
    environment:
      ACCEPT_EULA: "1"
      MSSQL_SA_PASSWORD: "${MSSQL_SA_PASSWORD}"
    volumes:
      - mssql_data:/var/opt/mssql
    healthcheck:
      test: ["CMD-SHELL", "bash -c 'cat /dev/null > /dev/tcp/localhost/1433' || exit 1"]
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
DOCKER_COMPOSE_EOF
  print_success "Created docker-compose.yml"
fi

# =============================================================================
# 5. Start SQL Server container
# =============================================================================

print_status "Starting SQL Server container..."

cd "$PARENT_DIR"

# Check if container is already running
if docker ps --format '{{.Names}}' | grep -q "mssql_dev"; then
  print_success "SQL Server container (mssql_dev) is already running"
else
  # Check if container exists but is stopped
  if docker ps -a --format '{{.Names}}' | grep -q "mssql_dev"; then
    print_status "Starting existing container..."
    docker compose up -d
  else
    print_status "Creating and starting new container..."
    docker compose up -d
  fi

  # Wait for container to be healthy
  print_status "Waiting for SQL Server to be ready (~30 seconds)..."
  max_attempts=20
  attempt=0
  while [ $attempt -lt $max_attempts ]; do
    if docker exec mssql_dev \
      /opt/mssql-tools18/bin/sqlcmd \
      -S localhost -U SA -P "$(grep MSSQL_SA_PASSWORD "$ENV_FILE" | cut -d'=' -f2)" -C \
      -Q "SELECT 1" &> /dev/null; then
      print_success "SQL Server is ready!"
      break
    fi
    echo -n "."
    sleep 2
    ((attempt++))
  done

  if [ $attempt -eq $max_attempts ]; then
    print_error "SQL Server failed to start after 60 seconds"
    echo "  Check logs: docker compose logs mssql"
    exit 1
  fi
fi

# =============================================================================
# 6. Create omop_synth database
# =============================================================================

print_status "Creating omop_synth database..."

SA_PASSWORD=$(grep MSSQL_SA_PASSWORD "$ENV_FILE" | cut -d'=' -f2)

docker exec mssql_dev \
  /opt/mssql-tools18/bin/sqlcmd \
  -S localhost -U SA -P "$SA_PASSWORD" -C \
  -Q "IF DB_ID('omop_synth') IS NULL CREATE DATABASE omop_synth;" &> /dev/null

print_success "omop_synth database created (or already exists)"

# =============================================================================
# 7. Create omop_vocab folder structure
# =============================================================================

print_status "Creating omop_vocab folder structure..."

VOCAB_DIR="$PARENT_DIR/omop_vocab"
mkdir -p "$VOCAB_DIR"

if [ ! -f "$VOCAB_DIR/CONCEPT.csv" ]; then
  print_warning "OMOP vocabulary files not found in $VOCAB_DIR"
fi

# =============================================================================
# 8. Summary and next steps
# =============================================================================

cat << EOF

${GREEN}╔════════════════════════════════════════════════════════════════════════╗${NC}
${GREEN}║${NC}                 Docker Setup Complete!                              ${GREEN}║${NC}
${GREEN}╚════════════════════════════════════════════════════════════════════════╝${NC}

${BLUE}✓ Setup Summary:${NC}
  • OS detected: $OS
  • OMOP_Dev folder: $PARENT_DIR
  • .env file: $ENV_FILE
  • Docker Compose: $COMPOSE_FILE
  • SQL Server container: mssql_dev (running)
  • Database: omop_synth (created)

${YELLOW}→ Next Steps:${NC}

1. ${BLUE}Download OMOP Vocabulary from Athena:${NC}
   • Go to https://athena.ohdsi.org
   • Download vocabulary bundle (SNOMED, RxNorm, LOINC, etc.)
   • Extract to: $VOCAB_DIR

2. ${BLUE}Rebuild CPT-4 codes (optional, requires UMLS API key):${NC}
   • Get free UMLS API key: https://uts.nlm.nih.gov
   • Run: cd $VOCAB_DIR && bash cpt.sh YOUR_UMLS_API_KEY

3. ${BLUE}Verify SQL Server connection:${NC}
   • Install VS Code mssql extension
   • Server: localhost,1433
   • Username: SA
   • Password: $(grep MSSQL_SA_PASSWORD "$ENV_FILE" | cut -d'=' -f2)

4. ${BLUE}Clone your study repository:${NC}
   • cd $PARENT_DIR
   • git clone https://github.com/<your-org>/<your-study>.git
   • cd <your-study>
   • Open in VS Code → Reopen in Container

${YELLOW}Important Notes:${NC}
  • Keep .env file secure (contains SA password)
  • Never commit .env to version control
  • Vocabulary load takes 30-60 minutes (one-time cost)
  • This setup is reusable for multiple studies

${BLUE}For more details:${NC}
  • See: OMOP_Dev/docs/SETUP.md
  • Or run: Rscript workflow/01_setup_synthea_etl_qc_env.R

EOF

print_success "Setup script completed successfully!"
