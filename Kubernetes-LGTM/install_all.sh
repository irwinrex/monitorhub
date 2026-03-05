#!/usr/bin/env bash
# ==============================================================================
# install_all.sh
# Root-level orchestrator — runs all phases in order.
#
# Usage:
#   bash install_all.sh
#
# With S3 configuration via flags:
#   bash install_all.sh --bucket-name my-bucket --bucket-region us-east-1
#
# Or with environment variables:
#   S3_BUCKET=my-bucket S3_REGION=us-east-1 bash install_all.sh
#
# Non-interactive mode:
#   bash install_all.sh -y
#
# Force recreate secrets:
#   bash install_all.sh -y -f
#
# Skip completed phases after a partial/failed install:
#   SKIP_K0S=true SKIP_HAPROXY=true bash install_all.sh
#
# Available skip flags:
#   SKIP_K0S=true        skip scripts/install_k0s.sh
#   SKIP_HAPROXY=true    skip scripts/install_HAproxy.sh
#   SKIP_SECRETS=true    skip scripts/install_secrets.sh
#   SKIP_LGTM=true       skip scripts/install_LGTM.sh
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${ROOT_DIR}/scripts"
VALUES_DIR="${ROOT_DIR}/values"

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
  -f | --force-recreate)
    FORCE_RECREATE="true"
    shift
    ;;
  -h | --help)
    echo "Usage: bash install_all.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -b, --bucket-name    S3 base bucket name"
    echo "  -r, --region         S3 region (e.g., us-east-1)"
    echo "  -y, --yes            Non-interactive mode"
    echo "  -f, --force-recreate Force recreate secrets"
    echo "  -h, --help           Show this help"
    echo ""
    echo "Examples:"
    echo "  bash install_all.sh -b my-bucket -r us-east-1 -y"
    echo "  S3_BUCKET=my-bucket S3_REGION=us-east-1 bash install_all.sh -y"
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
  S3_BUCKET="${S3_BUCKET}" \
    S3_REGION="${S3_REGION}" \
    YES="${YES}" \
    FORCE_RECREATE="${FORCE_RECREATE}" \
    bash "${script}"
  echo -e "${GREEN}  ✓  Phase ${num} complete in $((SECONDS - t))s${NC}"
}

# ── Pre-flight ────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  LGTM Full Stack Install                                 ║${NC}"
echo -e "${BOLD}║  k0s · HAProxy · Loki · Tempo · Mimir · Grafana         ║${NC}"
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

configure_s3_buckets "${S3_BUCKET}" "${S3_REGION}"

echo ""
info "S3 Configuration:"
print_s3_config
echo ""

export S3_BUCKET S3_REGION \
  S3_BUCKET_LOKI S3_BUCKET_TEMPO S3_BUCKET_MIMIR \
  S3_BUCKET_MIMIR_ALERTMANAGER S3_BUCKET_MIMIR_RULER S3_BUCKET_GRAFANA

# ── Confirm ───────────────────────────────────────────────────────────────────
if [[ "${YES}" != "true" ]]; then
  echo ""
  warn "This will install k0s, HAProxy, and the full LGTM stack."
  warn "Intended for a fresh Debian 12 ARM64 instance (t4g.xlarge)."
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
# Summary
# ══════════════════════════════════════════════════════════════════════════════
TOTAL_MIN=$(((SECONDS - TOTAL_START) / 60))
TOTAL_SEC=$(((SECONDS - TOTAL_START) % 60))

