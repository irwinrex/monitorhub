#!/usr/bin/env bash
# ==============================================================================
# install_all.sh
# Root-level orchestrator — runs all phases in order.
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${ROOT_DIR}/scripts"
VALUES_DIR="${ROOT_DIR}/values"

# Check for common lib before sourcing
if [[ ! -f "${SCRIPTS_DIR}/lib/common.sh" ]]; then
  echo "Error: ${SCRIPTS_DIR}/lib/common.sh not found."
  exit 1
fi
source "${SCRIPTS_DIR}/lib/common.sh"

require_kubeconfig

# ── Parse arguments ───────────────────────────────────────────────────────────
_S3_BUCKET=""
_S3_REGION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
  -b | --bucket-name | --bucket-name-prefix)
    _S3_BUCKET="$2"
    shift 2
    ;;
  --bucket-name=* | --bucket-name-prefix=*)
    _S3_BUCKET="${1#*=}"
    shift
    ;;
  -r | --region | --bucket-region)
    _S3_REGION="$2"
    shift 2
    ;;
  --region=* | --bucket-region=*)
    _S3_REGION="${1#*=}"
    shift
    ;;
  -y | --yes)
    YES="true"
    shift
    ;;
  -f | --force)
    FORCE_RECREATE="true"
    shift
    ;;
  -h | --help)
    echo "Usage: bash install_all.sh [OPTIONS]"
    echo ""
  echo "Options:"
  echo "  -b, --bucket-name    S3 base bucket name"
  echo "  -r, --region         S3 region (e.g., us-west-2)"
  echo "  -y, --yes            Non-interactive mode"
  echo "  -f, --force          Force recreate secrets"
  echo "  -h, --help           Show this help"
    exit 0
    ;;
  *)
    warn "Unknown option: $1"
    shift
    ;;
  esac
done

# ── Defaults ──────────────────────────────────────────────────────────────────
S3_BUCKET="${_S3_BUCKET:-${S3_BUCKET:-}}"
S3_REGION="${_S3_REGION:-${S3_REGION:-}}"
YES="${YES:-false}"
SKIP_K0S="${SKIP_K0S:-false}"
SKIP_HAPROXY="${SKIP_HAPROXY:-false}"
SKIP_SECRETS="${SKIP_SECRETS:-false}"
SKIP_LGTM="${SKIP_LGTM:-false}"
FORCE_RECREATE="${FORCE_RECREATE:-false}"
MONITORING_NS="monitoring"

# ── Phase runner ──────────────────────────────────────────────────────────────
_phase_banner() {
  echo ""
  echo -e "${BOLD}${CYAN}┌──────────────────────────────────────────────────────┐${NC}"
  printf "${BOLD}${CYAN}│  %-52s│${NC}\n" "$*"
  echo -e "${BOLD}${CYAN}└──────────────────────────────────────────────────────┘${NC}"
}

_run_phase() {
  local num="$1" label="$2" skip_flag="$3" script="$4"
  if [[ "${skip_flag}" == "true" ]]; then
    echo -e "${YELLOW}  ↷  Phase ${num}: ${label} — SKIPPED${NC}"
    return
  fi
  _phase_banner "Phase ${num}: ${label}"
  local t=$SECONDS
  
  # Pass environment variables explicitly to sub-shells
  S3_BUCKET="${S3_BUCKET}" \
    S3_REGION="${S3_REGION}" \
    YES="${YES}" \
    FORCE_RECREATE="${FORCE_RECREATE}" \
    BASIC_AUTH_USER="${BASIC_AUTH_USER:-admin}" \
    bash "${script}"
    
  echo -e "${GREEN}  ✓  Phase ${num} complete in $((SECONDS - t))s${NC}"
}

# ── Pre-flight ────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  LGTM Full Stack Install                                 ║${NC}"
echo -e "${BOLD}║  k0s · HAProxy · Loki · Tempo · Mimir · Grafana          ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

info "Verifying required files..."
MISSING=false

