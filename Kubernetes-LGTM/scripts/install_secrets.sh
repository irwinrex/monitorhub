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
#   -f, --force                Force recreate all secrets
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
    echo "Usage: $0 [-f|--force]"
    echo "  -f  Force recreate all secrets"
    echo ""
    echo "Env vars:"
    echo "  GRAFANA_ADMIN_PASSWORD  Grafana admin password"
    echo "  BASIC_AUTH_USER         Basic auth username (default: admin)"
    echo "  BASIC_AUTH_PASS         Basic auth password"
    exit 0
    ;;
  *) shift ;;
  esac
done

: "${MONITORING_NS:=monitoring}"

# Ensure monitoring namespace exists
if ! kubectl get namespace "${MONITORING_NS}" &>/dev/null; then
  die "Namespace '${MONITORING_NS}' does not exist. Run install_k0s.sh first."
fi

# Ensure htpasswd is available — install if missing
if ! command -v htpasswd &>/dev/null; then
  info "htpasswd not found — installing apache2-utils..."
  apt-get install -y apache2-utils -qq ||
    die "Failed to install apache2-utils. Install manually: apt-get install apache2-utils"
fi

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

# ── HAProxy Basic Auth Secret (monitoring namespace) ─────────────────────────
# HAProxy can read secrets from monitoring namespace using namespace/secret-name
# Referenced in ingress: haproxy.org/auth-secret: "monitoring/lgtm-basic-auth"
BASIC_AUTH_SECRET="lgtm-basic-auth"
BASIC_AUTH_USER="${BASIC_AUTH_USER:-admin}"

if kubectl get secret "${BASIC_AUTH_SECRET}" -n "${MONITORING_NS}" &>/dev/null; then
  if [[ "${FORCE_RECREATE}" == "true" ]]; then
    warn "FORCE_RECREATE=true — deleting existing secret ${BASIC_AUTH_SECRET}..."
    kubectl delete secret "${BASIC_AUTH_SECRET}" -n "${MONITORING_NS}"
  else
    success "HAProxy basic auth secret already exists — skipping"
    # Export for install_all.sh summary even when skipping
    BASIC_AUTH_PASS=$(kubectl get secret "${BASIC_AUTH_SECRET}" -n "${MONITORING_NS}" \
      -o jsonpath='{.data.password}' | base64 -d)
    export BASIC_AUTH_USER BASIC_AUTH_PASS
    success "install_secrets.sh complete"
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

# htpasswd -nbm = apr1 (MD5) hash — required by HAProxy, bcrypt not supported
HTPASSWD=$(htpasswd -nbm "${BASIC_AUTH_USER}" "${BASIC_AUTH_PASS}")

# Verify the hash works before storing
printf '%s' "${HTPASSWD}" >/tmp/_auth_verify
htpasswd -vb /tmp/_auth_verify "${BASIC_AUTH_USER}" "${BASIC_AUTH_PASS}" &>/dev/null ||
  die "htpasswd hash verification failed — password not stored"
rm -f /tmp/_auth_verify
info "htpasswd hash verified OK"

# Write to file — avoids shell $ expansion corrupting the apr1 hash
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
success "install_secrets.sh complete"
