#!/usr/bin/env bash
# ==============================================================================
# scripts/install_LGTM.sh
# Deploys Loki, Tempo, Mimir, Grafana via Helm.
# Uses separate values files for each component.
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
if helm list -n "${MONITORING_NS}" 2>/dev/null | grep -q "^loki "; then
  success "LGTM stack already deployed"
  exit 0
fi

# ── 1. Namespace ─────────────────────────────────────────────────────────────
info "Configuring Namespace '${MONITORING_NS}'..."
kubectl create namespace "${MONITORING_NS}" --dry-run=client -o yaml | kubectl apply -f -

# ── 2. Pre-flight ─────────────────────────────────────────────────────────────
if ! kubectl get secret grafana-admin -n "${MONITORING_NS}" &>/dev/null; then
  die "Secret 'grafana-admin' not found. Run: sudo bash scripts/install_secrets.sh"
fi

# ── 3. S3 Configuration ────────────────────────────────────────────────────────
VALUES_DIR="$(resolve_values_dir)"

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
export LOKI_CHUNKS_BUCKET="${S3_BUCKET}/loki"
export LOKI_RULER_BUCKET="${S3_BUCKET}/loki-ruler"
export LOKI_ADMIN_BUCKET="${S3_BUCKET}/loki-admin"
export TEMPO_BUCKET="${S3_BUCKET}/tempo"
export MIMIR_BLOCKS_BUCKET="${S3_BUCKET}/mimir"
export MIMIR_ALERTMANAGER_BUCKET="${S3_BUCKET}/mimir-alertmanager"
export MIMIR_RULER_BUCKET="${S3_BUCKET}/mimir-ruler"
export S3_REGION

info "S3 Configuration:"
echo "  Bucket:    ${S3_BUCKET}"
echo "  Loki:      ${LOKI_CHUNKS_BUCKET}"
echo "  Tempo:     ${TEMPO_BUCKET}"
echo "  Mimir:     ${MIMIR_BLOCKS_BUCKET}"
echo "  Region:    ${S3_REGION}"

# ── 4. Generate Values from templates ────────────────────────────────────────
generate_values() {
  local template="$1"
  local outfile="$2"
  
  # Read template and replace placeholders with actual values
  sed -e "s|S3_REGION_PLACEHOLDER|${S3_REGION}|g" \
      -e "s|LOKI_BUCKET_PLACEHOLDER|${S3_BUCKET}/loki|g" \
      -e "s|TEMPO_BUCKET_PLACEHOLDER|${S3_BUCKET}/tempo|g" \
      -e "s|MIMIR_BUCKET_PLACEHOLDER|${S3_BUCKET}/mimir|g" \
      "${template}" > "${outfile}"
}

# ── 5. Helm Deploy ─────────────────────────────────────────────────────────────
helm repo add grafana https://grafana.github.io/helm-charts --force-update
helm repo update grafana >/dev/null

# Loki
info "Installing Loki..."
generate_values "${VALUES_DIR}/loki-values.yaml" /tmp/loki-values.yaml
helm upgrade --install loki grafana/loki \
  --namespace "${MONITORING_NS}" \
  --version "${LOKI_CHART_VERSION}" \
  --values /tmp/loki-values.yaml \
  --wait --timeout 10m

# Tempo
info "Installing Tempo..."
generate_values "${VALUES_DIR}/tempo-values.yaml" /tmp/tempo-values.yaml
helm upgrade --install tempo grafana/tempo \
  --namespace "${MONITORING_NS}" \
  --version "${TEMPO_CHART_VERSION}" \
  --values /tmp/tempo-values.yaml \
  --wait --timeout 10m

# Mimir
info "Installing Mimir..."
generate_values "${VALUES_DIR}/mimir-values.yaml" /tmp/mimir-values.yaml
helm upgrade --install mimir grafana/mimir-distributed \
  --namespace "${MONITORING_NS}" \
  --version "${MIMIR_CHART_VERSION}" \
  --values /tmp/mimir-values.yaml \
  --wait --timeout 10m

# Grafana
info "Installing Grafana..."
helm upgrade --install grafana grafana/grafana \
  --namespace "${MONITORING_NS}" \
  --version "${GRAFANA_CHART_VERSION}" \
  --values "${VALUES_DIR}/grafana-values.yaml" \
  --wait --timeout 10m

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
                name: grafana
                port:
                  number: 3000
EOF

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
kubectl get pods -n "${MONITORING_NS}" -o wide | head -n 10

echo ""
success "install_LGTM.sh complete"
info "Access: http://<instance-ip>/"
info "Login:  admin / (check secret)"
echo ""
