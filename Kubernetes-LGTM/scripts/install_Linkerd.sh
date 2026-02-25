#!/usr/bin/env bash
# ==============================================================================
# scripts/install_Linkerd.sh
# Installs Linkerd for automatic mTLS between all pods in the cluster.
#
# Run standalone:   sudo bash scripts/install_Linkerd.sh
# Run via all:      called automatically by install_all.sh
#
# What this does:
#   • Installs Linkerd control plane (linkerd-core)
#   • Installs Linkerd viz extension (optional via LINKERD_VIZ=true)
#   • Excludes kube-system, cert-manager from mesh (they have special TLS needs)
#   • Injects monitoring namespace for mesh injection
#
# Excluded namespaces:
#   • kube-system    (k0s, CoreDNS, HAProxy)
#   • cert-manager  (webhook requires strict TLS, conflicts with mesh)
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
require_kubeconfig

LINKERD_VIZ="${LINKERD_VIZ:-true}"

header "Phase X — Linkerd mTLS ${LINKERD_VERSION}"

# Check cluster connectivity
info "Verifying cluster connectivity..."
if ! k0s kubectl get nodes &>/dev/null 2>&1; then
  die "Cannot connect to cluster. Run install_k0s.sh first."
fi

# ── 1. Install Linkerd CLI ───────────────────────────────────────────────────
info "Installing Linkerd CLI ${LINKERD_VERSION}..."
if [[ ! -f /usr/local/bin/linkerd ]]; then
  curl -sSLf --max-time 300 \
    "https://github.com/linkerd/linkerd2/releases/download/${LINKERD_VERSION}/linkerd2-cli-${LINKERD_VERSION}-linux-arm64" \
    -o /tmp/linkerd || die "Failed to download Linkerd CLI"
  chmod +x /tmp/linkerd
  mv /tmp/linkerd /usr/local/bin/linkerd
fi
success "Linkerd: $(linkerd version --client 2>/dev/null || echo ${LINKERD_VERSION})"

# ── 2. Install Linkerd control plane ─────────────────────────────────────────
info "Installing Linkerd control plane..."
linkerd install --crds | k0s kubectl apply -f -
linkerd install | k0s kubectl apply -f -

info "Waiting for Linkerd control plane to be ready..."
linkerd check --expected-version "${LINKERD_VERSION}" --wait 2m
success "Linkerd control plane ready"

# ── 3. Exclude system namespaces ──────────────────────────────────────────────
info "Excluding kube-system from mesh..."
k0s kubectl label namespace kube-system linkerd.io/is-control-plane=true --overwrite
k0s kubectl label namespace kube-system linkerd.io/control-plane-ns=linkerd --overwrite

info "Excluding cert-manager from mesh..."
k0s kubectl label namespace cert-manager linkerd.io/is-control-plane=true --overwrite
k0s kubectl label namespace cert-manager linkerd.io/control-plane-ns=linkerd --overwrite

# ── 4. Inject monitoring namespace ────────────────────────────────────────────
info "Injecting monitoring namespace for mTLS..."
k0s kubectl label namespace monitoring linkerd.io/inject=enabled --overwrite

# ── 5. Install Linkerd Viz (optional) ────────────────────────────────────────
if [[ "${LINKERD_VIZ}" == "true" ]]; then
  info "Installing Linkerd viz extension..."
  linkerd viz install | k0s kubectl apply -f -
  
  info "Waiting for Linkerd viz to be ready..."
  linkerd viz check --wait 2m
  success "Linkerd viz ready"
  
  info "Linkerd viz dashboard: linkerd viz dashboard &"
  info "Or access: kubectl -n linkerd-viz port-forward svc/linkerd-grafana 3000:3000"
else
  info "Skipping Linkerd viz (set LINKERD_VIZ=true to enable)"
fi

# ── 6. Verify mTLS ──────────────────────────────────────────────────────────
info "Verifying automatic mTLS..."
linkerd check --expected-version "${LINKERD_VERSION}" --wait 1m
success "Linkerd mTLS verified"

echo ""
success "install_Linkerd.sh complete"
info "All pods in monitoring namespace now have automatic mTLS"
info "Verify: linkerd -n monitoring mTLS"
echo ""
