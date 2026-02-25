#!/usr/bin/env bash
# ==============================================================================
# scripts/install_mTLS.sh
# Installs Linkerd for pod-to-pod mTLS with automatic certificate management.
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

# ── 1. Generate Certificates ───────────────────────────────────────────────────
info "Generating Linkerd certificates..."

CERT_DIR=$(mktemp -d)
TRUST_ANCHOR_CERT="${CERT_DIR}/ca.crt"
TRUST_ANCHOR_KEY="${CERT_DIR}/ca.key"
ISSUER_CERT="${CERT_DIR}/issuer.crt"
ISSUER_KEY="${CERT_DIR}/issuer.key"

# Generate Trust Anchor (Root CA) - 10 years
openssl ecparam -genkey -name prime256v1 -out "${TRUST_ANCHOR_KEY}"
openssl req -x509 -new -nodes -key "${TRUST_ANCHOR_KEY}" -sha256 -days 3650 \
  -out "${TRUST_ANCHOR_CERT}" \
  -subj "/CN=linkerd-root-ca/O=Linkerd"

# Generate Issuer (Intermediate CA) - 1 year
openssl ecparam -genkey -name prime256v1 -out "${ISSUER_KEY}"
openssl req -new -key "${ISSUER_KEY}" -out "${CERT_DIR}/issuer.csr" \
  -subj "/CN=identity.linkerd.cluster.local/O=Linkerd"

openssl x509 -req -in "${CERT_DIR}/issuer.csr" -CA "${TRUST_ANCHOR_CERT}" -CAkey "${TRUST_ANCHOR_KEY}" \
  -CAcreateserial -out "${ISSUER_CERT}" -days 365 -sha256

success "Certificates generated"

# ── 2. Install Linkerd with certificates ────────────────────────────────────────
info "Installing Linkerd ${LINKERD_VERSION}..."

helm repo add linkerd https://helm.linkerd.io/stable --force-update
helm repo update linkerd >/dev/null

# Install CRDs
helm upgrade --install linkerd-crds linkerd/linkerd-crds \
  --namespace linkerd \
  --wait

# Install Control Plane with certificates
helm upgrade --install linkerd-control-plane linkerd/linkerd-control-plane \
  --namespace linkerd \
  --set-file identityTrustAnchorsPEM="${TRUST_ANCHOR_CERT}" \
  --set-file identity.issuer.tls.crtPEM="${ISSUER_CERT}" \
  --set-file identity.issuer.tls.keyPEM="${ISSUER_KEY}" \
  --set identity.issuer.clockSkewAllowance=60s \
  --wait --timeout 5m

# Cleanup temp files
rm -rf "${CERT_DIR}"

# Inject into monitoring namespace
kubectl label namespace "${MONITORING_NS}" linkerd.io/inject=enabled --overwrite

# Exclude system namespaces
kubectl label namespace kube-system linkerd.io/is-control-plane=true --overwrite 2>/dev/null || true

info "Waiting for Linkerd to be ready..."
sleep 30

success "Linkerd mTLS enabled"

echo ""
success "install_mTLS.sh complete"
info "Linkerd: Running (pod-to-pod mTLS)"
echo ""
