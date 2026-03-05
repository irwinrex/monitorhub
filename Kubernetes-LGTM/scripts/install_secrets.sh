#!/usr/bin/env bash
# ==============================================================================
# scripts/install_secrets.sh
# Creates Kubernetes secrets required before Helm charts are deployed.
#
# Secrets managed:
#   grafana-admin    (namespace: monitoring)  — Grafana admin login
#   basic-auth       (namespace: kube-system) — HAProxy basic auth for LGTM APIs
#
# Options:
#   -f, --force                Force recreate secrets
#   GRAFANA_ADMIN_PASSWORD="x" bash scripts/install_secrets.sh
#   BASIC_AUTH_USER="myuser"   bash scripts/install_secrets.sh
#   BASIC_AUTH_PASS="mypass"   bash scripts/install_secrets.sh
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_kubeconfig

FORCE_RECREATE="${FORCE_RECREATE:-false}"

while [[ $# -gt 0 ]]; do
  case "$1" in
  -f | --force)
    FORCE_RECREATE="true"
    shift
    ;;
  -h | --help)
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -f, --force  Force recreate secrets"
    echo ""
    echo "Environment variables:"
    echo "  GRAFANA_ADMIN_PASSWORD  Set Grafana admin password"
    echo "  BASIC_AUTH_USER        Set basic auth username"
    echo "  BASIC_AUTH_PASS        Set basic auth password"
    exit 0
    ;;
  *)
    shift
    ;;
  esac
done

: "${MONITORING_NS:=monitoring}"

# Ensure monitoring namespace exists
if ! kubectl get namespace "${MONITORING_NS}" &>/dev/null; then
  die "Namespace '${MONITORING_NS}' does not exist. Run install_k0s.sh first."
fi

FORCE_RECREATE="${FORCE_RECREATE:-false}"

# ── Grafana Admin Secret (monitoring namespace) ────────────────────────────────
SECRET_NAME="grafana-admin"

if kubectl get secret "${SECRET_NAME}" -n "${MONITORING_NS}" &>/dev/null; then
  if [[ "${FORCE_RECREATE}" == "true" ]]; then
    warn "FORCE_RECREATE=true — deleting existing secret ${SECRET_NAME}..."
    kubectl delete secret "${SECRET_NAME}" -n "${MONITORING_NS}"
  else
    success "Grafana admin secret already exists — skipping"
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
  echo -e "${YELLOW}│  Password: ${BOLD}${GRAFANA_PASS}${NC}${YELLOW}                        │${NC}"
  echo -e "${YELLOW}│                                                          │${NC}"
  echo -e "${YELLOW}│  Retrieve later:                                         │${NC}"
  echo -e "${YELLOW}│  kubectl get secret grafana-admin -n monitoring \\        │${NC}"
  echo -e "${YELLOW}│    -o jsonpath='{.data.admin-password}' | base64 -d     │${NC}"
  echo -e "${YELLOW}└──────────────────────────────────────────────────────────┘${NC}"
  echo ""
fi

# ── HAProxy Basic Auth Secret (kube-system namespace) ─────────────────────────
# Stored in kube-system so HAProxy ingress controller can read it directly.
# Referenced in ingress annotations as: haproxy.org/auth-secret: "kube-system/basic-auth"
BASIC_AUTH_SECRET="basic-auth"
BASIC_AUTH_USER="${BASIC_AUTH_USER:-admin}"

if kubectl get secret "${BASIC_AUTH_SECRET}" -n kube-system &>/dev/null; then
  if [[ "${FORCE_RECREATE}" == "true" ]]; then
    warn "FORCE_RECREATE=true — deleting existing secret ${BASIC_AUTH_SECRET}..."
    kubectl delete secret "${BASIC_AUTH_SECRET}" -n kube-system
  else
    success "HAProxy basic auth secret already exists — skipping"
    exit 0
  fi
fi

if [[ -n "${BASIC_AUTH_PASS:-}" ]]; then
  info "Using provided BASIC_AUTH_PASS"
else
  BASIC_AUTH_PASS="$(openssl rand -hex 16)"
  info "Generated random basic auth password"
fi

info "Creating HAProxy basic auth secret in kube-system..."

if command -v htpasswd &>/dev/null; then
  HTPASSWD=$(htpasswd -nbm "${BASIC_AUTH_USER}" "${BASIC_AUTH_PASS}")
else
  info "htpasswd not found — using openssl apr1 fallback"
  HTPASSWD="${BASIC_AUTH_USER}:$(openssl passwd -apr1 "${BASIC_AUTH_PASS}")"
fi

kubectl create secret generic "${BASIC_AUTH_SECRET}" \
  --namespace kube-system \
  --from-literal=auth="${HTPASSWD}" \
  --from-literal=username="${BASIC_AUTH_USER}" \
  --from-literal=password="${BASIC_AUTH_PASS}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo -e "${YELLOW}┌──────────────────────────────────────────────────────────┐${NC}"
echo -e "${YELLOW}│  LGTM BASIC AUTH CREDENTIALS — save now, shown once only │${NC}"
echo -e "${YELLOW}│                                                          │${NC}"
echo -e "${YELLOW}│  User    : ${BASIC_AUTH_USER}                                        │${NC}"
echo -e "${YELLOW}│  Password: ${BOLD}${BASIC_AUTH_PASS}${NC}${YELLOW}                        │${NC}"
echo -e "${YELLOW}│                                                          │${NC}"
echo -e "${YELLOW}│  Retrieve later:                                         │${NC}"
echo -e "${YELLOW}│  kubectl get secret basic-auth -n kube-system \\         │${NC}"
echo -e "${YELLOW}│    -o jsonpath='{.data.password}' | base64 -d           │${NC}"
echo -e "${YELLOW}└──────────────────────────────────────────────────────────┘${NC}"
echo ""

export BASIC_AUTH_USER BASIC_AUTH_PASS
success "install_secrets.sh complete"
