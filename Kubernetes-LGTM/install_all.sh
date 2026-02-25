#!/usr/bin/env bash
# ==============================================================================
# install_all.sh
# Root-level orchestrator — runs all phases in order.
#
# Usage:
#   sudo bash install_all.sh
#
# With custom Grafana password:
#   GRAFANA_ADMIN_PASSWORD="strong-pass" sudo -E bash install_all.sh
#
# Skip completed phases after a partial/failed install:
#   SKIP_K0S=true SKIP_HAPROXY=true sudo bash install_all.sh
#
# Non-interactive mode (skip confirmation):
#   YES=true sudo bash install_all.sh
#
# Linkerd mTLS (optional):
#   SKIP_LINKERD=true       skip Linkerd installation
#   LINKERD_VIZ=false       skip Linkerd viz (~150MB)
#
# Available skip flags:
#   SKIP_K0S=true        skip scripts/install_k0s.sh
#   SKIP_HAPROXY=true    skip scripts/install_HAProxy.sh
#   SKIP_MTLS=true       skip scripts/install_mTLS.sh
#   SKIP_SECRETS=true    skip scripts/install_secrets.sh
#   SKIP_LGTM=true       skip scripts/install_LGTM.sh
#   SKIP_LINKERD=true    skip scripts/install_Linkerd.sh
#
# Project structure expected:
#   install_all.sh          ← this file
#   scripts/
#     lib/common.sh
#     install_k0s.sh
#     install_HAProxy.sh
#     install_mTLS.sh
#     install_secrets.sh
#     install_LGTM.sh
#   values/
#     lgtm-values.yaml
#     mtls-patch.yaml
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${ROOT_DIR}/scripts"
VALUES_DIR="${ROOT_DIR}/values"

# shellcheck source=scripts/lib/common.sh
source "${SCRIPTS_DIR}/lib/common.sh"

require_root

# ── Skip flags ────────────────────────────────────────────────────────────────────
SKIP_K0S="${SKIP_K0S:-false}"
SKIP_HAPROXY="${SKIP_HAPROXY:-false}"
SKIP_MTLS="${SKIP_MTLS:-false}"
SKIP_SECRETS="${SKIP_SECRETS:-false}"
SKIP_LGTM="${SKIP_LGTM:-false}"
SKIP_LINKERD="${SKIP_LINKERD:-false}"
YES="${YES:-false}"

# ── Phase runner helpers ──────────────────────────────────────────────────────
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
  bash "${script}"
  echo -e "${GREEN}  ✓  Phase ${num} complete in $((SECONDS - t))s${NC}"
}

# ══════════════════════════════════════════════════════════════════════════════
# Pre-flight: verify all required files are present before starting
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  LGTM Full Stack Install                                 ║${NC}"
echo -e "${BOLD}║  k0s · HAProxy · cert-manager · Linkerd · Loki/Tempo/Mimir║${NC}"
echo -e "${BOLD}║  Target: t4g.xlarge · Debian 12 ARM64 · Single Node      ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

info "Verifying required files..."
MISSING=false

for script in \
  "${SCRIPTS_DIR}/lib/common.sh" \
  "${SCRIPTS_DIR}/install_k0s.sh" \
  "${SCRIPTS_DIR}/install_HAProxy.sh" \
  "${SCRIPTS_DIR}/install_mTLS.sh" \
  "${SCRIPTS_DIR}/install_secrets.sh" \
  "${SCRIPTS_DIR}/install_Linkerd.sh" \
  "${SCRIPTS_DIR}/install_LGTM.sh"; do
  if [[ -f "$script" ]]; then
    info "  found: ${script##"${ROOT_DIR}/"}"
  else
    warn "  MISSING: ${script##"${ROOT_DIR}/"}"
    MISSING=true
  fi
done

for vfile in \
  "${VALUES_DIR}/lgtm-values.yaml" \
  "${VALUES_DIR}/mtls-patch.yaml" \
  "${VALUES_DIR}/haproxy-values.yaml" \
  "${VALUES_DIR}/cert-manager-values.yaml"; do
  if [[ -f "$vfile" ]]; then
    info "  found: ${vfile##"${ROOT_DIR}/"}"
  else
    warn "  MISSING: ${vfile##"${ROOT_DIR}/"}"
    MISSING=true
  fi
done

[[ "${MISSING}" == "false" ]] || die "Missing files detected — ensure the full project is uploaded."
success "All required files present"

# ── Battle-ready pre-flight checks ───────────────────────────────────────────────
info "Running battle-ready pre-flight checks..."

# Check disk space
check_disk_space 20

# Check ports 80, 443 for HAProxy
if [[ "${SKIP_HAPROXY}" != "true" ]]; then
  check_ports 80 || warn "Port 80 may be in use - HAProxy installation could fail"
  check_ports 443 || warn "Port 443 may be in use - HAProxy installation could fail"
