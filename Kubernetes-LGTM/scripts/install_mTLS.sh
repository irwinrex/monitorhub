#!/usr/bin/env bash
# ==============================================================================
# scripts/install_mTLS.sh
# Installs cert-manager and applies the full LGTM mTLS PKI.
#
# Run standalone:   sudo bash scripts/install_mTLS.sh
# Run via all:      called automatically by install_all.sh
#
# PKI chain:
#   SelfSigned ClusterIssuer  (bootstrap only)
#     └─ lgtm-root-ca         ECDSA P-256, 10yr
#          └─ lgtm-ca-issuer  namespace-scoped
#               ├─ loki-tls-secret            server + client auth
#               ├─ tempo-tls-secret           server + client auth
#               ├─ mimir-gateway-tls-secret   server + client auth
#               ├─ mimir-ingester-tls-secret  server + client auth (isolated)
#               ├─ grafana-client-tls-secret  client auth only
#               └─ grafana-ingress-tls-secret server auth (HAProxy TLS term.)
#
# All leaf certs: ECDSA P-256, 1yr, auto-renew 30d before expiry,
#                 rotationPolicy Always (new key on every renewal).
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
require_kubeconfig
require_helm

# Skip if cert-manager already installed
if kubectl get crd certificates.cert-manager.io &>/dev/null; then
  header "Phase 3 — cert-manager (already installed)"
  
  # Check if root CA exists
  if kubectl get secret lgtm-root-ca-secret -n "${MONITORING_NS}" &>/dev/null; then
    success "mTLS certificates already exist"
    exit 0
  fi
fi

GRAFANA_DOMAIN="${GRAFANA_DOMAIN:-${GRAFANA_DOMAIN}}"

header "Phase 3 — cert-manager ${CERTMANAGER_VERSION} + mTLS PKI"

# Ensure required namespaces exist
for ns in "${MONITORING_NS}" "${CERTMANAGER_NS}"; do
  if ! kubectl get namespace "$ns" &>/dev/null 2>&1; then
    die "Namespace '$ns' does not exist. Run install_k0s.sh first."
  fi
done

# ── 1. cert-manager ───────────────────────────────────────────────────────────
info "Installing cert-manager ${CERTMANAGER_VERSION}..."

VALUES_FILE="${SCRIPT_DIR}/../values/cert-manager-values.yaml"
if [[ -f "${VALUES_FILE}" ]]; then
  helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace "${CERTMANAGER_NS}" \
    --version "${CERTMANAGER_VERSION}" \
    --wait --timeout 5m \
    --values "${VALUES_FILE}"
else
  helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace "${CERTMANAGER_NS}" \
    --version "${CERTMANAGER_VERSION}" \
    --wait --timeout 5m \
    --set crds.enabled=true \
    --set replicaCount=1 \
    --set global.leaderElection.namespace="${CERTMANAGER_NS}" \
    --set resources.requests.cpu=50m \
    --set resources.requests.memory=64Mi \
    --set resources.limits.cpu=200m \
    --set resources.limits.memory=128Mi \
    --set webhook.replicaCount=1 \
    --set webhook.resources.requests.cpu=10m \
    --set webhook.resources.requests.memory=32Mi \
    --set webhook.resources.limits.cpu=100m \
    --set webhook.resources.limits.memory=64Mi \
    --set cainjector.replicaCount=1 \
    --set cainjector.resources.requests.cpu=10m \
    --set cainjector.resources.requests.memory=32Mi \
    --set cainjector.resources.limits.cpu=100m \
    --set cainjector.resources.limits.memory=64Mi
fi

# Webhook needs time after rollout to register its CRD admission hooks.
# Skipping this causes "no kind Certificate is registered" on Debian 12 ARM64.
info "Waiting for cert-manager webhook to stabilise..."
wait_rollout "${CERTMANAGER_NS}" deployment/cert-manager-webhook 120s
wait_rollout "${CERTMANAGER_NS}" deployment/cert-manager 120s
wait_rollout "${CERTMANAGER_NS}" deployment/cert-manager-cainjector 120s
success "cert-manager ready"

# ── 2. mTLS PKI ───────────────────────────────────────────────────────────────
info "Applying mTLS PKI..."

kubectl apply -f - <<PKIEOF
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: lgtm-selfsigned-bootstrap
spec:
  selfSigned: {}

---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: lgtm-root-ca
  namespace: ${MONITORING_NS}
spec:
  isCA: true
  commonName: lgtm-root-ca
  secretName: lgtm-root-ca-secret
  duration:    87600h
  renewBefore: 720h
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name:  lgtm-selfsigned-bootstrap
    kind:  ClusterIssuer
    group: cert-manager.io

---
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: lgtm-ca-issuer
  namespace: ${MONITORING_NS}
spec:
  ca:
    secretName: lgtm-root-ca-secret

