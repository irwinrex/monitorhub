#!/usr/bin/env bash
# ==============================================================================
# scripts/install_secrets.sh
# Creates Kubernetes secrets required before Helm charts are deployed.
#
# Run standalone:   sudo bash scripts/install_secrets.sh
# Run via all:      called automatically by install_all.sh
#
# Secrets managed:
#   grafana-admin  (namespace: monitoring)
#     admin-user     = admin
#     admin-password = auto-generated OR $GRAFANA_ADMIN_PASSWORD
#
# Idempotent: if the secret already exists, it is left unchanged.
#
# Options:
#   GRAFANA_ADMIN_PASSWORD="x"  sudo -E bash scripts/install_secrets.sh
#   BASIC_AUTH_USER="admin"      sudo -E bash scripts/install_secrets.sh
#   BASIC_AUTH_PASS="pass"       sudo -E bash scripts/install_secrets.sh
#   FORCE_RECREATE=true         sudo bash scripts/install_secrets.sh
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
require_kubeconfig

header "Phase 4 — Secrets"

# Ensure monitoring namespace exists
if ! k0s kubectl get namespace "${MONITORING_NS}" &>/dev/null 2>&1; then
  die "Namespace '${MONITORING_NS}' does not exist. Run install_k0s.sh first."
fi

FORCE_RECREATE="${FORCE_RECREATE:-false}"
SECRET_NAME="grafana-admin"

# ── Check existing secret ─────────────────────────────────────────────────────
if k0s kubectl get secret "${SECRET_NAME}" -n "${MONITORING_NS}" &>/dev/null; then
  if [[ "${FORCE_RECREATE}" == "true" ]]; then
    warn "FORCE_RECREATE=true — deleting existing secret..."
    k0s kubectl delete secret "${SECRET_NAME}" -n "${MONITORING_NS}"
  else
    success "Secret '${SECRET_NAME}' already exists — skipping"
    info "To regenerate: FORCE_RECREATE=true sudo bash scripts/install_secrets.sh"
    echo ""
    exit 0
  fi
fi

# ── Generate or use provided password ────────────────────────────────────────
if [[ -n "${GRAFANA_ADMIN_PASSWORD:-}" ]]; then
  GRAFANA_PASS="${GRAFANA_ADMIN_PASSWORD}"
  info "Using provided GRAFANA_ADMIN_PASSWORD"
else
  GRAFANA_PASS="$(openssl rand -hex 32)"
  info "Generated random Grafana admin password"
fi

k0s kubectl create secret generic "${SECRET_NAME}" \
  --namespace "${MONITORING_NS}" \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="${GRAFANA_PASS}"

# ── HAProxy Basic Auth Secret ─────────────────────────────────────────────────
BASIC_AUTH_SECRET="grafana-basic-auth"
BASIC_AUTH_USER="${BASIC_AUTH_USER:-admin}"
BASIC_AUTH_PASS="${BASIC_AUTH_PASS:-${GRAFANA_PASS}}"

info "Creating HAProxy basic auth secret..."
if command -v htpasswd &>/dev/null; then
  HTPASSWD=$(htpasswd -nbm "${BASIC_AUTH_USER}" "${BASIC_AUTH_PASS}" 2>/dev/null || die "htpasswd failed")
else
  info "htpasswd not available - using openssl for basic auth"
  HTPASSWD=$(openssl passwd -apr1 "${BASIC_AUTH_PASS}" 2>/dev/null | head -1)
  HTPASSWD="${BASIC_AUTH_USER}:${HTPASSWD}"
fi

k0s kubectl create secret generic "${BASIC_AUTH_SECRET}" \
  --namespace "${MONITORING_NS}" \
  --from-literal=auth="${HTPASSWD}" \
  --dry-run=client -o yaml | k0s kubectl apply -f -

success "HAProxy basic auth configured (${BASIC_AUTH_USER})"

echo ""
echo -e "${YELLOW}┌──────────────────────────────────────────────────────────┐${NC}"
echo -e "${YELLOW}│  GRAFANA ADMIN CREDENTIALS — save now, shown once only   │${NC}"
echo -e "${YELLOW}│                                                          │${NC}"
echo -e "${YELLOW}│  User    : admin                                         │${NC}"
echo -e "${YELLOW}│  Password: ${BOLD}${GRAFANA_PASS}${NC}${YELLOW}   │${NC}"
echo -e "${YELLOW}│                                                          │${NC}"
echo -e "${YELLOW}│  Retrieve later:                                         │${NC}"
echo -e "${YELLOW}│  kubectl get secret grafana-admin -n monitoring          │${NC}"
echo -e "${YELLOW}│    -o jsonpath='{.data.admin-password}' | base64 -d     │${NC}"
echo -e "${YELLOW}└──────────────────────────────────────────────────────────┘${NC}"
echo ""
success "install_secrets.sh complete"
echo ""
