#!/usr/bin/env bash
# ==============================================================================
# scripts/install_LGTM.sh
# Deploys Loki, Tempo, Mimir, and Grafana via Helm.
#
# Run standalone:   sudo bash scripts/install_LGTM.sh
# Run via all:      called automatically by install_all.sh
#
# Values applied in order (later overrides earlier):
#   values/lgtm-values.yaml  — base: S3, resources, single-bucket prefixes
#   values/mtls-patch.yaml   — mTLS: cert mounts, TLS listeners, https:// URLs
#
# Deploy order: Loki → Tempo → Mimir → Grafana
# Grafana last ensures datasource DNS names are resolvable at deploy time.
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
require_kubeconfig
require_helm

header "Phase 5 — LGTM Stack  |  Loki · Tempo · Mimir · Grafana"

# Ensure monitoring namespace exists
if ! k0s kubectl get namespace "${MONITORING_NS}" &>/dev/null 2>&1; then
  die "Namespace '${MONITORING_NS}' does not exist. Run install_k0s.sh first."
fi

VALUES_DIR="$(resolve_values_dir)"
BASE="${VALUES_DIR}/lgtm-values.yaml"
MTLS="${VALUES_DIR}/mtls-patch.yaml"

require_file "${BASE}"
require_file "${MTLS}"

# ── S3 bucket validation ────────────────────────────────────────────────────────
info "Validating S3 bucket configuration..."
S3_BUCKET="${S3_BUCKET:-lgtm-observability}"
S3_REGION="${S3_REGION:-us-east-1}"

if command -v aws &>/dev/null; then
  info "Checking S3 bucket '${S3_BUCKET}' exists..."
  if aws s3api head-bucket --bucket "${S3_BUCKET}" 2>/dev/null; then
    success "S3 bucket '${S3_BUCKET}' exists"
  else
    warn "S3 bucket '${S3_BUCKET}' not found or not accessible"
    warn "Create bucket first: aws s3 mb s3://${S3_BUCKET} --region ${S3_REGION}"
    if [[ "${FORCE:-false}" != "true" ]]; then
      die "S3 bucket validation failed. Set FORCE=true to skip."
    fi
  fi
else
  warn "AWS CLI not installed - skipping S3 validation"
  warn "Ensure bucket '${S3_BUCKET}' exists before deploying"
fi

# ── Pre-flight: all mTLS certs must be Ready ──────────────────────────────────
info "Pre-flight: checking mTLS certificates..."
CERTS_OK=true
for cert in loki-tls tempo-tls mimir-gateway-tls mimir-ingester-tls \
  grafana-client-tls grafana-ingress-tls; do
  STATUS=$(k0s kubectl get certificate "${cert}" -n "${MONITORING_NS}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
  if [[ "$STATUS" != "True" ]]; then
    warn "  NOT READY: ${cert} (status: ${STATUS})"
    CERTS_OK=false
  else
    info "  Ready: ${cert}"
  fi
done
[[ "${CERTS_OK}" == "true" ]] ||
  die "One or more mTLS certs not Ready.\n  Fix: sudo bash scripts/install_mTLS.sh\n  Check: kubectl get certificates -n ${MONITORING_NS}"

# ── Pre-flight: Grafana admin secret must exist ───────────────────────────────
k0s kubectl get secret grafana-admin -n "${MONITORING_NS}" &>/dev/null ||
  die "Secret 'grafana-admin' not found.\n  Fix: sudo bash scripts/install_secrets.sh"

success "Pre-flight checks passed"

# ── Helm install helper ───────────────────────────────────────────────────────
_helm_chart_version() {
  case "$1" in
  grafana/loki) echo "${LOKI_CHART_VERSION}" ;;
  grafana/tempo) echo "${TEMPO_CHART_VERSION}" ;;
  grafana/mimir-distributed) echo "${MIMIR_CHART_VERSION}" ;;
  grafana/grafana) echo "${GRAFANA_CHART_VERSION}" ;;
  *) die "Unknown chart: $1" ;;
  esac
}

helm_deploy() {
  local release="$1" chart="$2" timeout="${3:-5m}"
  local version
  version="$(_helm_chart_version "${chart}")"

  # Check if release exists
  if helm list -n "${MONITORING_NS}" -q 2>/dev/null | grep -q "^${release}$"; then
    info "Release '${release}' exists - upgrading..."
    local action="upgrade"
  else
    info "Deploying ${release} (${chart} ${version})..."
    local action="install"
  fi

  helm ${action} "${release}" "${chart}" \
    --namespace "${MONITORING_NS}" \
    --version "${version}" \
    --values "${BASE}" \
    --values "${MTLS}" \
    --wait \
    --timeout "${timeout}" \
    --atomic \
    --cleanup-on-fail
  success "${release} deployed"
}

