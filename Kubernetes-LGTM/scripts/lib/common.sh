#!/usr/bin/env bash
# ==============================================================================
# scripts/lib/common.sh
# Shared functions, version pins, and helpers.
# Sourced by every install_*.sh — never executed directly.
# ==============================================================================

# ── Pinned versions ────────────────────────────────────────────────────────────
# All version bumps happen here. Check release pages in README.md.
export K0S_VERSION="v1.34.3+k0s.0"      # Updated to latest 1.34.x stable
export HELM_VERSION="v3.17.1"           # Latest Helm
export HAPROXY_CHART_VERSION="1.48.0"   # Updated to latest (released Feb 2026)
export LINKERD_VERSION="stable-2.14.11" # Updated to latest OSS stable branch (2.14.11)

export LOKI_CHART_VERSION="6.53.0"     # Already at latest
export TEMPO_CHART_VERSION="1.61.3"    # Already at latest (tempo-distributed)
export MIMIR_CHART_VERSION="6.0.5"     # Already at latest stable
export GRAFANA_CHART_VERSION="10.5.15" # Updated from 9.1.0 to the latest 10.x release

# ── Namespaces ────────────────────────────────────────────────────────────────
export MONITORING_NS="monitoring"

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
