#!/usr/bin/env bash
# ==============================================================================
# scripts/lib/common.sh
# Shared functions, version pins, and helpers.
# Sourced by every install_*.sh — never executed directly.
# ==============================================================================

# ── Pinned versions ────────────────────────────────────────────────────────────
# All version bumps happen here. Check release pages in README.md.
export K0S_VERSION="v1.32.2+k0s.0"
export HELM_VERSION="v3.17.1"
export HAPROXY_CHART_VERSION="1.42.2" # haproxytech/kubernetes-ingress
export CERTMANAGER_VERSION="v1.17.1"  # jetstack/cert-manager
export LINKERD_VERSION="stable-2.16.0" # Linkerd

export LOKI_CHART_VERSION="6.29.0"
export TEMPO_CHART_VERSION="1.21.1"
export MIMIR_CHART_VERSION="5.6.0"
export GRAFANA_CHART_VERSION="8.9.1"

# ── S3 Configuration (can be overridden via env) ─────────────────────────────
export S3_BUCKET="${S3_BUCKET:-lgtm-observability}"
export S3_REGION="${S3_REGION:-us-east-1}"
export S3_ENDPOINT="${S3_ENDPOINT:-}"  # For MinIO/custom S3-compatible
export S3_ACCESS_KEY_ID="${S3_ACCESS_KEY_ID:-}"
export S3_SECRET_ACCESS_KEY="${S3_SECRET_ACCESS_KEY:-}"
export S3_FORCE_PATH_STYLE="${S3_FORCE_PATH_STYLE:-false}"

# ── Domain Configuration ──────────────────────────────────────────────────────────
export GRAFANA_DOMAIN="${GRAFANA_DOMAIN:-grafana.example.com}"

# ── Namespace ─────────────────────────────────────────────────────────────────
export MONITORING_NS="monitoring"
export CERTMANAGER_NS="cert-manager"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Logging ───────────────────────────────────────────────────────────────────
info() { echo -e "${CYAN}[INFO]${NC}   $*"; }
success() { echo -e "${GREEN}[OK]${NC}     $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}   $*"; }
die() {
  echo -e "${RED}[ERROR]${NC}  $*" >&2
  exit 1
}

header() {
  echo ""
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}${CYAN}  $*${NC}"
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${NC}"
}

# ── Guards ────────────────────────────────────────────────────────────────────
require_root() {
  [[ $EUID -eq 0 ]] || die "Must run as root: sudo bash $0"
}

require_kubeconfig() {
  export KUBECONFIG="${KUBECONFIG:-/root/.kube/config}"
  [[ -f "$KUBECONFIG" ]] || die "kubeconfig not found at ${KUBECONFIG}\n  Run: sudo bash scripts/install_k0s.sh first"
}

require_helm() {
  command -v helm &>/dev/null || die "Helm not found.\n  Run: sudo bash scripts/install_k0s.sh first"
}

require_file() {
  [[ -f "$1" ]] || die "Required file missing: $1"
}

# ── kubectl via k0s (no separate kubectl binary needed) ──────────────────────
# All scripts use k() instead of kubectl directly.
k() { k0s kubectl "$@"; }

# ── Wait helpers ──────────────────────────────────────────────────────────────

# wait_rollout <namespace> <resource/name> [timeout]
wait_rollout() {
  local ns="$1" resource="$2" timeout="${3:-120s}"
  info "Waiting for rollout: ${resource} (${ns})..."
  k0s kubectl rollout status "${resource}" -n "${ns}" --timeout="${timeout}"
}

# wait_cert_ready <cert-name> <namespace> [max-retries]
wait_cert_ready() {
  local name="$1" ns="$2" retries="${3:-24}"
  info "Waiting for certificate: ${name} (${ns})..."
  for i in $(seq 1 "${retries}"); do
    local status
    status=$(k0s kubectl get certificate "${name}" -n "${ns}" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
      2>/dev/null || true)
    if [[ "$status" == "True" ]]; then
      success "Certificate ${name} Ready"
      return 0
    fi
    [[ $i -eq "${retries}" ]] &&
      die "Certificate '${name}' not Ready after ${retries} attempts.\n  Debug: kubectl describe certificate ${name} -n ${ns}"
    printf '.'
    sleep 5
  done
  echo
}

