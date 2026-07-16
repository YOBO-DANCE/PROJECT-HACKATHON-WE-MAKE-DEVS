#!/usr/bin/env bash
# ==============================================================================
# setup_stack.sh
# ---------------
#  Self-Healing SRE Agent Pipeline — Full Stack Deployment
#
#  Automates the entire lifecycle:
#
#    Step   Action                          Outcome
#    ────────────────────────────────────────────────────────────────────────
#     1     Directory management            Clone SigNoz (if missing)
#     2     Configuration injection         Copy docker-compose.override.yaml
#                                           into signoz/deploy/
#     3     Stack bootstrapping             docker compose up -d
#     4     Health verification loop        Wait for :3301 HTTP 200
#     5     Application initialization      venv + pip install -r requirements
#     6     Pipeline launch                 uvicorn app:app --port 8080
#
#  Port usage
#  ----------
#    Container / Process         Host port   Purpose
#    ─────────────────────────────────────────────────────────────────
#    signoz-otel-collector       4317        OTLP gRPC (traces)
#    signoz-otel-collector       4318        OTLP HTTP (traces)
#    signoz-mcp-server           8000        MCP HTTP API
#    app.py (uvicorn)            8080        FastAPI pipeline endpoints
#    query-service (SigNoz)      3301        SigNoz UI + API
#
#  NOTE: The pipeline app runs on port 8080 (not 8000) to avoid conflict
#  with the signoz-mcp-server Docker container which occupies host :8000.
#  The app's internal reference to the MCP server at http://localhost:8000/mcp
#  resolves correctly.
#
#  Prerequisites
#  -------------
#    - Docker Desktop with WSL2 backend (Windows) OR Docker Engine (Linux)
#    - git
#    - Python 3.11+
#    - curl
#    - ~8 GB free RAM (4.6 GB allocated to WSL2 recommended)
#
#  Usage
#  -----
#    chmod +x setup_stack.sh
#    ./setup_stack.sh
# ==============================================================================

set -euo pipefail

# ── Script location (project root) ───────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Terminal colours ─────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ANSI helpers — use printf with these to ensure cross-platform compatibility
info()   { printf "${CYAN}[INFO]${NC}   %s\n" "$*"; }
ok()     { printf "${GREEN}[OK]${NC}     %s\n" "$*"; }
warn()   { printf "${YELLOW}[WARN]${NC}   %s\n" "$*"; }
error()  { printf "${RED}[ERROR]${NC}  %s\n" "$*"; }
header() { printf "\n${BOLD}═══ %s ═══${NC}\n" "$*"; }

# ── Pre-flight: guard against missing system tools ──────────────────────────

require_cmd() {
    if ! command -v "$1" &>/dev/null; then
        error "'$1' is required but was not found on PATH."
        error "Please install '$1' and re-run this script."
        exit 1
    fi
}

require_cmd docker
require_cmd git
require_cmd python3
require_cmd curl

# Ensure the Docker daemon is running
if ! docker info &>/dev/null; then
    error "Docker daemon is not running.  Please start Docker Desktop or"
    error "Docker Engine and try again."
    exit 1
fi

ok "All required system tools are available."
ok "Docker daemon is running."

# ═══════════════════════════════════════════════════════════════════════════
# STEP 1 — Directory Management (clone SigNoz if missing)
# ═══════════════════════════════════════════════════════════════════════════

header "Step 1/6  —  SigNoz Repository"

SIGNOZ_DIR="${SCRIPT_DIR}/signoz"

if [ -d "$SIGNOZ_DIR" ]; then
    info "Directory '${SIGNOZ_DIR}' already exists — skipping clone."
    # Optionally pull latest changes if the repo is already present
    if [ -d "${SIGNOZ_DIR}/.git" ]; then
        info "Pulling latest changes from upstream..."
        cd "$SIGNOZ_DIR"
        git pull --ff-only origin main 2>/dev/null || true
        cd "$SCRIPT_DIR"
    fi
else
    info "Cloning SigNoz repository (branch: main)..."
    git clone -b main https://github.com/sigNoz/signoz.git "$SIGNOZ_DIR"
    ok "SigNoz repository cloned successfully."
fi

# ═══════════════════════════════════════════════════════════════════════════
# STEP 2 — Configuration Injection (docker-compose.override.yaml)
# ═══════════════════════════════════════════════════════════════════════════

header "Step 2/6  —  Docker Compose Override Injection"

DEPLOY_DIR="${SIGNOZ_DIR}/deploy"
OVERRIDE_DEST="${DEPLOY_DIR}/docker-compose.override.yaml"
OVERRIDE_SRC="${SCRIPT_DIR}/docker-compose.override.yaml"

if [ -f "$OVERRIDE_DEST" ]; then
    info "Override file already exists at ${OVERRIDE_DEST} — skipping."
