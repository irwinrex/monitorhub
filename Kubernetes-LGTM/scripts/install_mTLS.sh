#!/usr/bin/env bash
# ==============================================================================
# scripts/install_mTLS.sh
# Installs Linkerd for pod-to-pod mTLS.
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_root
require_kubeconfig
require_helm

if ! command -v openssl &>/dev/null; then
  die "openssl is required."
fi

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

# ── 1. Generate Certificates ─────────────────────────────────────────────────
info "Generating Linkerd identity certificates..."

CERT_DIR=$(mktemp -d)
trap 'rm -rf "$CERT_DIR"' EXIT

# Create extensions file for CA
cat > "${CERT_DIR}/ca.ext" <<EOF
basicConstraints=critical,CA:TRUE
keyUsage=critical,keyCertSign,cRLSign
EOF

# Generate CA (Trust Anchor) - RSA 2048
openssl genrsa -out "${CERT_DIR}/ca.key" 2048
openssl req -x509 -new -nodes -key "${CERT_DIR}/ca.key" -sha256 -days 3650 \
  -out "${CERT_DIR}/ca.crt" \
  -subj "/CN=linkerd-root-ca/O=Linkerd" \
  -extfile "${CERT_DIR}/ca.ext"

# Generate Issuer with CA extension
cat > "${CERT_DIR}/issuer.ext" <<EOF
basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,keyCertSign,cRLSign
extendedKeyUsage=serverAuth,clientAuth
EOF

openssl genrsa -out "${CERT_DIR}/issuer.key" 2048
openssl req -new -key "${CERT_DIR}/issuer.key" -out "${CERT_DIR}/issuer.csr" \
  -subj "/CN=identity.linkerd.cluster.local/O=Linkerd"

openssl x509 -req -in "${CERT_DIR}/issuer.csr" -CA "${CERT_DIR}/ca.crt" \
  -CAkey "${CERT_DIR}/ca.key" -CAcreateserial -out "${CERT_DIR}/issuer.crt" \
  -days 365 -sha256 -extfile "${CERT_DIR}/issuer.ext"

# Get expiry
EXPIRY=$(openssl x509 -enddate -noout -in "${CERT_DIR}/issuer.crt" | cut -d= -f2)
EXPIRY_UTC=$(date -u -d "${EXPIRY}" +"%Y-%m-%dT%H:%M:%SZ")

success "Certificates generated (expires: ${EXPIRY_UTC})"

# ── 2. Install Linkerd ─────────────────────────────────────────────────────────
info "Installing Linkerd ${LINKERD_VERSION}..."

helm repo add linkerd https://helm.linkerd.io/stable --force-update
helm repo update linkerd >/dev/null

helm upgrade --install linkerd-crds linkerd/linkerd-crds \
  --namespace linkerd \
  --wait

helm upgrade --install linkerd-control-plane linkerd/linkerd-control-plane \
  --namespace linkerd \
  --set-file identityTrustAnchorsPEM="${CERT_DIR}/ca.crt" \
  --set-file identity.issuer.tls.crtPEM="${CERT_DIR}/issuer.crt" \
  --set-file identity.issuer.tls.keyPEM="${CERT_DIR}/issuer.key" \
  --set identity.issuer.crtExpiry="${EXPIRY_UTC}" \
  --set identity.issuer.clockSkewAllowance=60s \
  --wait --timeout 5m

# Inject into monitoring namespace
kubectl label namespace "${MONITORING_NS}" linkerd.io/inject=enabled --overwrite 2>/dev/null || true
kubectl label namespace kube-system linkerd.io/is-control-plane=true --overwrite 2>/dev/null || true

info "Waiting for Linkerd..."
sleep 30

success "Linkerd mTLS enabled"

echo ""
success "install_mTLS.sh complete"
echo ""
