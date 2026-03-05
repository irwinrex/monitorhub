#!/usr/bin/env bash
# ==============================================================================
# scripts/install_secrets.sh
# Creates Kubernetes secrets required before Helm charts are deployed.
#
# Secrets managed:
#   grafana-admin    (namespace: monitoring)  — Grafana admin login
#   lgtm-basic-auth  (namespace: monitoring)  — HAProxy basic auth for LGTM APIs
#
# Options:
#   GRAFANA_ADMIN_PASSWORD="x" bash scripts/install_secrets.sh
#   BASIC_AUTH_USER="myuser"   bash scripts/install_secrets.sh
#   BASIC_AUTH_PASS="mypass"   bash scripts/install_secrets.sh
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_kubeconfig

: "${MONITORING_NS:=monitoring}"

# Ensure monitoring namespace exists
if ! kubectl get namespace "${MONITORING_NS}" &>/dev/null; then
  die "Namespace '${MONITORING_NS}' does not exist. Run install_k0s.sh first."
fi

# Ensure htpasswd is available
if ! command -v htpasswd &>/dev/null; then
  info "htpasswd not found — installing apache2-utils..."
  apt-get install -y apache2-utils -qq ||
    die "Failed to install apache2-utils. Install manually: apt-get install apache2-utils"
fi

# ── Grafana Admin Secret (monitoring namespace) ───────────────────────────────-
SECRET_NAME="grafana-admin"

if kubectl get secret "${SECRET_NAME}" -n "${MONITORING_NS}" &>/dev/null; then
  success "Grafana admin secret already exists — skipping"
else
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
  echo -e "${YELLOW}│  Password: ${BOLD}${GRAFANA_PASS}${NC}${YELLOW}                        │${NC}"
  echo -e "${YELLOW}│                                                          │${NC}"
  echo -e "${YELLOW}│  Retrieve later:                                         │${NC}"
  echo -e "${YELLOW}│  kubectl get secret grafana-admin -n monitoring \\        │${NC}"
  echo -e "${YELLOW}│    -o jsonpath='{.data.admin-password}' | base64 -d     │${NC}"
  echo -e "${YELLOW}└──────────────────────────────────────────────────────────┘${NC}"
  echo ""
fi

# ── HAProxy Basic Auth Secret (monitoring namespace) ─────────────────────────
BASIC_AUTH_SECRET="lgtm-basic-auth"

if kubectl get secret "${BASIC_AUTH_SECRET}" -n "${MONITORING_NS}" &>/dev/null; then
  success "HAProxy basic auth secret already exists — skipping"
  BASIC_AUTH_PASS=$(kubectl get secret "${BASIC_AUTH_SECRET}" -n "${MONITORING_NS}" \
    -o jsonpath='{.data.password}' | base64 -d)
  export BASIC_AUTH_PASS
else
  BASIC_AUTH_USER="${BASIC_AUTH_USER:-admin}"

  if [[ -n "${BASIC_AUTH_PASS:-}" ]]; then
    info "Using provided BASIC_AUTH_PASS"
  else
    BASIC_AUTH_PASS="$(openssl rand -hex 16)"
    info "Generated random basic auth password"
  fi

  info "Creating HAProxy basic auth secret in monitoring..."

  HTPASSWD=$(htpasswd -nbm "${BASIC_AUTH_USER}" "${BASIC_AUTH_PASS}")

  printf '%s' "${HTPASSWD}" >/tmp/_basic_auth

  kubectl create secret generic "${BASIC_AUTH_SECRET}" \
    --namespace "${MONITORING_NS}" \
    --from-file=auth=/tmp/_basic_auth \
    --from-literal=username="${BASIC_AUTH_USER}" \
    --from-literal=password="${BASIC_AUTH_PASS}" \
    --dry-run=client -o yaml | kubectl apply -f -
  rm -f /tmp/_basic_auth

  echo ""
  echo -e "${YELLOW}┌──────────────────────────────────────────────────────────┐${NC}"
  echo -e "${YELLOW}│  LGTM BASIC AUTH CREDENTIALS — save now, shown once only │${NC}"
  echo -e "${YELLOW}│                                                          │${NC}"
  echo -e "${YELLOW}│  User    : ${BASIC_AUTH_USER}                                        │${NC}"
  echo -e "${YELLOW}│  Password: ${BOLD}${BASIC_AUTH_PASS}${NC}${YELLOW}                        │${NC}"
  echo -e "${YELLOW}│                                                          │${NC}"
  echo -e "${YELLOW}│  Retrieve later:                                         │${NC}"
  echo -e "${YELLOW}│  kubectl get secret lgtm-basic-auth -n monitoring \\      │${NC}"
  echo -e "${YELLOW}│    -o jsonpath='{.data.password}' | base64 -d           │${NC}"
  echo -e "${YELLOW}└──────────────────────────────────────────────────────────┘${NC}"
  echo ""

  export BASIC_AUTH_USER BASIC_AUTH_PASS
fi

success "install_secrets.sh complete"