# ── Resolve VALUES_DIR from caller's location ─────────────────────────────────
# Scripts live in scripts/ — values live in ../values/
# This works whether a script is called from install_all.sh (project root)
# or run standalone from the scripts/ directory.
resolve_values_dir() {
  local caller_dir
  caller_dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"

  # If called from scripts/ dir, values are one level up
  if [[ -d "${caller_dir}/../values" ]]; then
    echo "${caller_dir}/../values"
  # If called from project root (install_all.sh), values/ is right here
  elif [[ -d "${caller_dir}/values" ]]; then
    echo "${caller_dir}/values"
  else
    die "Cannot locate values/ directory relative to ${caller_dir}"
  fi
}

# ── Battle-ready checks ─────────────────────────────────────────────────────────
check_disk_space() {
  local required_gb="${1:-100}"
  local available_gb
  available_gb=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
  
  info "Checking disk space: ${available_gb}GB available, ${required_gb}GB required..."
  if [[ "$available_gb" -lt "$required_gb" ]]; then
    die "Insufficient disk space: ${available_gb}GB available, ${required_gb}GB required"
  fi
  success "Disk space OK: ${available_gb}GB available"
}

check_ports() {
  local port="$1"
  if ss -tuln 2>/dev/null | grep -q ":${port} "; then
    warn "Port ${port} is already in use"
    return 1
  fi
  info "Port ${port} is available"
  return 0
}

check_k0s_not_installed() {
  if command -v k0s &>/dev/null || [[ -f /usr/local/bin/k0s ]]; then
    warn "k0s is already installed"
    info "To reinstall: k0s reset or SKIP_K0S=true to skip"
    return 1
  fi
  success "k0s not found - safe to install"
  return 0
}

retry_kubectl() {
  local max_attempts="${1:-5}"
  local delay="${2:-10}"
  local cmd="${3:-}"
  
  for ((i=1; i<=max_attempts; i++)); do
    if eval "$cmd" &>/dev/null; then
      return 0
    fi
    warn "Attempt $i/$max_attempts failed, retrying in ${delay}s..."
    sleep "$delay"
  done
  return 1
}

check_helm_release() {
  local release="$1"
  local namespace="${2:-default}"
  
  if helm list -n "$namespace" -q 2>/dev/null | grep -q "^${release}$"; then
    info "Helm release '${release}' already exists in ${namespace}"
    return 1
  fi
  return 0
}

check_namespace_exists() {
  local ns="$1"
  if k0s kubectl get namespace "$ns" &>/dev/null 2>&1; then
    return 0
  fi
  return 1
}

check_dns_resolution() {
  local domain="${1:-}"
  if [[ -z "$domain" ]]; then
    return 0
  fi
  
  if [[ "$domain" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    success "Using IP address: ${domain}"
    return 0
  fi
  
  info "Checking DNS resolution for '${domain}'..."
  if command -v nslookup &>/dev/null; then
    if nslookup "$domain" &>/dev/null; then
      success "DNS resolved: ${domain}"
      return 0
    else
      warn "DNS not resolved: ${domain}"
      return 1
    fi
  elif command -v dig &>/dev/null; then
    if dig +short "$domain" | grep -q '^[0-9]'; then
      success "DNS resolved: ${domain}"
      return 0
    else
      warn "DNS not resolved: ${domain}"
      return 1
    fi
  fi
  return 0
}

backup_kubeconfig() {
  local backup_dir="/root/.kube/backups"
  local timestamp=$(date +%Y%m%d_%H%M%S)
  
  if [[ -f /root/.kube/config ]]; then
    mkdir -p "$backup_dir"
    cp /root/.kube/config "${backup_dir}/config.${timestamp}"
    info "Backed up kubeconfig to ${backup_dir}/config.${timestamp}"
  fi
}

cleanup_on_failure() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    echo ""
    warn "Installation failed with exit code: ${exit_code}"
    info "To debug: check logs above, or run 'journalctl -u k0s -n 50'"
    info "To reset: k0s reset"
  fi
}

log_to_file() {
  local log_file="${LOG_FILE:-/var/log/lgtm-install.log}"
  exec > >(tee -a "$log_file") 2>&1
}

wait_for_service() {
  local service="$1"
  local timeout="${2:-60}"
  local count=0
  
  while [[ $count -lt $timeout ]]; do
    if systemctl is-active --quiet "$service"; then
      return 0
    fi
    sleep 1
    ((count++))
  done
  return 1
}
