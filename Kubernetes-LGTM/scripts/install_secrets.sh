#!/usr/bin/env bash
# ==============================================================================
# scripts/install_secrets.sh
# Creates Kubernetes secrets required before Helm charts are deployed.
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPTS_DIR:-$SCRIPT_DIR}/lib/common.sh"

require_kubeconfig

: "${MONITORING_NS:=monitoring}"
: "${FORCE_RECREATE:=false}"

if ! kubectl get namespace "${MONITORING_NS}" &>/dev/null; then
  die "Namespace '${MONITORING_NS}' does not exist. Run install_k0s.sh first."
fi

# Ensure openssl is available
if ! command -v openssl &>/dev/null; then
  die "openssl is required but not found."
fi

# ── Grafana Admin Secret ───────────────────────────────────────────────────────
SECRET_NAME="grafana-admin"

if kubectl get secret "${SECRET_NAME}" -n "${MONITORING_NS}" &>/dev/null; then
  if [[ "${FORCE_RECREATE}" == "true" ]]; then
    warn "FORCE_RECREATE=true — deleting ${SECRET_NAME}..."
    kubectl delete secret "${SECRET_NAME}" -n "${MONITORING_NS}"
  else
    success "Grafana admin secret already exists — skipping"
  fi
fi

if ! kubectl get secret "${SECRET_NAME}" -n "${MONITORING_NS}" &>/dev/null; then
  GRAFANA_PASS="${GRAFANA_ADMIN_PASSWORD:-$(openssl rand -hex 32)}"
  info "Creating Grafana admin secret..."

  kubectl create secret generic "${SECRET_NAME}" \
    --namespace "${MONITORING_NS}" \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="${GRAFANA_PASS}"

  echo ""
  echo -e "${YELLOW}┌────────────────────────────────────────────────────────────────────────────────────┐${NC}"
  echo -e "${YELLOW}│  GRAFANA ADMIN CREDENTIALS — save now, shown once only                             │${NC}"
  echo -e "${YELLOW}│                                                                                    │${NC}"
  echo -e "${YELLOW}│  User    : admin                                                                   │${NC}"
  echo -e "${YELLOW}│  Password: ${BOLD}${GRAFANA_PASS}${NC}${YELLOW}                                    │${NC}"
  echo -e "${YELLOW}└────────────────────────────────────────────────────────────────────────────────────┘${NC}"
  echo ""
fi

# ── HAProxy Basic Auth Secret ──────────────────────────────────────────────────
BASIC_AUTH_SECRET="lgtm-basic-auth"
BASIC_AUTH_USER="${BASIC_AUTH_USER:-admin}"

if kubectl get secret "${BASIC_AUTH_SECRET}" -n "${MONITORING_NS}" &>/dev/null; then
  if [[ "${FORCE_RECREATE}" == "true" ]]; then
    warn "FORCE_RECREATE=true — deleting ${BASIC_AUTH_SECRET}..."
    kubectl delete secret "${BASIC_AUTH_SECRET}" -n "${MONITORING_NS}"
  else
    success "HAProxy basic auth secret already exists — skipping"
    BASIC_AUTH_PASS=$(kubectl get secret "${BASIC_AUTH_SECRET}" \
      -n "${MONITORING_NS}" -o jsonpath='{.data.password}' | base64 -d)
    export BASIC_AUTH_USER BASIC_AUTH_PASS
    success "install_secrets.sh complete"
    exit 0
  fi
fi

BASIC_AUTH_PASS="${BASIC_AUTH_PASS:-$(openssl rand -hex 16)}"
info "Creating HAProxy basic auth secret..."

# ------------------------------------------------------------------------------
# Generate password hash using openssl (standard MD5)
# Format: username:hashed_password
# ------------------------------------------------------------------------------
HASH=$(openssl passwd -1 "${BASIC_AUTH_PASS}")
echo "${BASIC_AUTH_USER}:${HASH}" >/tmp/_lgtm_auth

# Create secret with the auth file + raw credentials for reference
# The key 'auth' contains the htpasswd-style format that HAProxy expects
kubectl create secret generic "${BASIC_AUTH_SECRET}" \
  --namespace "${MONITORING_NS}" \
  --from-file=auth=/tmp/_lgtm_auth \
  --from-literal=username="${BASIC_AUTH_USER}" \
  --from-literal=password="${BASIC_AUTH_PASS}" \
  --dry-run=client -o yaml | kubectl apply -f -

rm -f /tmp/_lgtm_auth

echo ""
echo -e "${YELLOW}┌──────────────────────────────────────────────────────────────────────────────────────────────────┐${NC}"
echo -e "${YELLOW}│  LGTM BASIC AUTH CREDENTIALS — save now, shown once only                                         │${NC}"
echo -e "${YELLOW}│                                                                                                  │${NC}"
echo -e "${YELLOW}│  User    : ${BASIC_AUTH_USER}                                                                    │${NC}"
echo -e "${YELLOW}│  Password: ${BOLD}${BASIC_AUTH_PASS}${NC}${YELLOW}                                               │${NC}"
echo -e "${YELLOW}└──────────────────────────────────────────────────────────────────────────────────────────────────┘${NC}"
echo ""

export BASIC_AUTH_USER BASIC_AUTH_PASS
success "install_secrets.sh complete"
