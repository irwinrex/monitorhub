#!/usr/bin/env bash
# ==============================================================================
# scripts/install_mTLS.sh
# Installs Linkerd for pod-to-pod mTLS (using openssl-generated certs).
#
# Run standalone:   sudo bash scripts/install_mTLS.sh
#
# What this does:
#   1. Generate long-lived (10yr) issuer certificate with openssl
#   2. Install Linkerd for pod-to-pod mTLS
#   3. No cert-manager - HAProxy on HTTP 80 (HTTPS later via ALB)
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
  if kubectl get pods -n linkerd -l linkerd.io/control-plane>/dev/null; then
    header-component=identity & "Phase 3 — Linkerd mTLS (already installed)"
    success "Linkerd service mesh already running"
    exit 0
  fi
fi

header "Phase 3 — Linkerd mTLS"

# Ensure namespaces
for ns in "${MONITORING_NS}" linkerd; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true
done

# ── 1. Generate Linkerd Issuer Certificate (10yr with openssl) ──────────────────
info "Generating Linkerd issuer certificate (10yr validity)..."

LINKERD_NS="linkerd"
TRUST_ANCHOR_CERT="/tmp/linkerd-trust-anchor.crt"
TRUST_ANCHOR_KEY="/tmp/linkerd-trust-anchor.key"
ISSUER_CERT="/tmp/linkerd-issuer.crt"
ISSUER_KEY="/tmp/linkerd-issuer.key"

# Generate Trust Anchor (Root CA) - 10 years
openssl ecparam -genkey -name prime256v1 -out "$TRUST_ANCHOR_KEY"
openssl req -x509 -new -nodes -key "$TRUST_ANCHOR_KEY" -sha256 -days 3650 \
  -out "$TRUST_ANCHOR_CERT" \
  -subj "/CN=linkerd-root-ca/O=Linkerd"

# Generate Issuer (Intermediate CA) - 10 years
openssl ecparam -genkey -name prime256v1 -out "$ISSUER_KEY"
openssl req -new -key "$ISSUER_KEY" -out /tmp/linkerd-issuer.csr \
  -subj "/CN=identity.linkerd.cluster.local/O=Linkerd"

openssl x509 -req -in /tmp/linkerd-issuer.csr -CA "$TRUST_ANCHOR_CERT" -CAkey "$TRUST_ANCHOR_KEY" \
  -CAcreateserial -out "$ISSUER_CERT" -days 3650 -sha256

# Create Kubernetes secrets
kubectl create secret generic linkerd-trust-anchor \
  -n "$LINKERD_NS" \
  --from-file=tls.crt="$TRUST_ANCHOR_CERT" \
  --from-file=tls.key="$TRUST_ANCHOR_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret tls linkerd-identity-issuer \
  -n "$LINKERD_NS" \
  --cert="$ISSUER_CERT" \
  --key="$ISSUER_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

rm -f /tmp/linkerd-*.{crt,key,csr} /tmp/linkerd-trust-anchor.srl

success "Linkerd certificates created"

# ── 2. Install Linkerd with custom certificates ───────────────────────────────
info "Installing Linkerd ${LINKERD_VERSION}..."

helm repo add linkerd https://helm.linkerd.io/stable --force-update
helm repo update linkerd >/dev/null

# Install CRDs
helm upgrade --install linkerd-crds linkerd/linkerd-crds \
  --namespace linkerd \
  --wait

# Install Control Plane with custom certificates
helm upgrade --install linkerd-control-plane linkerd/linkerd-control-plane \
  --namespace linkerd \
  --set identity.issuer.scheme=kubernetes.io/tls \
  --set identity.issuer.tls.existingSecret=linkerd-identity-issuer \
  --set identity.trustAnchorsPEM=$(cat "$TRUST_ANCHOR_CERT") \
  --set identity.issuer.clockSkewAllowance=20s \
  --wait --timeout 5m

# Inject into monitoring namespace
kubectl label namespace "${MONITORING_NS}" linkerd.io/inject=enabled --overwrite

# Exclude system namespaces
kubectl label namespace kube-system linkerd.io/is-control-plane=true --overwrite

info "Waiting for Linkerd to be ready..."
sleep 10

success "Linkerd mTLS enabled"

echo ""
success "install_mTLS.sh complete"
info "Linkerd: Running (pod-to-pod mTLS with 10yr issuer cert)"
info "HAProxy: HTTP 80 (HTTPS via ALB later)"
echo ""