# ── Deploy in order ───────────────────────────────────────────────────────────
helm_deploy lgtm-loki grafana/loki 5m
helm_deploy lgtm-tempo grafana/tempo 5m
helm_deploy lgtm-mimir grafana/mimir-distributed 10m
helm_deploy lgtm-grafana grafana/grafana 5m

# ── Path-based Ingress for /mimir, /loki, /tempo ──────────────────────────────
info "Creating path-based Ingress resources..."

GRAFANA_DOMAIN="${GRAFANA_DOMAIN:-grafana.example.com}"

k0s kubectl apply -f - <<INGRESSEOF
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana-main
  namespace: ${MONITORING_NS}
  annotations:
    haproxy.org/timeout-connect: "10s"
    haproxy.org/timeout-client: "60s"
    haproxy.org/timeout-server: "60s"
    haproxy.org/rate-limit: "100"
    haproxy.org/ssl-redirect: "true"
    haproxy.org/force-ssl-redirect: "true"
    haproxy.org/body-max-size: "20480"
    haproxy.org/auth-type: "basic"
    haproxy.org/auth-secret: "grafana-basic-auth"
    haproxy.org/backend-config-snippet: |
      http-response set-header X-Frame-Options "SAMEORIGIN"
      http-response set-header X-Content-Type-Options "nosniff"
spec:
  ingressClassName: haproxy
  rules:
    - host: ${GRAFANA_DOMAIN}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: lgtm-grafana
                port:
                  number: 3000
  tls:
    - secretName: grafana-ingress-tls-secret
      hosts:
        - ${GRAFANA_DOMAIN}
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: mimir-api
  namespace: ${MONITORING_NS}
  annotations:
    haproxy.org/timeout-connect: "10s"
    haproxy.org/timeout-client: "60s"
    haproxy.org/timeout-server: "60s"
    haproxy.org/rate-limit: "100"
    haproxy.org/ssl-redirect: "true"
    haproxy.org/force-ssl-redirect: "true"
    haproxy.org/body-max-size: "20480"
    haproxy.org/path-rewrite: "/mimir(.*) /\$1"
spec:
  ingressClassName: haproxy
  rules:
    - http:
        paths:
          - path: /mimir
            pathType: Prefix
            backend:
              service:
                name: lgtm-mimir-gateway
                port:
                  number: 443
  tls:
    - secretName: grafana-ingress-tls-secret
      hosts:
        - ${GRAFANA_DOMAIN}
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: loki-api
  namespace: ${MONITORING_NS}
  annotations:
    haproxy.org/timeout-connect: "10s"
    haproxy.org/timeout-client: "60s"
    haproxy.org/timeout-server: "60s"
    haproxy.org/rate-limit: "100"
    haproxy.org/ssl-redirect: "true"
    haproxy.org/force-ssl-redirect: "true"
    haproxy.org/body-max-size: "20480"
    haproxy.org/path-rewrite: "/loki(.*) /\$1"
spec:
  ingressClassName: haproxy
  rules:
    - http:
        paths:
          - path: /loki
            pathType: Prefix
            backend:
              service:
                name: lgtm-loki
                port:
                  number: 3100
  tls:
    - secretName: grafana-ingress-tls-secret
      hosts:
        - ${GRAFANA_DOMAIN}
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: tempo-api
  namespace: ${MONITORING_NS}
  annotations:
    haproxy.org/timeout-connect: "10s"
    haproxy.org/timeout-client: "60s"
    haproxy.org/timeout-server: "60s"
    haproxy.org/rate-limit: "100"
    haproxy.org/ssl-redirect: "true"
    haproxy.org/force-ssl-redirect: "true"
    haproxy.org/body-max-size: "20480"
    haproxy.org/path-rewrite: "/tempo(.*) /\$1"
spec:
  ingressClassName: haproxy
  rules:
    - http:
        paths:
          - path: /tempo
            pathType: Prefix
            backend:
              service:
                name: lgtm-tempo
                port:
                  number: 3200
  tls:
    - secretName: grafana-ingress-tls-secret
      hosts:
        - ${GRAFANA_DOMAIN}
INGRESSEOF

success "Path-based Ingress resources created"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
info "Pods in ${MONITORING_NS}:"
k0s kubectl get pods -n "${MONITORING_NS}" -o wide

echo ""
info "Helm releases:"
helm list -n "${MONITORING_NS}"

echo ""
success "install_LGTM.sh complete"
GRAFANA_DOMAIN="${GRAFANA_DOMAIN:-grafana.example.com}"
info "Access points:"
info "  Grafana: https://${GRAFANA_DOMAIN}/"
info "  Mimir:    https://${GRAFANA_DOMAIN}/mimir"
info "  Loki:     https://${GRAFANA_DOMAIN}/loki"
info "  Tempo:    https://${GRAFANA_DOMAIN}/tempo"
info "  Basic Auth: admin / (GRAFANA_ADMIN_PASSWORD or auto-generated)"
echo ""
