#!/usr/bin/env bash
# ==============================================================================
# setup_stack.sh
# ---------------
#  Self-Healing SRE Agent Pipeline — Full Stack Deployment
#
#  Automates the entire lifecycle using SigNoz Foundry (the official deployment
#  tool, replacing legacy docker-compose).
#
#    Step   Action                          Outcome
#    ────────────────────────────────────────────────────────────────────────
#     1     Foundry CLI                     Install foundryctl (if missing)
#     2     Config generation               foundryctl forge -> pours/deployment/
#     3     Override injection + deploy     Dynamic YAML patch + docker compose up
#     4     Health verification             Wait for :3301 HTTP 200
#     5     Python environment              venv + pip install -r requirements
#     6     Pipeline launch                 uvicorn app:app --port 8081
#
#  Port usage
#  ----------
#    Container / Process         Host port   Purpose
#    ─────────────────────────────────────────────────────────────────
#    signoz-ingester (OTel)      4317        OTLP gRPC (traces)
#    signoz-ingester (OTel)      4318        OTLP HTTP (traces)
#    signoz-mcp-server           8000        MCP HTTP API
#    app.py (uvicorn)            8081        FastAPI pipeline endpoints
#    signoz-signoz-0 (SigNoz)    8080        SigNoz UI + API
#
#  Prerequisites
#  -------------
#    - Docker Desktop with WSL2 backend (Windows) OR Docker Engine (Linux)
#    - git
#    - Python 3.11+
#    - curl
#    - ~8 GB free RAM (4 GB allocated to WSL2 recommended)
#
#  Usage
#  -----
#    chmod +x setup_stack.sh
#    ./setup_stack.sh
# ==============================================================================

# ── Self-healing: detect and fix Windows CRLF line endings ──────────────────
# If this file has CRLF (\r\n) line endings (common when edited on Windows),
# convert them to LF (\n) and re-execute to avoid shebang / parsing errors.
# Runs before 'set -euo pipefail' so the check itself can fail gracefully.
if grep -q $'\r$' "$0" 2>/dev/null; then
    echo "[SETUP] Detected CRLF line endings in $0 — converting to Unix LF..."
    sed -i 's/\r$//' "$0"
    echo "[SETUP] Line endings fixed. Re-executing with clean environment..."
    exec bash "$0" "$@"
fi

set -euo pipefail

# ── Script location (project root) ───────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}" )" && pwd)"

# ── Terminal colours ─────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

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

# ── Helper: install PyYAML if missing on system Python ───────────────────────
ensure_pyyaml() {
    python3 -c "import yaml" 2>/dev/null && return 0
    info "PyYAML not found on system Python — installing..."
    pip3 install pyyaml --quiet --user 2>/dev/null || pip install pyyaml --quiet 2>/dev/null || true
    python3 -c "import yaml" 2>/dev/null && return 0
    # Last resort: install into a temp venv and use its python directly
    python3 -m venv /tmp/setup_venv
    /tmp/setup_venv/bin/pip install pyyaml --quiet
    # Use the temp venv's python for YAML operations going forward
    python3() { /tmp/setup_venv/bin/python3 "$@"; }
    export -f python3
    python3 -c "import yaml" 2>/dev/null && return 0
    error "Could not install PyYAML. Please install it manually: pip3 install pyyaml"
    exit 1
}

# ═══════════════════════════════════════════════════════════════════════════
# STEP 1 — Install Foundry CLI if missing
# ═══════════════════════════════════════════════════════════════════════════

header "Step 1/6  —  Foundry CLI & Prerequisites"

if command -v foundryctl &>/dev/null; then
    ok "Foundry CLI ($(foundryctl version 2>/dev/null || echo 'installed')) is available."
else
    info "Installing SigNoz Foundry CLI..."
    curl -fsSL https://signoz.io/foundry.sh | bash
    # foundry.sh adds foundryctl to PATH, but may need rehashing
    hash -r 2>/dev/null || true
    if ! command -v foundryctl &>/dev/null; then
        error "Foundry CLI installation failed. Please install manually:"
        error "  curl -fsSL https://signoz.io/foundry.sh | bash"
        exit 1
    fi
    ok "Foundry CLI installed successfully."
fi

# Ensure PyYAML is available for dynamic compose patching
ensure_pyyaml
ok "Python YAML support is ready."

# ═══════════════════════════════════════════════════════════════════════════
# STEP 2 — Generate SigNoz deployment configuration via Foundry Forge
# ═══════════════════════════════════════════════════════════════════════════

header "Step 2/6  —  Generate SigNoz Deployment Configuration"

CASTING_FILE="${SCRIPT_DIR}/casting.yaml"
if [ ! -f "$CASTING_FILE" ]; then
    error "Casting file not found at ${CASTING_FILE}"
    error "This project requires a casting.yaml for Foundry deployment."
    exit 1
fi

# Ensure casting.yaml has Unix line endings (Foundry's parser may choke on CRLF)
if grep -q $'\r$' "$CASTING_FILE" 2>/dev/null; then
    info "Fixing CRLF line endings in casting.yaml..."
    sed -i 's/\r$//' "$CASTING_FILE"