fi

# Check k0s not already installed (unless skipping)
if [[ "${SKIP_K0S}" != "true" ]]; then
  check_k0s_not_installed || {
    if [[ "${YES}" != "true" ]]; then
      read -r -p "  Continue anyway? [y/N] " confirm
      [[ "${confirm,,}" == "y" ]] || { info "Aborted."; exit 0; }
    fi
  }
  
  # Backup existing kubeconfig
  backup_kubeconfig
fi

# Check memory
info "Checking available memory..."
AVAILABLE_MEM=$(free -g | awk 'NR==2 {print $7}')
info "  Available: ${AVAILABLE_MEM}GB free memory"
if [[ "${AVAILABLE_MEM}" -lt 8 ]]; then
  warn "  WARNING: Less than 8GB free memory - installation may fail"
fi

# DNS check disabled - HAProxy now works with IP addresses on ports 80/443
# Domain-based access will work after DNS is configured via LoadBalancer

# ── Node resource check (only if k0s already running) ───────────────────────────
if [[ "${SKIP_K0S}" == "true" ]]; then
  info "Skipping k0s - checking existing cluster resources..."
  if k0s kubectl get nodes &>/dev/null 2>&1; then
    NODE_CPU=$(k0s kubectl get nodes -o jsonpath='{.items[0].status.capacity.cpu}' 2>/dev/null || echo "0")
    NODE_MEM=$(k0s kubectl get nodes -o jsonpath='{.items[0].status.capacity.memory}' 2>/dev/null | sed 's/Ki//' || echo "0")
    NODE_MEM_GB=$((NODE_MEM / 1024 / 1024))
    info "  Detected: ${NODE_CPU} vCPUs, ~${NODE_MEM_GB} GB RAM"
  else
    info "  No existing cluster detected - will install k0s"
  fi
fi

# ── Confirm ───────────────────────────────────────────────────────────────────
if [[ "${YES}" != "true" ]]; then
  echo ""
  warn "This will install k0s, HAProxy, cert-manager, Linkerd (mTLS), and LGTM stack."
  warn "Intended for a FRESH Debian 12 ARM64 instance (t4g.xlarge)."
  echo ""
  read -r -p "  Continue? [y/N] " confirm
  [[ "${confirm,,}" == "y" ]] || {
    info "Aborted."
    exit 0
  }
else
  info "Running in non-interactive mode (YES=true)"
fi

TOTAL_START=$SECONDS

# ══════════════════════════════════════════════════════════════════════════════
# Phases
# ══════════════════════════════════════════════════════════════════════════════
_run_phase 1 "k0s — System prep + Kubernetes + Helm" \
  "${SKIP_K0S}" "${SCRIPTS_DIR}/install_k0s.sh"

_run_phase 2 "HAProxy — Ingress Controller" \
  "${SKIP_HAPROXY}" "${SCRIPTS_DIR}/install_HAProxy.sh"

_run_phase 3 "mTLS — cert-manager + PKI + Certificates" \
  "${SKIP_MTLS}" "${SCRIPTS_DIR}/install_mTLS.sh"

_run_phase 4 "Secrets — Grafana admin credentials + Basic Auth" \
  "${SKIP_SECRETS}" "${SCRIPTS_DIR}/install_secrets.sh"

_run_phase 5 "Linkerd — Service Mesh mTLS (optional)" \
  "${SKIP_LINKERD}" "${SCRIPTS_DIR}/install_Linkerd.sh"

_run_phase 6 "LGTM — Loki · Tempo · Mimir · Grafana" \
  "${SKIP_LGTM}" "${SCRIPTS_DIR}/install_LGTM.sh"

# ══════════════════════════════════════════════════════════════════════════════
# Done
# ══════════════════════════════════════════════════════════════════════════════
TOTAL_MIN=$(((SECONDS - TOTAL_START) / 60))
TOTAL_SEC=$(((SECONDS - TOTAL_START) % 60))

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  All phases complete in ${TOTAL_MIN}m ${TOTAL_SEC}s                              ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "  Nodes:       kubectl get nodes -o wide"
echo "  Pods:        kubectl get pods -n monitoring -o wide"
echo "  Helm:        helm list -n monitoring"
echo "  Certs:       kubectl get certificates -n monitoring"
echo ""
echo "  Grafana:     https://grafana.example.com"
echo "               (DNS A record → this instance's public IP)"
echo ""
echo "  Export root CA for browser trust:"
echo "    kubectl get secret lgtm-root-ca-secret -n monitoring \\"
echo "      -o jsonpath='{.data.ca\\.crt}' | base64 -d > lgtm-root-ca.crt"
echo ""
