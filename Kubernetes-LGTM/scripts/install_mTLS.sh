#!/usr/bin/env bash
# ==============================================================================
# scripts/install_mTLS.sh
# Installs Linkerd for pod-to-pod mTLS.
# Uses OpenSSL to generate the required identity certificates for Helm.
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_root
require_kubeconfig
require_helm

if ! command -v openssl &>/dev/null; then
  die "openssl is required to generate Linkerd certificates."
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

# ── 1. Generate Linkerd Identity Certificates (Strict X.509v3) ──────────────
info "Generating Linkerd identity certificates..."

CERT_DIR=$(mktemp -d)
trap 'rm -rf "$CERT_DIR"' EXIT

# Create a clean CA Config
cat <<'EOF' >"${CERT_DIR}/ca.cnf"
[ req ]
prompt = no
distinguished_name = req_distinguished_name
x509_extensions = v3_ca

[ req_distinguished_name ]
CN = root.linkerd.cluster.local

[ v3_ca ]
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
EOF

# Create a clean Issuer Config
cat <<'EOF' >"${CERT_DIR}/issuer.cnf"
[ req ]
prompt = no
distinguished_name = req_distinguished_name
req_extensions = v3_intermediate_ca

[ req_distinguished_name ]
CN = identity.linkerd.cluster.local[ v3_intermediate_ca ]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
EOF

# A. Generate the Trust Anchor (Root CA)
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:prime256v1 -out "${CERT_DIR}/ca.key"
openssl req -x509 -new -key "${CERT_DIR}/ca.key" -out "${CERT_DIR}/ca.crt" -days 3650 -config "${CERT_DIR}/ca.cnf"

# B. Generate the Identity Issuer Certificate/Key
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:prime256v1 -out "${CERT_DIR}/issuer.key"
openssl req -new -key "${CERT_DIR}/issuer.key" -out "${CERT_DIR}/issuer.csr" -config "${CERT_DIR}/issuer.cnf"

# C. Sign the Issuer with the Root CA (applying intermediate CA extensions)
openssl x509 -req -in "${CERT_DIR}/issuer.csr" -CA "${CERT_DIR}/ca.crt" -CAkey "${CERT_DIR}/ca.key" -CAcreateserial -out "${CERT_DIR}/issuer.crt" -days 3650 -extfile "${CERT_DIR}/issuer.cnf" -extensions v3_intermediate_ca

# D. Extract Expiry Date (Helm strictly requires this in UTC format)
EXPIRY_RAW=$(openssl x509 -enddate -noout -in "${CERT_DIR}/issuer.crt" | cut -d= -f2)
if date --version &>/dev/null; then
  # GNU date (Linux)
  EXPIRY_FORMATTED=$(date -u -d "${EXPIRY_RAW}" +"%Y-%m-%dT%H:%M:%SZ")
else
  # BSD date (macOS)
  EXPIRY_FORMATTED=$(date -u -j -f "%b %d %T %Y %Z" "${EXPIRY_RAW}" +"%Y-%m-%dT%H:%M:%SZ")
fi

# ── 2. Install Linkerd with Helm ──────────────────────────────────────────────
info "Installing Linkerd ${LINKERD_VERSION}..."

helm repo add linkerd https://helm.linkerd.io/stable --force-update
helm repo update linkerd >/dev/null

# Install CRDs
helm upgrade --install linkerd-crds linkerd/linkerd-crds \
  --namespace linkerd \
  --version "${LINKERD_VERSION#stable-}" \
  --wait

# Install Control Plane
helm upgrade --install linkerd-control-plane linkerd/linkerd-control-plane \
  --namespace linkerd \
  --version "${LINKERD_VERSION#stable-}" \
  --set-file identityTrustAnchorsPEM="${CERT_DIR}/ca.crt" \
  --set-file identity.issuer.tls.crtPEM="${CERT_DIR}/issuer.crt" \
  --set-file identity.issuer.tls.keyPEM="${CERT_DIR}/issuer.key" \
  --set identity.issuer.crtExpiry="${EXPIRY_FORMATTED}" \
  --set identity.issuer.clockSkewAllowance=60s \
  --wait --timeout 5m

# Inject into monitoring namespace
kubectl annotate namespace "${MONITORING_NS}" linkerd.io/inject=enabled --overwrite 2>/dev/null || true
kubectl label namespace "${MONITORING_NS}" linkerd.io/inject=enabled --overwrite 2>/dev/null || true

# Exclude system namespaces
kubectl label namespace kube-system linkerd.io/is-control-plane=true --overwrite 2>/dev/null || true

info "Waiting for Linkerd to be ready..."
sleep 30

success "Linkerd mTLS enabled"

echo ""
success "install_mTLS.sh complete"
info "Linkerd: Running (automatic pod-to-pod mTLS)"
echo ""