fi

# Clean any previous Foundry output to avoid stale state
info "Cleaning previous Foundry output..."
rm -rf "${SCRIPT_DIR}/pours"

info "Running 'foundryctl forge' to generate deployment files..."
foundryctl forge -f "$CASTING_FILE"
ok "SigNoz deployment files generated."

# Verify the output directory exists
POURS_DIR="${SCRIPT_DIR}/pours/deployment"
export POURS_DIR
if [ ! -d "$POURS_DIR" ]; then
    error "Expected Foundry output at ${POURS_DIR} but it was not found."
    error "Check the contents of ${SCRIPT_DIR}/pours/ for the actual path."
    exit 1
fi
ok "Foundry output directory: ${POURS_DIR}"

# ═══════════════════════════════════════════════════════════════════════════
# STEP 3 — Dynamic override generation + stack deployment
# ═══════════════════════════════════════════════════════════════════════════
#
# Instead of trying to match a static override to Foundry's generated
# compose (service names and network names vary between Foundry versions),
# we read the generated compose.yaml at runtime and build a correct override.
#
# This patch:
#   1. Host-exposes OTLP ports 4317 (gRPC) and 4318 (HTTP) so the native
#      Python pipeline can export telemetry via localhost.
#   2. Injects the signoz-mcp-server container — a Model Context Protocol
#      companion that the SRE pipeline queries for trace search & diagnosis.
#   3. Adds host.docker.internal gateway for WSL2 host resolution.
# ═══════════════════════════════════════════════════════════════════════════

header "Step 3/6  —  Inject MCP Server & Deploy SigNoz Stack"

info "Analyzing generated compose file to build override..."
OVERRIDE_PATH="${POURS_DIR}/docker-compose.override.yaml"

python3 << PYEOF
import yaml, os, sys

pours_dir = os.environ.get('POURS_DIR', 'pours/deployment')
compose_path = os.path.join(pours_dir, 'compose.yaml')

try:
    with open(compose_path) as f:
        compose = yaml.safe_load(f)
except FileNotFoundError:
    print(f"ERROR: Generated compose not found at {compose_path}", file=sys.stderr)
    sys.exit(1)

services = compose.get('services', {})
if not services:
    print("ERROR: No services found in generated compose.yaml", file=sys.stderr)
    sys.exit(1)

# ── Identify the OTel collector service ──────────────────────────────────
otel_service = None
for name, svc in services.items():
    image = svc.get('image', '').lower()
    if 'otel' in image or 'collector' in image:
        otel_service = name
        break

if not otel_service:
    # Fallback: try common Foundry service names
    for candidate in ('ingester', 'otel-collector', 'signoz-otel-collector'):
        if candidate in services:
            otel_service = candidate
            break

if not otel_service:
    # Last resort: pick the last-resort default
    otel_service = 'ingester'
    print(f"WARNING: Could not auto-detect OTel collector. Assuming '{otel_service}'.")

# ── Identify the SigNoz API service ──────────────────────────────────────
signoz_service = None
for name, svc in services.items():
    image = svc.get('image', '').lower()
    if 'signoz/signoz' in image and 'otel' not in image and 'mcp' not in image:
        signoz_service = name
        break

if not signoz_service:
    signoz_service = 'signoz'  # default fallback

# ── Identify the first network ───────────────────────────────────────────
network_name = None
if compose.get('networks'):
    network_name = list(compose['networks'].keys())[0]

print(f"Detected OTel collector service: {otel_service}")
print(f"Detected SigNoz API service:    {signoz_service}")
print(f"Network:                         {network_name}")

# ── Build the override ───────────────────────────────────────────────────
override = {
    'services': {
        otel_service: {
            'ports': ['4317:4317', '4318:4318'],
            'extra_hosts': ['host.docker.internal:host-gateway']
        },
        'signoz-mcp-server': {
            'image': 'signoz/signoz-mcp-server:latest',
            'container_name': 'signoz-mcp-server',
            'environment': {
                'SIGNOZ_URL': f'http://{signoz_service}:8080',
                'SIGNOZ_API_KEY': 'sk_hackathon_master_key_2026',
                'TRANSPORT_MODE': 'http',
                'MCP_SERVER_PORT': '8000',
                'LOG_LEVEL': 'debug'
            },
            'ports': ['8000:8000'],
            'extra_hosts': ['host.docker.internal:host-gateway'],
            'restart': 'unless-stopped'
        }
    }
}

# Attach services to the Foundry-managed network (if detected)
if network_name:
    override['services'][otel_service]['networks'] = [network_name]
    override['services']['signoz-mcp-server']['networks'] = [network_name]

with open(os.path.join(pours_dir, 'docker-compose.override.yaml'), 'w') as f:
    yaml.dump(override, f, default_flow_style=False, indent=2)

print(f"Override written to: {os.path.join(pours_dir, 'docker-compose.override.yaml')}")
PYEOF

ok "Override file generated with MCP server configuration."

info "Deploying SigNoz stack (docker compose up -d)..."
cd "$POURS_DIR"
docker compose -f compose.yaml -f docker-compose.override.yaml up -d
cd "$SCRIPT_DIR"
ok "SigNoz stack is deployed with MCP server on host port :8000."

