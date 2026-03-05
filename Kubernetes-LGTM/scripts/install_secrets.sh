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

if ! kubectl get namespace kube-system &>/dev/null 2>&1; then
  die "Namespace 'kube-system' does not exist."
fi

if ! command -v htpasswd >/dev/null 2>&1; then
  warn "htpasswd not found, installing apache2-utils..."
  apt-get update -qq && apt-get install -y apache2-utils -qq >/dev/null 2>&1 || true
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

if ! kubectl get secret "${BASIC_AUTH_SECRET}" -n kube-system &>/dev/null || [[ "${FORCE_RECREATE}" == "true" ]]; then
  BASIC_AUTH_USER="${BASIC_AUTH_USER:-admin}"
  BASIC_AUTH_PASS="${BASIC_AUTH_PASS:-$(openssl rand -hex 16)}"

  if ! command -v htpasswd >/dev/null 2>&1; then
    die "htpasswd is required but not installed. Install apache2-utils manually."
  fi

  HTPASSWD=$(htpasswd -nbm "${BASIC_AUTH_USER}" "${BASIC_AUTH_PASS}")

  kubectl create secret generic "${BASIC_AUTH_SECRET}" \
    --namespace kube-system \
    --from-literal=auth="${HTPASSWD}" \
    --from-literal=username="${BASIC_AUTH_USER}" \
    --from-literal=password="${BASIC_AUTH_PASS}"

  info "Verifying secret..."
  VERIFIED=$(kubectl get secret "${BASIC_AUTH_SECRET}" -n kube-system -o jsonpath='{.data.auth}' | base64 -d)
  if [[ -n "$VERIFIED" ]]; then
    success "Basic auth secret verified"
  fi

  info "Testing basic auth with HAProxy..."
  NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "")
  if [[ -n "$NODE_IP" ]]; then
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -u "${BASIC_AUTH_USER}:${BASIC_AUTH_PASS}" "http://${NODE_IP}/metrics" 2>/dev/null || echo "000")
    if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "401" ]]; then
      success "Basic auth test completed (HTTP ${HTTP_CODE})"
    else
      warn "Basic auth test returned HTTP ${HTTP_CODE}"
    fi
  else
    warn "Could not determine node IP for curl test"
  fi
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

if ! kubectl get secret "${HAPROXY_STATS_SECRET}" -n kube-system &>/dev/null || [[ "${FORCE_RECREATE}" == "true" ]]; then
  HAPROXY_STATS_USER="${HAPROXY_STATS_USER:-admin}"
  HAPROXY_STATS_PASS="${HAPROXY_STATS_PASS:-admin}"

  if ! command -v htpasswd >/dev/null 2>&1; then
    die "htpasswd is required but not installed. Install apache2-utils manually."
  fi

  STATS_HTPASSWD=$(htpasswd -nbm "${HAPROXY_STATS_USER}" "${HAPROXY_STATS_PASS}")

  kubectl create secret generic "${HAPROXY_STATS_SECRET}" \
    --namespace kube-system \
    --from-literal=auth="${STATS_HTPASSWD}" \
    --from-literal=username="${HAPROXY_STATS_USER}" \
    --from-literal=password="${HAPROXY_STATS_PASS}"
fi

success "HAProxy stats secret configured"
echo ""
