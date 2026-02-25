#!/usr/bin/env bash
# ==============================================================================
# scripts/lib/common.sh
# Shared functions, version pins, and helpers.
# Sourced by every install_*.sh — never executed directly.
# ==============================================================================

# ── Pinned versions ────────────────────────────────────────────────────────────
# All version bumps happen here. Check release pages in README.md.
export K0S_VERSION="v1.32.7+k0s.0"
export HELM_VERSION="v3.17.1"
export HAPROXY_CHART_VERSION="1.42.2"   # haproxytech/kubernetes-ingress
export CERTMANAGER_VERSION="v1.17.1"    # jetstack/cert-manager
export LINKERD_VERSION="stable-2.14.10" # linkerd/linkerd2 — ARM64 supported from 2.12+

export LOKI_CHART_VERSION="6.29.0"
export TEMPO_CHART_VERSION="1.21.1"
export MIMIR_CHART_VERSION="5.6.0"
export GRAFANA_CHART_VERSION="8.9.1"

# ── Namespaces ────────────────────────────────────────────────────────────────
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

# ── Linkerd CLI helper ────────────────────────────────────────────────────────
require_linkerd() {
  command -v linkerd &>/dev/null || die "linkerd CLI not found.\n  Run: sudo bash scripts/install_linkerd.sh first"
}

# wait_linkerd_ready — polls until all Linkerd control plane pods are Running
wait_linkerd_ready() {
  info "Waiting for Linkerd control plane to be ready..."
  for i in $(seq 1 36); do
    if linkerd check --pre 2>/dev/null | grep -q "Status check results are √"; then
      success "Linkerd control plane is healthy"
      return 0
    fi
    # Fallback: just wait for deployments directly
    if k0s kubectl get deploy -n linkerd 2>/dev/null | grep -v "0/"; then
      if k0s kubectl rollout status deploy/linkerd-destination -n linkerd --timeout=10s &>/dev/null &&
        k0s kubectl rollout status deploy/linkerd-identity -n linkerd --timeout=10s &>/dev/null &&
        k0s kubectl rollout status deploy/linkerd-proxy-injector -n linkerd --timeout=10s &>/dev/null; then
        success "Linkerd control plane rollouts complete"
        return 0
      fi
    fi
    [[ $i -eq 36 ]] && die "Linkerd did not become ready.\n  Debug: linkerd check\n  Pods:  kubectl get pods -n linkerd"
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
