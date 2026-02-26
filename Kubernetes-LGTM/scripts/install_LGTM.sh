#!/usr/bin/env bash
# ==============================================================================
# scripts/install_LGTM.sh
# Deploys Loki, Tempo, Mimir, Grafana via Helm.
# Configured for: Private IP, No Domain, No Cert-Manager, HTTP only.
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_root
require_kubeconfig
require_helm

: "${MONITORING_NS:=monitoring}"
: "${LOKI_CHART_VERSION:=6.32.0}"
: "${TEMPO_CHART_VERSION:=1.22.0}"
: "${MIMIR_CHART_VERSION:=5.7.0}"
: "${GRAFANA_CHART_VERSION:=9.1.0}"

# Skip if already deployed
if helm list -n "${MONITORING_NS}" 2>/dev/null | grep -q lgtm-grafana; then
  success "LGTM stack already deployed"
  exit 0
fi

# ── 1. Namespace & Linkerd ─────────────────────────────────────────────────────
info "Configuring Namespace '${MONITORING_NS}'..."
kubectl create namespace "${MONITORING_NS}" --dry-run=client -o yaml | kubectl apply -f -

# ── 2. Pre-flight ─────────────────────────────────────────────────────────────
if ! kubectl get secret grafana-admin -n "${MONITORING_NS}" &>/dev/null; then
  die "Secret 'grafana-admin' not found. Run: sudo bash scripts/install_secrets.sh"
fi

# ── 3. S3 Configuration ────────────────────────────────────────────────────────
VALUES_DIR="$(resolve_values_dir)"
BASE_VALUES="${VALUES_DIR}/lgtm-values.yaml"

if [[ ! -f "${BASE_VALUES}" ]]; then
  die "Values file not found: ${BASE_VALUES}"
fi

# Prompt for S3 (single bucket with prefixes)
echo ""
echo "=== S3 Bucket Configuration (Single Bucket with Prefixes) ==="
echo ""

if [[ -z "${S3_BUCKET:-}" ]]; then
  read -r -p "S3 bucket name: " S3_BUCKET
fi
S3_BUCKET="${S3_BUCKET:-lgtm-observability}"

if [[ -z "${S3_REGION:-}" ]]; then
  read -r -p "S3 region [default: us-east-1]: " S3_REGION
fi
S3_REGION="${S3_REGION:-us-east-1}"

# Use single bucket with prefixes
LOKI_CHUNKS_BUCKET="${S3_BUCKET}/loki"
LOKI_RULER_BUCKET="${S3_BUCKET}/loki-ruler"
LOKI_ADMIN_BUCKET="${S3_BUCKET}/loki-admin"
TEMPO_BUCKET="${S3_BUCKET}/tempo"
MIMIR_BLOCKS_BUCKET="${S3_BUCKET}/mimir"
MIMIR_ALERTMANAGER_BUCKET="${S3_BUCKET}/mimir-alertmanager"
MIMIR_RULER_BUCKET="${S3_BUCKET}/mimir-ruler"

# Export for helm (values file will use these env vars)
export LOKI_CHUNKS_BUCKET LOKI_RULER_BUCKET LOKI_ADMIN_BUCKET
export TEMPO_BUCKET
export MIMIR_BLOCKS_BUCKET MIMIR_ALERTMANAGER_BUCKET MIMIR_RULER_BUCKET
export S3_REGION

info "S3 Configuration:"
echo "  Bucket:    ${S3_BUCKET}"
echo "  Loki:      ${LOKI_CHUNKS_BUCKET}"
echo "  Tempo:     ${TEMPO_BUCKET}"
echo "  Mimir:     ${MIMIR_BLOCKS_BUCKET}"
echo "  Region:    ${S3_REGION}"