for script in \
  "${SCRIPTS_DIR}/lib/common.sh" \
  "${SCRIPTS_DIR}/install_k0s.sh" \
  "${SCRIPTS_DIR}/install_HAproxy.sh" \
  "${SCRIPTS_DIR}/install_secrets.sh" \
  "${SCRIPTS_DIR}/install_LGTM.sh"; do
  if [[ -f "$script" ]]; then
    info "  found: ${script##"${ROOT_DIR}/"}"
  else
    warn "  MISSING: ${script##"${ROOT_DIR}/"}"
    MISSING=true
  fi
done

for vfile in \
  "${VALUES_DIR}/loki-values.yaml" \
  "${VALUES_DIR}/tempo-values.yaml" \
  "${VALUES_DIR}/mimir-values.yaml" \
  "${VALUES_DIR}/grafana-values.yaml" \
  "${VALUES_DIR}/haproxy-values.yaml" \
  "${VALUES_DIR}/ingress.yaml"; do
  if [[ -f "$vfile" ]]; then
    info "  found: ${vfile##"${ROOT_DIR}/"}"
  else
    warn "  MISSING: ${vfile##"${ROOT_DIR}/"}"
    MISSING=true
  fi
done

[[ "${MISSING}" == "false" ]] || die "Missing files — ensure the full project is uploaded."
success "All required files present"

# ── Resolve S3 interactively if not provided ──────────────────────────────────
if [[ -z "${S3_BUCKET}" ]]; then
  echo ""
  read -r -p "S3 base bucket name: " S3_BUCKET
  S3_BUCKET="${S3_BUCKET:-lgtm-observability}"
fi

if [[ -z "${S3_REGION}" ]]; then
  read -r -p "S3 region [default: us-east-1]: " S3_REGION
  S3_REGION="${S3_REGION:-us-east-1}"
fi

# Configure S3 buckets using common.sh function
configure_s3_buckets "${S3_BUCKET}" "${S3_REGION}"

echo ""
info "S3 Configuration:"
print_s3_config
echo ""

# Export all S3 variables for sub-scripts
export S3_BUCKET S3_REGION \
  S3_BUCKET_LOKI S3_BUCKET_TEMPO S3_BUCKET_MIMIR \
  S3_BUCKET_MIMIR_ALERTMANAGER S3_BUCKET_MIMIR_RULER S3_BUCKET_GRAFANA

# ── Credentials (auto-generated by install_secrets.sh) ─────────────────────────
export BASIC_AUTH_USER="${BASIC_AUTH_USER:-admin}"

# ── Confirm ───────────────────────────────────────────────────────────────────
if [[ "${YES}" != "true" ]]; then
  echo ""
  warn "This will install k0s, HAProxy, and the full LGTM stack."
  warn "Ensure you have S3 credentials exported in your shell (AWS_ACCESS_KEY_ID, etc)."
  echo ""
  read -r -p "  Continue? [y/N] " confirm
  [[ "${confirm,,}" == "y" ]] || {
    info "Aborted."
    exit 0
  }
else
  info "Running in non-interactive mode (--yes)"
fi

TOTAL_START=$SECONDS

# ══════════════════════════════════════════════════════════════════════════════
# Phases
# ══════════════════════════════════════════════════════════════════════════════
_run_phase 1 "k0s — System prep + Kubernetes + Helm" \
  "${SKIP_K0S}" "${SCRIPTS_DIR}/install_k0s.sh"

_run_phase 2 "Secrets — Grafana admin + HAProxy basic auth" \
  "${SKIP_SECRETS}" "${SCRIPTS_DIR}/install_secrets.sh"

_run_phase 3 "LGTM — Loki · Tempo · Mimir · Grafana" \
  "${SKIP_LGTM}" "${SCRIPTS_DIR}/install_LGTM.sh"

_run_phase 4 "HAProxy — Ingress Controller" \
  "${SKIP_HAPROXY}" "${SCRIPTS_DIR}/install_HAproxy.sh"