else
    if [ -f "$OVERRIDE_SRC" ]; then
        info "Copying override file from project root to ${DEPLOY_DIR}/ ..."
        cp "$OVERRIDE_SRC" "$OVERRIDE_DEST"
        ok "Override file injected."
    else
        error "Expected docker-compose.override.yaml at ${OVERRIDE_SRC}"
        error "Please ensure the file exists alongside this script."
        exit 1
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# STEP 3 — Stack Bootstrapping (docker compose up -d)
# ═══════════════════════════════════════════════════════════════════════════

header "Step 3/6  —  SigNoz Stack Bootstrapping"

info "Starting SigNoz stack via Docker Compose..."
cd "$DEPLOY_DIR"

# Pull images first so the background output is clean
info "Pulling Docker images (this may take several minutes on first run)..."
docker compose pull

info "Bringing up containers in detached mode..."
docker compose up -d

ok "Docker Compose stack initiated."

cd "$SCRIPT_DIR"

# ═══════════════════════════════════════════════════════════════════════════
# STEP 4 — Health Verification Loop
# ═══════════════════════════════════════════════════════════════════════════

header "Step 4/6  —  SigNoz Health Verification"

info "Waiting for SigNoz Query Service at http://localhost:3301 ..."
info "This typically takes 60–180 seconds on first boot (DB migrations)."
echo ""

MAX_RETRIES=60  # 60 × 5 s = 5 minutes
COUNT=0

until curl -s -o /dev/null -w "%{http_code}" http://localhost:3301 | grep -q 200; do
    COUNT=$(( COUNT + 1 ))

    if [ "$COUNT" -gt "$MAX_RETRIES" ]; then
        echo ""
        error "SigNoz did not become healthy within 5 minutes."
        error "Check container logs for troubleshooting:"
        error "  cd ${DEPLOY_DIR} && docker compose logs --tail=50 query-service"
        error "  cd ${DEPLOY_DIR} && docker compose ps"
        exit 1
    fi

    # Spinner character
    case $(( COUNT % 4 )) in
        0) CHAR="◐" ;; 1) CHAR="◓" ;; 2) CHAR="◑" ;; 3) CHAR="◒" ;;
    esac
    printf "  ${CHAR}  [%02d/%02d]  query-service not ready yet — retrying in 5 s...\r" \
        "$COUNT" "$MAX_RETRIES"
    sleep 5
done

echo ""
ok "SigNoz Query Service is healthy — returned HTTP 200."

# Quick sanity — ensure the OTel collector is also listening on gRPC :4317
info "Verifying OTLP gRPC port :4317 is reachable..."
if curl -s --http2-prior-knowledge http://localhost:4317 &>/dev/null \
    || timeout 2 bash -c 'echo > /dev/tcp/localhost/4317' 2>/dev/null; then
    ok "OTLP gRPC endpoint is reachable at localhost:4317."
else
    warn "OTLP gRPC port :4317 does not appear to be listening yet."
    warn "The collector may still be initialising — the pipeline will retry."
fi

# ═══════════════════════════════════════════════════════════════════════════
# STEP 5 — Application Initialization (venv + dependencies)
# ═══════════════════════════════════════════════════════════════════════════

header "Step 5/6  —  Python Environment"

cd "$SCRIPT_DIR"

# Create virtual environment (idempotent)
if [ -d "venv" ]; then
    info "Virtual environment already exists at ${SCRIPT_DIR}/venv."
else
    info "Creating Python virtual environment..."
    python3 -m venv venv
    ok "Virtual environment created."
fi

# Activate
# shellcheck disable=SC1091
source venv/bin/activate
ok "Virtual environment activated."

# Upgrade pip
info "Upgrading pip..."
pip install --upgrade pip --quiet
ok "pip is up to date."

# Install project dependencies
info "Installing dependencies from requirements.txt..."
pip install -r requirements.txt --quiet
ok "All Python dependencies installed."

# ═══════════════════════════════════════════════════════════════════════════
# STEP 6 — Pipeline Launch
# ═══════════════════════════════════════════════════════════════════════════

header "Step 6/6  —  Launch Self-Healing SRE Pipeline"

warn "The pipeline app is configured to run on ${BOLD}port 8080${NC} (not 8000)"
warn "to avoid collision with the signoz-mcp-server container (host :8000)."
warn "Override by setting APP_PORT env var, e.g.:  APP_PORT=9000 python app.py"
echo ""
info "${BOLD}Access points:${NC}"
info "  FastAPI pipeline    →  http://localhost:8080"
info "  FastAPI docs         →  http://localhost:8080/docs"
info "  SigNoz UI            →  http://localhost:3301"
info "  MCP Server           →  http://localhost:8000/mcp"
echo ""
info "Starting pipeline (Ctrl+C to stop)..."
echo ""

exec python app.py