---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: loki-tls
  namespace: ${MONITORING_NS}
spec:
  secretName: loki-tls-secret
  duration:    8760h
  renewBefore: 720h
  privateKey:
    algorithm:      ECDSA
    size:           256
    rotationPolicy: Always
  usages: [server auth, client auth]
  dnsNames:
    - lgtm-loki
    - lgtm-loki.${MONITORING_NS}
    - lgtm-loki.${MONITORING_NS}.svc
    - lgtm-loki.${MONITORING_NS}.svc.cluster.local
    - localhost
  issuerRef:
    name:  lgtm-ca-issuer
    kind:  Issuer
    group: cert-manager.io

---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: tempo-tls
  namespace: ${MONITORING_NS}
spec:
  secretName: tempo-tls-secret
  duration:    8760h
  renewBefore: 720h
  privateKey:
    algorithm:      ECDSA
    size:           256
    rotationPolicy: Always
  usages: [server auth, client auth]
  dnsNames:
    - lgtm-tempo
    - lgtm-tempo.${MONITORING_NS}
    - lgtm-tempo.${MONITORING_NS}.svc
    - lgtm-tempo.${MONITORING_NS}.svc.cluster.local
    - localhost
  issuerRef:
    name:  lgtm-ca-issuer
    kind:  Issuer
    group: cert-manager.io

---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: mimir-gateway-tls
  namespace: ${MONITORING_NS}
spec:
  secretName: mimir-gateway-tls-secret
  duration:    8760h
  renewBefore: 720h
  privateKey:
    algorithm:      ECDSA
    size:           256
    rotationPolicy: Always
  usages: [server auth, client auth]
  dnsNames:
    - lgtm-mimir-gateway
    - lgtm-mimir-gateway.${MONITORING_NS}
    - lgtm-mimir-gateway.${MONITORING_NS}.svc
    - lgtm-mimir-gateway.${MONITORING_NS}.svc.cluster.local
    - localhost
  issuerRef:
    name:  lgtm-ca-issuer
    kind:  Issuer
    group: cert-manager.io

---
# Ingester gets its own cert — different SANs, isolated blast radius.
# A compromised gateway cert cannot impersonate the stateful ingester.
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: mimir-ingester-tls
  namespace: ${MONITORING_NS}
spec:
  secretName: mimir-ingester-tls-secret
  duration:    8760h
  renewBefore: 720h
  privateKey:
    algorithm:      ECDSA
    size:           256
    rotationPolicy: Always
  usages: [server auth, client auth]
  dnsNames:
    - lgtm-mimir-ingester
    - lgtm-mimir-ingester.${MONITORING_NS}
    - lgtm-mimir-ingester.${MONITORING_NS}.svc
    - lgtm-mimir-ingester.${MONITORING_NS}.svc.cluster.local
    - localhost
  issuerRef:
    name:  lgtm-ca-issuer
    kind:  Issuer
    group: cert-manager.io

---
# Client-only cert — Grafana presents this when connecting to backends.
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: grafana-client-tls
  namespace: ${MONITORING_NS}
spec:
  secretName: grafana-client-tls-secret
  duration:    8760h
  renewBefore: 720h
  privateKey:
    algorithm:      ECDSA
    size:           256
    rotationPolicy: Always
  usages: [client auth]
  dnsNames:
    - lgtm-grafana
    - lgtm-grafana.${MONITORING_NS}
    - lgtm-grafana.${MONITORING_NS}.svc
    - lgtm-grafana.${MONITORING_NS}.svc.cluster.local
  issuerRef:
    name:  lgtm-ca-issuer
    kind:  Issuer
    group: cert-manager.io

---
# Server cert — HAProxy presents this to browsers for the public domain.
# For Let's Encrypt: replace issuerRef with an ACME ClusterIssuer.
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: grafana-ingress-tls
  namespace: ${MONITORING_NS}
spec:
  secretName: grafana-ingress-tls-secret
  duration:    8760h
  renewBefore: 720h
  privateKey:
    algorithm:      ECDSA
    size:           256
    rotationPolicy: Always
  usages: [server auth]
  dnsNames:
    - ${GRAFANA_DOMAIN}
  issuerRef:
    name:  lgtm-ca-issuer
    kind:  Issuer
    group: cert-manager.io
PKIEOF

# ── 3. Wait for all certificates ──────────────────────────────────────────────
wait_cert_ready lgtm-root-ca "${MONITORING_NS}" 24

for cert in loki-tls tempo-tls mimir-gateway-tls mimir-ingester-tls \
  grafana-client-tls grafana-ingress-tls; do
  wait_cert_ready "${cert}" "${MONITORING_NS}" 24
done

echo ""
success "install_mTLS.sh complete"
info "All certificates Ready — verify: kubectl get certificates -n ${MONITORING_NS}"
echo ""
