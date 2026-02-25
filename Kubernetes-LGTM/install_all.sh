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
# Available skip flags:
#   SKIP_K0S=true        skip scripts/install_k0s.sh
#   SKIP_HAPROXY=true   skip scripts/install_HAProxy.sh
#   SKIP_MTLS=true      skip scripts/install_mTLS.sh (Linkerd mTLS)
#   SKIP_SECRETS=true   skip scripts/install_secrets.sh
#   SKIP_LGTM=true      skip scripts/install_LGTM.sh
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
#     haproxy-values.yaml
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
SKIP_POSTGRES="${SKIP_POSTGRES:-false}"
SKIP_SECRETS="${SKIP_SECRETS:-false}"
SKIP_LGTM="${SKIP_LGTM:-false}"
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
echo -e "${BOLD}║  k0s · HAProxy · Linkerd · Loki/Tempo/Mimir    ║${NC}"
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
  "${VALUES_DIR}/haproxy-values.yaml" \
  "${VALUES_DIR}/ingress-values.yaml"; do
  if [[ -f "$vfile" ]]; then
    info "  found: ${vfile##"${ROOT_DIR}/"}"
  else
    warn "  MISSING: ${vfile##"${ROOT_DIR}/"}"
    MISSING=true
  fi
done

[[ "${MISSING}" == "false" ]] || die "Missing files detected — ensure the full project is uploaded."
success "All required files present"

# ── Confirm ───────────────────────────────────────────────────────────────────
if [[ "${YES}" != "true" ]]; then
  echo ""
  warn "This will install k0s, HAProxy, Linkerd (mTLS), and LGTM stack."
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

_run_phase 2 "HAProxy — Ingress Controller (HTTP 80)" \
  "${SKIP_HAPROXY}" "${SCRIPTS_DIR}/install_HAProxy.sh"

_run_phase 3 "Linkerd — Pod-to-Pod mTLS" \
  "${SKIP_MTLS}" "${SCRIPTS_DIR}/install_mTLS.sh"

_run_phase 4 "PostgreSQL — Database for HA" \
  "${SKIP_POSTGRES}" "${SCRIPTS_DIR}/install_Postgres.sh"

_run_phase 5 "Secrets — Grafana admin credentials + Basic Auth" \
  "${SKIP_SECRETS}" "${SCRIPTS_DIR}/install_secrets.sh"

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
