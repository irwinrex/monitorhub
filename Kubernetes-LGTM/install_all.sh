#!/usr/bin/env bash
# ==============================================================================
# install_all.sh
# Root-level orchestrator — runs all phases in order.
#
# Usage:
#   sudo bash install_all.sh
#
# With S3 configuration via flags:
#   sudo bash install_all.sh --bucket-name my-bucket --bucket-region us-east-1
#
# Or with environment variables:
#   S3_BUCKET=my-bucket S3_REGION=us-east-1 sudo -E bash install_all.sh
#
# Non-interactive mode:
#   sudo bash install_all.sh -y
#   sudo bash install_all.sh --yes
#
# Skip completed phases after a partial/failed install:
#   SKIP_K0S=true SKIP_HAPROXY=true sudo bash install_all.sh
#
# Available skip flags:
#   SKIP_K0S=true        skip scripts/install_k0s.sh
#   SKIP_HAPROXY=true   skip scripts/install_HAproxy.sh
#   SKIP_SECRETS=true   skip scripts/install_secrets.sh
#   SKIP_LGTM=true      skip scripts/install_LGTM.sh
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${ROOT_DIR}/scripts"
VALUES_DIR="${ROOT_DIR}/values"

# shellcheck source=scripts/lib/common.sh
source "${SCRIPTS_DIR}/lib/common.sh"

require_root

# ── Parse arguments ───────────────────────────────────────────────────────────
# FIX: capture into local vars first — do not export until fully resolved
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
  --force-recreate)
    FORCE_RECREATE="true"
    shift
    ;;
  -h | --help)
    echo "Usage: sudo bash install_all.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -b, --bucket-name    S3 base bucket name"
  echo "  -r, --region         S3 region (e.g., us-east-1)"
  echo "  -y, --yes            Non-interactive mode"
  echo "  --force-recreate    Force recreate secrets"
  echo "  -h, --help           Show this help"
    echo ""
    echo "Examples:"
    echo "  sudo bash install_all.sh -b my-bucket -r us-east-1 -y"
    echo "  S3_BUCKET=my-bucket S3_REGION=us-east-1 sudo -E bash install_all.sh -y"
    exit 0
    ;;
  *)
    warn "Unknown option: $1"
    shift
    ;;
  esac
done

# ── Resolve S3 config — flags > env vars > interactive prompt ─────────────────
S3_BUCKET="${_S3_BUCKET:-${S3_BUCKET:-}}"
S3_REGION="${_S3_REGION:-${S3_REGION:-}}"

YES="${YES:-false}"

# ── Skip flags ────────────────────────────────────────────────────────────────
SKIP_K0S="${SKIP_K0S:-false}"
SKIP_HAPROXY="${SKIP_HAPROXY:-false}"
SKIP_SECRETS="${SKIP_SECRETS:-false}"
SKIP_LGTM="${SKIP_LGTM:-false}"
SKIP_BACKUP="${SKIP_BACKUP:-false}"
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
    FORCE_RECREATE="${FORCE_RECREATE:-false}" \
    bash "${script}"
  echo -e "${GREEN}  ✓  Phase ${num} complete in $((SECONDS - t))s${NC}"
}

# ══════════════════════════════════════════════════════════════════════════════
# Pre-flight
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  LGTM Full Stack Install                                 ║${NC}"
echo -e "${BOLD}║  k0s · HAproxy · Loki · Tempo · Mimir · Grafana         ║${NC}"
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

[[ "${MISSING}" == "false" ]] || die "Missing files detected — ensure the full project is uploaded."
success "All required files present"

# ── Resolve S3 interactively if not provided via flags ────────────────────────
if [[ -z "${S3_BUCKET}" ]]; then
  echo ""
  read -r -p "S3 base bucket name: " S3_BUCKET
  S3_BUCKET="${S3_BUCKET:-lgtm-observability}"
fi

if [[ -z "${S3_REGION}" ]]; then
  read -r -p "S3 region [default: us-east-1]: " S3_REGION
  S3_REGION="${S3_REGION:-us-east-1}"
fi

# Resolve all derived bucket names via common.sh helper
# This is the single source of truth — install_LGTM.sh reads these exports
configure_s3_buckets "${S3_BUCKET}" "${S3_REGION}"

