#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_root
require_kubeconfig

: "${MONITORING_NS:=monitoring}"

if ! kubectl get namespace "${MONITORING_NS}" &>/dev/null 2>&1; then
  die "Namespace '${MONITORING_NS}' does not exist."
fi

FORCE_RECREATE="${FORCE_RECREATE:-false}"
SECRET_NAME="grafana-admin"

if kubectl get secret "${SECRET_NAME}" -n "${MONITORING_NS}" &>/dev/null; then
  if [[ "${FORCE_RECREATE}" == "true" ]]; then
    warn "FORCE_RECREATE=true - deleting existing secret..."
    kubectl delete secret "${SECRET_NAME}" -n "${MONITORING_NS}"
  else
    success "Grafana admin secret already exists"
    GRAFANA_SECRET_EXISTS=true
  fi
fi

if [[ "${GRAFANA_SECRET_EXISTS:-false}" != "true" ]]; then
  if [[ -n "${GRAFANA_ADMIN_PASSWORD:-}" ]]; then
    GRAFANA_PASS="${GRAFANA_ADMIN_PASSWORD}"
  else
    GRAFANA_PASS="$(openssl rand -hex 32)"
  fi
  kubectl create secret generic "${SECRET_NAME}" \
    --namespace "${MONITORING_NS}" \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="${GRAFANA_PASS}"
fi

BASIC_AUTH_SECRET="grafana-basic-auth"

info "Creating HAProxy basic auth secret..."

if kubectl get secret "${BASIC_AUTH_SECRET}" -n "${MONITORING_NS}" &>/dev/null; then
  if [[ "${FORCE_RECREATE}" == "true" ]]; then
    warn "FORCE_RECREATE=true - deleting existing basic-auth secret..."
    kubectl delete secret "${BASIC_AUTH_SECRET}" -n "${MONITORING_NS}"
  else
    success "HAProxy basic auth secret already exists"
  fi
fi

if ! kubectl get secret "${BASIC_AUTH_SECRET}" -n "${MONITORING_NS}" &>/dev/null; then
  BASIC_AUTH_USER="${BASIC_AUTH_USER:-admin}"
  BASIC_AUTH_PASS="${BASIC_AUTH_PASS:-$(openssl rand -hex 16)}"

  if command -v htpasswd >/dev/null 2>&1; then
    HTPASSWD=$(htpasswd -nbm "${BASIC_AUTH_USER}" "${BASIC_AUTH_PASS}")
  else
    HTPASSWD=$(openssl passwd -apr1 "${BASIC_AUTH_PASS}")
    HTPASSWD="${BASIC_AUTH_USER}:${HTPASSWD}"
  fi

  kubectl create secret generic "${BASIC_AUTH_SECRET}" \
    --namespace "${MONITORING_NS}" \
    --from-literal=auth="${HTPASSWD}" \
    --from-literal=username="${BASIC_AUTH_USER}" \
    --from-literal=password="${BASIC_AUTH_PASS}"
fi

success "HAProxy basic auth configured"
echo ""