# ═══════════════════════════════════════════════════════════════════════════
# STEP 4 — Health Verification Loop
# ═══════════════════════════════════════════════════════════════════════════

header "Step 4/6  —  SigNoz Health Verification"

info "Waiting for SigNoz API at http://localhost:8080 ..."
info "This typically takes 60–180 seconds on first boot (DB migrations)."
echo ""

SIGNOZ_HEALTH_URL="http://localhost:8080"
MAX_RETRIES=60  # 60 × 5 s = 5 minutes
COUNT=0

until curl -s -o /dev/null -w "%{http_code}" "$SIGNOZ_HEALTH_URL" | grep -q 200; do
    COUNT=$(( COUNT + 1 ))

    if [ "$COUNT" -gt "$MAX_RETRIES" ]; then
        echo ""
        error "SigNoz did not become healthy within 5 minutes."
        error "Check container logs for troubleshooting:"
        error "  cd ${POURS_DIR} && docker compose logs --tail=50"
        error "  cd ${POURS_DIR} && docker compose ps"
        exit 1
    fi

    # Spinner
    case $(( COUNT % 4 )) in
        0) CHAR="◐" ;; 1) CHAR="◓" ;; 2) CHAR="◑" ;; 3) CHAR="◒" ;;
    esac
    printf "  ${CHAR}  [%02d/%02d]  SigNoz not ready yet — retrying in 5 s...\r" \
        "$COUNT" "$MAX_RETRIES"
    sleep 5
done

echo ""
ok "SigNoz API is healthy — returned HTTP 200 at ${SIGNOZ_HEALTH_URL}."

# Verify OTLP gRPC port is reachable
info "Verifying OTLP gRPC port :4317 is reachable..."
if timeout 2 bash -c 'echo > /dev/tcp/localhost/4317' 2>/dev/null; then
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

# ── Ensure python3-venv is available (common missing package on Debian/WSL) ─
if ! python3 -c "import ensurepip" &>/dev/null; then
    info "python3-venv is not installed — attempting to install it..."
    # Detect Python version for the apt package name
    PYTHON_VERSION=$(python3 --version 2>&1 | grep -oP '\d+\.\d+')
    # Check if we have passwordless sudo (won't hang on WSL defaults; fails fast otherwise)
    if timeout 5 sudo -n true 2>/dev/null; then
        if command -v apt &>/dev/null; then
            sudo apt update -qq && sudo apt install -y -qq "python${PYTHON_VERSION}-venv"
        elif command -v yum &>/dev/null; then
            sudo yum install -y python3-virtualenv
        elif command -v apk &>/dev/null; then
            sudo apk add py3-virtualenv
        fi
    else
        warn "Passwordless sudo not available — skipping auto-install."
        warn "If needed, install python3-venv manually:"
        warn "  sudo apt install python${PYTHON_VERSION}-venv"
    fi
    # Re-check after installation attempt
    if ! python3 -c "import ensurepip" &>/dev/null; then
        error "Python venv module is not available."
        error "Please install it manually and re-run:"
        error "  sudo apt install python${PYTHON_VERSION}-venv"
        exit 1
    fi
    ok "python3-venv installed successfully."
fi

if [ -f "venv/bin/activate" ]; then
    info "Virtual environment already exists at ${SCRIPT_DIR}/venv."
elif [ -d "venv" ]; then
    warn "Found incomplete venv directory (likely from a previous failed run)."
    info "Removing and recreating it..."
    rm -rf "venv"
    python3 -m venv venv
    ok "Virtual environment created."
else
    info "Creating Python virtual environment..."
    python3 -m venv venv
    ok "Virtual environment created."
fi

# shellcheck disable=SC1091
source venv/bin/activate
ok "Virtual environment activated."

info "Upgrading pip..."
pip install --upgrade pip --quiet
ok "pip is up to date."

info "Installing dependencies from requirements.txt..."
pip install -r requirements.txt --quiet
ok "All Python dependencies installed."

# ═══════════════════════════════════════════════════════════════════════════
# STEP 6 — Pipeline Launch
# ═══════════════════════════════════════════════════════════════════════════

header "Step 6/6  —  Launch Self-Healing SRE Pipeline"

warn "The pipeline app is configured to run on ${BOLD}port 8081${NC} (not 8000)"
warn "to avoid collision with the signoz-mcp-server container (host :8000)."
warn "Override by setting APP_PORT env var, e.g.:  APP_PORT=9000 python app.py"
echo ""
info "${BOLD}Access points:${NC}"
info "  FastAPI pipeline    →  http://localhost:8081"
info "  FastAPI docs         →  http://localhost:8081/docs"
info "  SigNoz UI            →  http://localhost:8080"
info "  MCP Server           →  http://localhost:8000/mcp"
echo ""
info "Starting pipeline (Ctrl+C to stop)..."
echo ""

export OTEL_SERVICE_NAME="self-healing-sre-pipeline"
export OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:4317"
export APP_PORT="8081"

exec python app.py