echo ""
info "S3 Configuration:"
print_s3_config
echo ""

# Export fully resolved vars for all child phases
export S3_BUCKET S3_REGION \
  S3_BUCKET_LOKI \
  S3_BUCKET_TEMPO \
  S3_BUCKET_MIMIR \
  S3_BUCKET_MIMIR_ALERTMANAGER \
  S3_BUCKET_MIMIR_RULER \
  S3_BUCKET_GRAFANA

# ── Confirm ───────────────────────────────────────────────────────────────────
if [[ "${YES}" != "true" ]]; then
  echo ""
  warn "This will install k0s, HAproxy, and the full LGTM stack."
  warn "Intended for a FRESH Debian 12 ARM64 instance (t4g.xlarge)."
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

_run_phase 2 "Secrets — Grafana admin credentials" \
  "${SKIP_SECRETS}" "${SCRIPTS_DIR}/install_secrets.sh"

_run_phase 3 "LGTM — Loki · Tempo · Mimir · Grafana" \
  "${SKIP_LGTM}" "${SCRIPTS_DIR}/install_LGTM.sh"

_run_phase 4 "HAproxy — Ingress Controller (deployed after LGTM)" \
  "${SKIP_HAPROXY}" "${SCRIPTS_DIR}/install_HAproxy.sh"

# ══════════════════════════════════════════════════════════════════════════════
# Done
# ══════════════════════════════════════════════════════════════════════════════
TOTAL_MIN=$(((SECONDS - TOTAL_START) / 60))
TOTAL_SEC=$(((SECONDS - TOTAL_START) % 60))

# Get node IP for summary
NODE_IP=$(kubectl get nodes \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' \
  2>/dev/null || echo "<node-ip>")

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
printf "${GREEN}║  All phases complete in %dm %ds%-28s║${NC}\n" \
  "${TOTAL_MIN}" "${TOTAL_SEC}" ""
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

# Get passwords from secrets
GRAFANA_PASS_RAW=$(kubectl get secret grafana-admin -n monitoring -o jsonpath='{.data.admin-password}' 2>/dev/null || echo "")
if [[ -n "$GRAFANA_PASS_RAW" ]]; then
  GRAFANA_PASS=$(echo "$GRAFANA_PASS_RAW" | base64 -d 2>/dev/null || echo "decode failed")
else
  GRAFANA_PASS="check secret"
fi

# Get basic auth credentials (plain password)
BASIC_AUTH_USER=$(kubectl get secret grafana-basic-auth -n monitoring -o jsonpath='{.data.username}' 2>/dev/null | base64 -d || echo "admin")
BASIC_AUTH_PASS=$(kubectl get secret grafana-basic-auth -n monitoring -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "check secret")

echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}  ACCESS CREDENTIALS${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${CYAN}Grafana:${NC}"
echo "  URL:      http://${NODE_IP}/"
echo "  User:     admin"
echo "  Password: ${GRAFANA_PASS}"
echo ""
echo -e "${CYAN}API Endpoints (Mimir, Loki, Tempo):${NC}"
echo "  URL:      http://${NODE_IP}/metrics, /logs, /traces"
echo "  User:     ${BASIC_AUTH_USER:-admin}"
echo "  Password: ${BASIC_AUTH_PASS:-check secret}"
echo ""
echo -e "${CYAN}HAProxy Stats:${NC}"
echo "  URL:      http://${NODE_IP}:1024"
HAPROXY_STATS_USER=$(kubectl get secret haproxy-stats -n kube-system -o jsonpath='{.data.username}' 2>/dev/null | base64 -d || echo "admin")
HAPROXY_STATS_PASS=$(kubectl get secret haproxy-stats -n kube-system -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "check secret")
echo "  User:     ${HAPROXY_STATS_USER}"
echo "  Password: ${HAPROXY_STATS_PASS}"
echo ""
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo "  Nodes:    kubectl get nodes -o wide"
echo "  Pods:     kubectl get pods -n monitoring -o wide"
echo "  Helm:     helm list -n monitoring"
echo ""
echo "  Grafana:  http://${NODE_IP}/"
echo "  Mimir:    http://${NODE_IP}/mimir"
echo "  Loki:     http://${NODE_IP}/loki"
echo "  Tempo:    http://${NODE_IP}/tempo"
echo ""