# ── 4. Generate Values ───────────────────────────────────────────────────────
generate_values() {
  local service="$1"
  local outfile="/tmp/values-${service}.yaml"
  
  # Create temp file with env var replacements
  cp "${BASE_VALUES}" /tmp/lgtm-temp.yaml
  
  # Replace ${VAR} placeholders with actual values
  sed -i "s|\${S3_BUCKET}|${S3_BUCKET}|g" /tmp/lgtm-temp.yaml
  sed -i "s|\${S3_REGION}|${S3_REGION}|g" /tmp/lgtm-temp.yaml
  sed -i "s|\${LOKI_CHUNKS_BUCKET}|${LOKI_CHUNKS_BUCKET}|g" /tmp/lgtm-temp.yaml
  sed -i "s|\${LOKI_RULER_BUCKET}|${LOKI_RULER_BUCKET}|g" /tmp/lgtm-temp.yaml
  sed -i "s|\${LOKI_ADMIN_BUCKET}|${LOKI_ADMIN_BUCKET}|g" /tmp/lgtm-temp.yaml
  sed -i "s|\${TEMPO_BUCKET}|${TEMPO_BUCKET}|g" /tmp/lgtm-temp.yaml
  sed -i "s|\${MIMIR_BLOCKS_BUCKET}|${MIMIR_BLOCKS_BUCKET}|g" /tmp/lgtm-temp.yaml
  sed -i "s|\${MIMIR_ALERTMANAGER_BUCKET}|${MIMIR_ALERTMANAGER_BUCKET}|g" /tmp/lgtm-temp.yaml
  sed -i "s|\${MIMIR_RULER_BUCKET}|${MIMIR_RULER_BUCKET}|g" /tmp/lgtm-temp.yaml
  
  # Use the full config
  cp /tmp/lgtm-temp.yaml "${outfile}"
  rm -f /tmp/lgtm-temp.yaml
}

# ── 5. Helm Deploy ─────────────────────────────────────────────────────────────
helm repo add grafana https://grafana.github.io/helm-charts --force-update
helm repo update grafana >/dev/null

helm_deploy() {
  local release="$1"
  local chart="$2"
  local version="$3"
  local service_key="$4"
  local timeout="${5:-10m}"

  generate_values "${service_key}"
  local values_file="/tmp/values-${service_key}.yaml"

  local action="install"
  helm list -n "${MONITORING_NS}" -q | grep -q "^${release}$" && action="upgrade"

  info "${action^}ing ${release}..."
  helm ${action} "${release}" "${chart}" \
    --namespace "${MONITORING_NS}" \
    --version "${version}" \
    --values "${values_file}" \
    --wait \
    --timeout "${timeout}" \
    --atomic

  success "${release} Ready"
  rm -f "${values_file}"
}

# Deploy
helm_deploy lgtm-loki    grafana/loki               "${LOKI_CHART_VERSION}"    "loki"    5m
helm_deploy lgtm-tempo   grafana/tempo              "${TEMPO_CHART_VERSION}"   "tempo"   5m
helm_deploy lgtm-mimir   grafana/mimir-distributed  "${MIMIR_CHART_VERSION}"  "mimir"   10m
helm_deploy lgtm-grafana grafana/grafana            "${GRAFANA_CHART_VERSION}"  "grafana" 5m

# ── 6. Ingress (HTTP) ─────────────────────────────────────────────────────────
info "Applying Ingress Rules..."

kubectl apply -f - <<EOF
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: lgtm-ingress
  namespace: ${MONITORING_NS}
  annotations:
    haproxy.org/timeout-server: "60s"
spec:
  ingressClassName: haproxy
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: lgtm-grafana
                port:
                  number: 3000
          - path: /api/v1/push
            pathType: Prefix
            backend:
              service:
                name: lgtm-mimir-gateway
                port:
                  number: 80
          - path: /loki
            pathType: Prefix
            backend:
              service:
                name: lgtm-loki
                port:
                  number: 3100
          - path: /tempo
            pathType: Prefix
            backend:
              service:
                name: lgtm-tempo
                port:
                  number: 3200
EOF

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
kubectl get pods -n "${MONITORING_NS}" -o wide | head -n 10

echo ""
success "install_LGTM.sh complete"
info "Access: http://<instance-ip>/"
info "Login:  admin / (check secret)"
echo ""