# Resolve IPs
PRIVATE_IP=$(kubectl get nodes \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' \
  2>/dev/null || echo "")
PUBLIC_IP=$(curl -sf --max-time 2 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null ||
  curl -sf --max-time 2 -H "Metadata-Flavor: Google" \
    http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip 2>/dev/null ||
  curl -sf --max-time 2 -H "Metadata: true" \
    "http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/publicIpAddress?api-version=2021-02-01" 2>/dev/null ||
  curl -sf --max-time 2 http://169.254.169.254/hetzner/v1/metadata/public-ipv4 2>/dev/null ||
  curl -sf --max-time 2 http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address 2>/dev/null ||
  echo "")
DISPLAY_IP="${PUBLIC_IP:-${PRIVATE_IP:-localhost}}"

# Fetch credentials from secrets
GRAFANA_PASS=$(kubectl get secret grafana-admin -n monitoring \
  -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d || echo "")
BASIC_AUTH_USER=$(kubectl get secret basic-auth -n kube-system \
  -o jsonpath='{.data.username}' 2>/dev/null | base64 -d || echo "")
BASIC_AUTH_PASS=$(kubectl get secret basic-auth -n kube-system \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "")

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
echo "  Password: ${GRAFANA_PASS:-<run: kubectl get secret grafana-admin -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d>}"
echo ""

echo -e "${CYAN}API Endpoints (Mimir, Loki, Tempo):${NC}"
echo "  Mimir:    http://${DISPLAY_IP}/metrics"
echo "  Loki:     http://${DISPLAY_IP}/logs"
echo "  Tempo:    http://${DISPLAY_IP}/traces"
if [[ -n "${BASIC_AUTH_USER}" && -n "${BASIC_AUTH_PASS}" ]]; then
  echo "  User:     ${BASIC_AUTH_USER}"
  echo "  Password: ${BASIC_AUTH_PASS}"
else
  _user=$(kubectl get secret basic-auth -n kube-system -o jsonpath='{.data.username}' 2>/dev/null | base64 -d || echo "<not found>")
  _pass=$(kubectl get secret basic-auth -n kube-system -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "<not found>")
  echo "  User:     ${_user}"
  echo "  Password: ${_pass}"
fi
echo ""

echo -e "${CYAN}HAProxy Stats:${NC}"
echo "  URL:  http://${DISPLAY_IP}:1024"
echo ""

[[ -n "$PUBLIC_IP" ]] && info "Public IP:  ${PUBLIC_IP}"
[[ -n "$PRIVATE_IP" ]] && info "Private IP: ${PRIVATE_IP}"

echo ""
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}  QUICK COMMANDS${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo "  kubectl get nodes -o wide"
echo "  kubectl get pods -n monitoring -o wide"
echo "  kubectl get ingress -n monitoring"
echo "  helm list -n monitoring"
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# Endpoint tests — use localhost since HAProxy binds via hostPort on this node
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}  ENDPOINT TESTS${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
echo ""

_test_endpoint() {
  local label="$1" url="$2" auth="$3"
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    ${auth:+-u "$auth"} --max-time 5 "$url" 2>/dev/null || echo "000")
  if [[ "$http_code" =~ ^[2-4] ]]; then
    success "${label}: HTTP ${http_code}"
  else
    warn "${label}: HTTP ${http_code} — connection failed or timed out"
  fi
}

# Grafana — no auth
_test_endpoint "Grafana  (/)" \
  "http://localhost/" \
  ""

# LGTM APIs — basic auth required
if [[ -n "${BASIC_AUTH_USER}" && -n "${BASIC_AUTH_PASS}" ]]; then
  AUTH="${BASIC_AUTH_USER}:${BASIC_AUTH_PASS}"
  _test_endpoint "Mimir    (/metrics)" "http://localhost/metrics" "$AUTH"
  _test_endpoint "Loki     (/logs)" "http://localhost/logs" "$AUTH"
  _test_endpoint "Tempo    (/traces)" "http://localhost/traces" "$AUTH"

  # Also verify 401 is returned without credentials
  info "Verifying auth enforcement (expect 401)..."
  _test_endpoint "Mimir no-auth (expect 401)" "http://localhost/metrics" ""
else
  warn "Basic auth credentials not found in secrets — skipping API tests"
  warn "Run: kubectl get secret basic-auth -n kube-system -o yaml"
fi

echo ""
