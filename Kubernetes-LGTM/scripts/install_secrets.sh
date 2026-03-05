#!/usr/bin/env bash
# ==============================================================================
# scripts/install_secrets.sh
# Creates Kubernetes secrets required before Helm charts are deployed.
#
# Secrets managed:
#   grafana-admin    (namespace: monitoring)  — Grafana admin login
#   lgtm-basic-auth  (namespace: monitoring)  — HAProxy basic auth for LGTM APIs
#
# Usage:
#   bash scripts/install_secrets.sh
#   bash scripts/install_secrets.sh -b mybucket -r us-east-1
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPTS_DIR:-$SCRIPT_DIR}/lib/common.sh"

require_kubeconfig

: "${MONITORING_NS:=monitoring}"

if ! kubectl get namespace "${MONITORING_NS}" &>/dev/null; then
  die "Namespace '${MONITORING_NS}' does not exist. Run install_k0s.sh first."
fi

if ! command -v htpasswd &>/dev/null; then
  info "htpasswd not found — installing apache2-utils..."
  apt-get install -y apache2-utils -qq ||
    die "Failed to install apache2-utils"
fi

# ── Parse args ─────────────────────────────────────────────────────────────────
_BUCKET=""
_REGION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
  -b|--bucket) _BUCKET="$2"; shift 2 ;;
  -r|--region) _REGION="$2"; shift 2 ;;
  *) shift ;;
  esac
done

[[ -n "$_BUCKET" ]] && S3_BUCKET="$_BUCKET"
[[ -n "$_REGION" ]] && S3_REGION="$_REGION"

# ── Grafana Admin Secret ───────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}━━━ Grafana Admin Credentials ━━━${NC}"
echo ""

if [[ -z "${GRAFANA_ADMIN_PASSWORD:-}" ]]; then
  read -r -p "Grafana admin password: " GRAFANA_ADMIN_PASSWORD
fi
GRAFANA_PASS="${GRAFANA_ADMIN_PASSWORD:-admin}"

kubectl delete secret grafana-admin -n "${MONITORING_NS}" 2>/dev/null || true

kubectl create secret generic grafana-admin \
  --namespace "${MONITORING_NS}" \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="${GRAFANA_PASS}"

echo ""
success "Grafana admin secret created"
echo "  User:     admin"
echo "  Password: ${GRAFANA_PASS}"
echo ""

# ── HAProxy Basic Auth Secret ─────────────────────────────────────────────────
echo -e "${CYAN}━━━ HAProxy Basic Auth Credentials ━━━${NC}"
echo ""

if [[ -z "${BASIC_AUTH_USER:-}" ]]; then
  read -r -p "Basic auth username [admin]: " BASIC_AUTH_USER
fi
BASIC_AUTH_USER="${BASIC_AUTH_USER:-admin}"

if [[ -z "${BASIC_AUTH_PASS:-}" ]]; then
  read -r -s -p "Basic auth password: " BASIC_AUTH_PASS
  echo ""
fi
BASIC_AUTH_PASS="${BASIC_AUTH_PASS:-admin}"

info "Creating HAProxy basic auth secret..."

HTPASSWD=$(htpasswd -nbm "${BASIC_AUTH_USER}" "${BASIC_AUTH_PASS}")
printf '%s' "${HTPASSWD}" >/tmp/_basic_auth

kubectl delete secret lgtm-basic-auth -n "${MONITORING_NS}" 2>/dev/null || true

kubectl create secret generic lgtm-basic-auth \
  --namespace "${MONITORING_NS}" \
  --from-file=auth=/tmp/_basic_auth \
  --from-literal=username="${BASIC_AUTH_USER}" \
  --from-literal=password="${BASIC_AUTH_PASS}" \
  --dry-run=client -o yaml | kubectl apply -f -
rm -f /tmp/_basic_auth

echo ""
success "HAProxy basic auth secret created"
echo "  User:     ${BASIC_AUTH_USER}"
echo "  Password: ${BASIC_AUTH_PASS}"
echo ""

export BASIC_AUTH_USER BASIC_AUTH_PASS

if [[ -n "${S3_BUCKET:-}" ]]; then
  S3_REGION="${S3_REGION:-us-east-1}"
  configure_s3_buckets "${S3_BUCKET}" "${S3_REGION}"
  print_s3_config
fi

echo ""
success "install_secrets.sh complete"
