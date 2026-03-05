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
#   grafana-basic-auth (namespace: monitoring)
#     username = admin (or $BASIC_AUTH_USER)
#     password = auto-generated OR $BASIC_AUTH_PASS
#
# Options:
#   GRAFANA_ADMIN_PASSWORD="x"  sudo -E bash scripts/install_secrets.sh
#   BASIC_AUTH_USER="admin"     sudo -E bash scripts/install_secrets.sh
#   BASIC_AUTH_PASS="pass"     sudo -E bash scripts/install_secrets.sh
#   FORCE_RECREATE=true        sudo bash scripts/install_secrets.sh
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_root
require_kubeconfig

: "${MONITORING_NS:=monitoring}"

# Ensure monitoring namespace exists
if ! kubectl get namespace "${MONITORING_NS}" &>/dev/null 2>&1; then
  die "Namespace '${MONITORING_NS}' does not exist. Run install_k0s.sh first."
fi

FORCE_RECREATE="${FORCE_RECREATE:-false}"
SECRET_NAME="grafana-admin"

# ── Grafana Admin Secret ───────────────────────────────────────────────────────
if kubectl get secret "${SECRET_NAME}" -n "${MONITORING_NS}" &>/dev/null; then
  if [[ "${FORCE_RECREATE}" == "true" ]]; then
    warn "FORCE_RECREATE=true — deleting existing secret..."
    kubectl delete secret "${SECRET_NAME}" -n "${MONITORING_NS}"
  else
    success "Grafana admin secret already exists"
  fi
fi

if ! kubectl get secret "${SECRET_NAME}" -n "${MONITORING_NS}" &>/dev/null; then
  if [[ -n "${GRAFANA_ADMIN_PASSWORD:-}" ]]; then
    GRAFANA_PASS="${GRAFANA_ADMIN_PASSWORD}"
    info "Using provided GRAFANA_ADMIN_PASSWORD"
  else
    GRAFANA_PASS="$(openssl rand -hex 32)"
    info "Generated random Grafana admin password"
  fi

  kubectl create secret generic "${SECRET_NAME}" \
    --namespace "${MONITORING_NS}" \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="${GRAFANA_PASS}"

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
fi

# ── HAProxy Basic Auth Secret (for Loki, Tempo, Mimir) ─────────────────────────
BASIC_AUTH_SECRET="grafana-basic-auth"
BASIC_AUTH_USER="${BASIC_AUTH_USER:-admin}"
BASIC_AUTH_PASS="${BASIC_AUTH_PASS:-$(openssl rand -hex 16)}"

info "Creating HAProxy basic auth secret for API endpoints (LGTM)..."
if command -v htpasswd &>/dev/null; then
  HTPASSWD=$(htpasswd -nbm "${BASIC_AUTH_USER}" "${BASIC_AUTH_PASS}" 2>/dev/null || die "htpasswd failed"
else
  info "htpasswd not available - using openssl for basic auth"
  HTPASSWD=$(openssl passwd -apr1 "${BASIC_AUTH_PASS}" 2>/dev/null | head -1)
  HTPASSWD="${BASIC_AUTH_USER}:${HTPASSWD}"
fi

kubectl create secret generic "${BASIC_AUTH_SECRET}" \
  --namespace "${MONITORING_NS}" \
  --from-literal=auth="${HTPASSWD}" \
  --from-literal=username="${BASIC_AUTH_USER}" \
  --from-literal=password="${BASIC_AUTH_PASS}" \
  --dry-run=client -o yaml | kubectl apply -f -

export BASIC_AUTH_USER BASIC_AUTH_PASS
success "HAProxy basic auth configured (user: ${BASIC_AUTH_USER}, pass: ${BASIC_AUTH_PASS})"
echo ""
