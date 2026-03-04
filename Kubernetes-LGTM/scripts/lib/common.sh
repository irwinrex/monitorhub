#!/usr/bin/env bash
# ==============================================================================
# scripts/lib/common.sh
# Shared functions, version pins, and helpers.
# Sourced by every install_*.sh — never executed directly.
# ==============================================================================

# ── Pinned versions ────────────────────────────────────────────────────────────
# All version bumps happen here. Check release pages in README.md.
export K0S_VERSION="v1.34.3+k0s.0" # https://github.com/k0sproject/k0s/releases
export HELM_VERSION="v3.17.1"      # https://github.com/helm/helm/releases

export HAPROXY_CHART_VERSION="1.48.0"   # https://artifacthub.io/packages/helm/haproxy-ingress/haproxy-ingress
export LINKERD_VERSION="stable-2.14.11" # https://github.com/linkerd/linkerd2/releases

# LGTM chart versions
# Sources: artifacthub.io — stable releases only (no weekly/RC builds).
#
# IMPORTANT — repo migrations in effect as of 2026-03:
#   Tempo  → grafana-community (migrated 2026-01-30)
#   Loki   → grafana-community (migrating 2026-03-16)
#   Both repos are registered in install_LGTM.sh.
export LOKI_CHART_VERSION="6.53.0"     # grafana-community/loki
export TEMPO_CHART_VERSION="1.24.4"    # grafana-community/tempo (single binary)
export MIMIR_CHART_VERSION="6.0.5"     # grafana/mimir-distributed
export GRAFANA_CHART_VERSION="10.5.15" # grafana/grafana
# Alertmanager is built into Mimir - no separate chart needed

# ── Namespaces ────────────────────────────────────────────────────────────────
export MONITORING_NS="monitoring"

# ── S3 Bucket Configuration ───────────────────────────────────────────────────
# Call this in scripts that need S3 buckets
# Usage: configure_s3_buckets "lgtm-observability" "us-east-1"
configure_s3_buckets() {
  local base_bucket="$1"
  local region="${2:-us-west-2}"

  export S3_BUCKET="${base_bucket}"
  export S3_REGION="${region}"

  # All derived from ${S3_BUCKET} base — NOT from each other
  export S3_BUCKET_LOKI="${S3_BUCKET}-loki-data"
  export S3_BUCKET_TEMPO="${S3_BUCKET}-tempo-data"
  export S3_BUCKET_MIMIR="${S3_BUCKET}-mimir-data"
  export S3_BUCKET_MIMIR_ALERTMANAGER="${S3_BUCKET}-mimir-alertmanager-data"
  export S3_BUCKET_MIMIR_RULER="${S3_BUCKET}-mimir-ruler-data"
  export S3_BUCKET_GRAFANA="${S3_BUCKET}-grafana-data"
}

print_s3_config() {
  echo "  Base Bucket:        ${S3_BUCKET}"
  echo "  Loki Bucket:        ${S3_BUCKET_LOKI}"
  echo "  Tempo Bucket:       ${S3_BUCKET_TEMPO}"
  echo "  Mimir Bucket:       ${S3_BUCKET_MIMIR}"
  echo "  Mimir Alertmanager: ${S3_BUCKET_MIMIR_ALERTMANAGER}"
  echo "  Mimir Ruler:        ${S3_BUCKET_MIMIR_RULER}"
  echo "  Grafana Bucket:     ${S3_BUCKET_GRAFANA}"
  echo "  Region:             ${S3_REGION}"
}

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

# ── kubectl alias ─────────────────────────────────────────────────────────────
k() { kubectl "$@"; }

# ── Wait helpers ──────────────────────────────────────────────────────────────

# wait_rollout <namespace> <resource/name> [timeout]
wait_rollout() {
  local ns="$1" resource="$2" timeout="${3:-120s}"
  info "Waiting for rollout: ${resource} (${ns})..."
  kubectl rollout status "${resource}" -n "${ns}" --timeout="${timeout}"
}

# wait_cert_ready <cert-name> <namespace> [max-retries]
wait_cert_ready() {
  local name="$1" ns="$2" retries="${3:-24}"
  info "Waiting for certificate: ${name} (${ns})..."
  for i in $(seq 1 "${retries}"); do
    local status
    status=$(kubectl get certificate "${name}" -n "${ns}" \
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
resolve_values_dir() {
  local caller_dir
  caller_dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"

  if [[ -d "${caller_dir}/../values" ]]; then
    echo "${caller_dir}/../values"
  elif [[ -d "${caller_dir}/values" ]]; then
    echo "${caller_dir}/values"
  else
    die "Cannot locate values/ directory relative to ${caller_dir}"
  fi
}
