#!/usr/bin/env bash
# ==============================================================================
# scripts/install_HAProxy.sh
# Installs HAProxy Kubernetes Ingress Controller into kube-system.
#
# Run standalone:   sudo bash scripts/install_HAProxy.sh
# Run via all:      called automatically by install_all.sh
#
# Design: hostNetwork=true binds HAProxy directly to EC2 host ports 80/443.
# On a single node with no cloud LoadBalancer this is the most reliable
# approach and does NOT conflict with cert-manager.
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
require_kubeconfig
require_helm

header "Phase 2 — HAProxy Ingress Controller ${HAPROXY_CHART_VERSION}"

HAPROXY_VALUES="${SCRIPT_DIR}/../values/haproxy-values.yaml"

if [[ -f "${HAPROXY_VALUES}" ]]; then
  helm upgrade --install haproxy-ingress haproxytech/kubernetes-ingress \
    --namespace kube-system \
    --version "${HAPROXY_CHART_VERSION}" \
    --wait --timeout 3m \
    --values "${HAPROXY_VALUES}"
else
  die "HAProxy values file not found: ${HAPROXY_VALUES}"
fi

wait_rollout kube-system deployment/haproxy-ingress-kubernetes-ingress 120s

echo ""
success "install_HAProxy.sh complete"
info "HAProxy bound to host ports 80/443 — IngressClass 'haproxy' is default"
echo ""
