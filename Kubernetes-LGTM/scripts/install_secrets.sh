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

# ------------------------------------------------------------------------------
# FIX 1: Install htpasswd (apache2-utils) instead of mkpasswd (whois)
# htpasswd is the industry standard for Ingress Basic Auth.
# ------------------------------------------------------------------------------
if ! command -v htpasswd &>/dev/null; then
  info "Installing apache2-utils (provides htpasswd)..."
  if command -v apt-get &>/dev/null; then
    apt-get update -qq && apt-get install -y -qq apache2-utils >/dev/null 2>&1
  elif command -v apk &>/dev/null; then
    apk add --no-cache apache2-utils >/dev/null 2>&1
  elif command -v yum &>/dev/null; then
    yum install -y httpd-tools >/dev/null 2>&1
  elif command -v dnf &>/dev/null; then
    dnf install -y httpd-tools >/dev/null 2>&1
  elif [[ "$OSTYPE" == "darwin"* ]]; then
    if command -v brew &>/dev/null; then
       brew install httpd >/dev/null 2>&1 || true
    else
       warn "macOS detected but Homebrew not found. Ensure 'htpasswd' is in your PATH."
    fi
  fi
fi

command -v htpasswd &>/dev/null || die "htpasswd is required. Install apache2-utils or httpd-tools."

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
# FIX 2: Generate Auth File using htpasswd -B (Bcrypt)
# -c: create new file
# -B: force Bcrypt encryption (Secure & Standard for HAProxy Ingress)
# -b: read password from command line argument (batch mode)
# ------------------------------------------------------------------------------
htpasswd -cB -b /tmp/_lgtm_auth "${BASIC_AUTH_USER}" "${BASIC_AUTH_PASS}" 2>/dev/null

# Create secret with the auth file + raw credentials for reference
# The key 'auth' corresponds to the file content expected by HAProxy Ingress
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
