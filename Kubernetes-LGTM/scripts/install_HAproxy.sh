#!/usr/bin/env bash
# ==============================================================================
# scripts/install_HAProxy.sh
# Installs HAProxy Kubernetes Ingress Controller into kube-system.
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
require_helm

# Ensure KUBECONFIG is available immediately
if [[ -z "${KUBECONFIG:-}" ]]; then
  if [[ -f "/root/.kube/config" ]]; then
    export KUBECONFIG="/root/.kube/config"
  elif [[ -f "/var/lib/k0s/pki/admin.conf" ]]; then
    export KUBECONFIG="/var/lib/k0s/pki/admin.conf"
  fi
fi

# Set default version
: "${HAPROXY_CHART_VERSION:=1.44.3}"

# Skip if HAProxy already installed and healthy
if helm list -n kube-system 2>/dev/null | grep -q haproxy-ingress; then
  header "Phase 2 — HAProxy (already installed)"
  
  # Check if pods are running
  if kubectl get pods -n kube-system -l app.kubernetes.io/instance=haproxy-ingress 2>/dev/null | grep -q "Running"; then
    success "HAProxy ingress controller is healthy"
    exit 0
  fi
fi

header "Phase 2 — HAProxy Ingress Controller ${HAPROXY_CHART_VERSION}"

# Ensure repo exists before installing
info "Updating Helm repositories..."
helm repo add haproxytech https://haproxytech.github.io/helm-charts --force-update
helm repo update haproxytech >/dev/null

HAPROXY_VALUES="${SCRIPT_DIR}/../values/haproxy-values.yaml"

if [[ -f "${HAPROXY_VALUES}" ]]; then
  info "Deploying HAProxy Ingress..."
  
  # Increased timeout to 10m and added failure debugging
  if ! helm upgrade --install haproxy-ingress haproxytech/kubernetes-ingress \
    --namespace kube-system \
    --version "${HAPROXY_CHART_VERSION}" \
    --wait --timeout 10m \
    --values "${HAPROXY_VALUES}"; then
    
    echo ""
    warn "Helm install failed. Gathering debug info..."
    echo "---------------------------------------------------"
    kubectl get pods -n kube-system -l app.kubernetes.io/instance=haproxy-ingress
    echo "---------------------------------------------------"
    POD_NAME=$(kubectl get pods -n kube-system -l app.kubernetes.io/instance=haproxy-ingress -o jsonpath="{.items[0].metadata.name}" 2>/dev/null || echo "")
    if [[ -n "$POD_NAME" ]]; then
      kubectl describe pod -n kube-system "$POD_NAME"
    fi
    die "HAProxy installation failed. See logs above."
  fi
else
  die "HAProxy values file not found: ${HAPROXY_VALUES}"
fi

wait_rollout kube-system deployment/haproxy-ingress-kubernetes-ingress 120s

echo ""
success "install_HAProxy.sh complete"
info "HAProxy bound to host ports 80/443 — IngressClass 'haproxy' is default"
echo ""
