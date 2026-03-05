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

BASIC_AUTH_SECRET="basic-auth"

info "Creating HAProxy basic auth secret in kube-system (HAProxy's namespace)..."

if kubectl get secret "${BASIC_AUTH_SECRET}" -n kube-system &>/dev/null; then
  if [[ "${FORCE_RECREATE}" == "true" ]]; then
    warn "FORCE_RECREATE=true - deleting existing basic-auth secret..."
    kubectl delete secret "${BASIC_AUTH_SECRET}" -n kube-system
  else
    success "HAProxy basic auth secret already exists"
  fi
fi

if ! kubectl get secret "${BASIC_AUTH_SECRET}" -n kube-system &>/dev/null; then
  BASIC_AUTH_USER="${BASIC_AUTH_USER:-admin}"
  BASIC_AUTH_PASS="${BASIC_AUTH_PASS:-$(openssl rand -hex 16)}"

  if command -v htpasswd >/dev/null 2>&1; then
    HTPASSWD=$(htpasswd -nbm "${BASIC_AUTH_USER}" "${BASIC_AUTH_PASS}")
  else
    HTPASSWD=$(openssl passwd -apr1 "${BASIC_AUTH_PASS}")
    HTPASSWD="${BASIC_AUTH_USER}:${HTPASSWD}"
  fi

  kubectl create secret generic "${BASIC_AUTH_SECRET}" \
    --namespace kube-system \
    --from-literal=auth="${HTPASSWD}" \
    --from-literal=username="${BASIC_AUTH_USER}" \
    --from-literal=password="${BASIC_AUTH_PASS}"
fi

success "HAProxy basic auth configured"

HAPROXY_STATS_SECRET="haproxy-stats"

info "Creating HAProxy stats secret..."

if kubectl get secret "${HAPROXY_STATS_SECRET}" -n kube-system &>/dev/null; then
  if [[ "${FORCE_RECREATE}" == "true" ]]; then
    warn "FORCE_RECREATE=true - deleting existing haproxy-stats secret..."
    kubectl delete secret "${HAPROXY_STATS_SECRET}" -n kube-system
  else
    success "HAProxy stats secret already exists"
  fi
fi

if ! kubectl get secret "${HAPROXY_STATS_SECRET}" -n kube-system &>/dev/null; then
  HAPROXY_STATS_USER="${HAPROXY_STATS_USER:-admin}"
  HAPROXY_STATS_PASS="${HAPROXY_STATS_PASS:-admin}"

  if command -v htpasswd >/dev/null 2>&1; then
    STATS_HTPASSWD=$(htpasswd -nbm "${HAPROXY_STATS_USER}" "${HAPROXY_STATS_PASS}")
  else
    STATS_HTPASSWD=$(openssl passwd -apr1 "${HAPROXY_STATS_PASS}")
    STATS_HTPASSWD="${HAPROXY_STATS_USER}:${STATS_HTPASSWD}"
  fi

  kubectl create secret generic "${HAPROXY_STATS_SECRET}" \
    --namespace kube-system \
    --from-literal=auth="${STATS_HTPASSWD}" \
    --from-literal=username="${HAPROXY_STATS_USER}" \
    --from-literal=password="${HAPROXY_STATS_PASS}"
fi

success "HAProxy stats secret configured"
echo ""
