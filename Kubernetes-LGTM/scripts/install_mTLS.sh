#!/usr/bin/env bash
# ==============================================================================
# scripts/install_mTLS.sh
# Installs Linkerd for pod-to-pod mTLS.
# Uses Linkerd's built-in certificate management (auto-rotation).
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_root
require_kubeconfig
require_helm

: "${LINKERD_VERSION:=stable-2.16.1}"

# Skip if already installed
if kubectl get namespace linkerd &>/dev/null; then
  if kubectl get pods -n linkerd -l linkerd.io/control-plane-component=identity &>/dev/null; then
    header "Phase 3 — Linkerd mTLS (already installed)"
    success "Linkerd service mesh already running"
    exit 0
  fi
fi

header "Phase 3 — Linkerd mTLS"

# Ensure namespaces
for ns in "${MONITORING_NS}" linkerd; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true
done

# ── 1. Install Linkerd with built-in PKI ────────────────────────────────────────
info "Installing Linkerd ${LINKERD_VERSION}..."

helm repo add linkerd https://helm.linkerd.io/stable --force-update
helm repo update linkerd >/dev/null

# Install CRDs
helm upgrade --install linkerd-crds linkerd/linkerd-crds \
  --namespace linkerd \
  --wait

# Install Control Plane with automatic certificate management
helm upgrade --install linkerd-control-plane linkerd/linkerd-control-plane \
  --namespace linkerd \
  --set identity.issuer.clockSkewAllowance=60s \
  --wait --timeout 5m

# Inject into monitoring namespace
kubectl annotate namespace "${MONITORING_NS}" linkerd.io/inject=enabled --overwrite 2>/dev/null || \
kubectl label namespace "${MONITORING_NS}" linkerd.io/inject=enabled --overwrite

# Exclude system namespaces
kubectl label namespace kube-system linkerd.io/is-control-plane=true --overwrite 2>/dev/null || true

info "Waiting for Linkerd to be ready..."
sleep 30

success "Linkerd mTLS enabled"

echo ""
success "install_mTLS.sh complete"
info "Linkerd: Running (automatic pod-to-pod mTLS)"
echo ""