# ══════════════════════════════════════════════════════════════════════════════
# Summary & Credential Retrieval
# ══════════════════════════════════════════════════════════════════════════════
TOTAL_MIN=$(((SECONDS - TOTAL_START) / 60))
TOTAL_SEC=$(((SECONDS - TOTAL_START) % 60))

# 1. Resolve Display IP
PRIVATE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "")
PUBLIC_IP=$(curl -sf --max-time 2 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "")
DISPLAY_IP="${PUBLIC_IP:-${PRIVATE_IP:-localhost}}"

# 2. Retrieve Credentials from K8s Secrets (safe decode)
GRAFANA_PASS="<unknown>"
if kubectl get secret grafana-admin -n "${MONITORING_NS}" &>/dev/null; then
  GRAFANA_PASS=$(kubectl get secret grafana-admin -n "${MONITORING_NS}" -o jsonpath='{.data.admin-password}' | base64 -d)
fi

BASIC_AUTH_USER="<unknown>"
BASIC_AUTH_PASS="<unknown>"
if kubectl get secret lgtm-basic-auth -n "${MONITORING_NS}" &>/dev/null; then
  BASIC_AUTH_USER=$(kubectl get secret lgtm-basic-auth -n "${MONITORING_NS}" -o jsonpath='{.data.username}' | base64 -d)
  BASIC_AUTH_PASS=$(kubectl get secret lgtm-basic-auth -n "${MONITORING_NS}" -o jsonpath='{.data.password}' | base64 -d)
fi

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
printf "${GREEN}║  All phases complete in %dm %ds%-28s║${NC}\n" \
  "${TOTAL_MIN}" "${TOTAL_SEC}" ""
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}  ACCESS CREDENTIALS${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${CYAN}Grafana:${NC}"
echo "  URL:      http://${DISPLAY_IP}/"
echo "  User:     admin"
echo "  Password: ${GRAFANA_PASS}"
echo ""

echo -e "${CYAN}Ingress Endpoints (Basic Auth Required):${NC}"
echo "  Mimir:    http://${DISPLAY_IP}/metrics"
echo "  Loki:     http://${DISPLAY_IP}/logs"
echo "  Tempo:    http://${DISPLAY_IP}/traces"
echo "  User:     ${BASIC_AUTH_USER}"
echo "  Password: ${BASIC_AUTH_PASS}"
echo ""

echo -e "${CYAN}HAProxy Stats:${NC}"
echo "  URL:      http://${DISPLAY_IP}:1024"
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# Connectivity Tests
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}  ENDPOINT CONNECTIVITY TESTS${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
echo ""

if [[ "${BASIC_AUTH_USER}" == "<unknown>" ]]; then
  warn "Skipping tests (Credentials not found in secrets)"
else
  # Use node IP with hostPort 80
  TEST_HOST="${PRIVATE_IP:-127.0.0.1}"
  
  _test() {
    local label="$1" url="$2"
    local http_code
    # Add -f flag to fail on HTTP errors, longer timeout
    http_code=$(curl -sf -o /dev/null -w "%{http_code}" \
      -u "${BASIC_AUTH_USER}:${BASIC_AUTH_PASS}" \
      --connect-timeout 10 --max-time 15 \
      "$url" 2>/dev/null || echo "000")
    
    # Accept 200, 401 (auth working), 404 (path exists but not found)
    if [[ "$http_code" =~ ^(200|401|404) ]]; then
      success "${label}: HTTP ${http_code} (OK)"
    elif [[ "$http_code" =~ ^[2-4] ]]; then
      success "${label}: HTTP ${http_code} (Reachable)"
    else
      warn "${label}: HTTP ${http_code} (Check logs)"
    fi
  }

  # Test HAProxy health first
  _test "HAProxy (health)" "http://${TEST_HOST}:80/"

  # Test endpoints with basic auth
  _test "Mimir  (/metrics)" "http://${TEST_HOST}:80/metrics"
  _test "Loki   (/logs)"    "http://${TEST_HOST}:80/logs"
  _test "Tempo  (/traces)"  "http://${TEST_HOST}:80/traces"
fi

echo ""
info "Installation Complete."
