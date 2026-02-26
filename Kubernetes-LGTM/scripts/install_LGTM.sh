#!/usr/bin/env bash
# ==============================================================================
# scripts/install_LGTM.sh
# Deploys Loki, Tempo, Mimir, Grafana via Helm.
# Uses separate values files with env substitution.
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_root
require_kubeconfig
require_helm

: "${MONITORING_NS:=monitoring}"
: "${LOKI_CHART_VERSION:=6.53.0}"
: "${TEMPO_CHART_VERSION:=1.61.3}"
: "${MIMIR_CHART_VERSION:=6.0.5}"
: "${GRAFANA_CHART_VERSION:=10.5.15}"

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
echo ""
echo "=== S3 Bucket Configuration ==="
echo ""

if [[ -z "${S3_BUCKET:-}" ]]; then
  read -r -p "S3 bucket name: " S3_BUCKET
fi
S3_BUCKET="${S3_BUCKET:-lgtm-observability}"

if [[ -z "${S3_REGION:-}" ]]; then
  read -r -p "S3 region [default: us-east-1]: " S3_REGION
fi
S3_REGION="${S3_REGION:-us-east-1}"

# Export for envsubst
export S3_BUCKET S3_REGION

info "S3 Configuration:"
echo "  Bucket:    ${S3_BUCKET}"
echo "  Region:    ${S3_REGION}"

VALUES_DIR="$(resolve_values_dir)"

# ── 4. Helper to apply env vars to values file ───────────────────────────────
apply_values() {
  local template="$1"
  local output="$2"
  envsubst < "${template}" > "${output}"
}

# ── 5. Helm Deploy ─────────────────────────────────────────────────────────────
helm repo add grafana https://grafana.github.io/helm-charts --force-update
helm repo update grafana >/dev/null

# Create PV BEFORE Loki installation
info "Creating PV for Loki..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-loki-data
spec:
  capacity:
    storage: 30Gi
  accessModes:
    - ReadWriteOnce
  storageClassName: local-path
  persistentVolumeReclaimPolicy: Retain
  hostPath:
    path: /mnt/loki-data
    type: DirectoryOrCreate
EOF

# Loki
info "Installing Loki..."
apply_values "${VALUES_DIR}/loki-values.yaml" /tmp/loki-values.yaml
helm upgrade --install loki grafana/loki \
  --namespace "${MONITORING_NS}" \
  --version "${LOKI_CHART_VERSION}" \
  --values /tmp/loki-values.yaml \
  --wait --timeout 10m

info "Waiting for Loki PVC to bind..."
for i in $(seq 1 30); do
  PVC_STATUS=$(kubectl get pvc storage-loki-0 -n "${MONITORING_NS}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
  if [[ "$PVC_STATUS" == "Bound" ]]; then
    success "Loki PVC bound"
    break
  fi
  [[ $i -eq 30 ]] && warn "Loki PVC still pending after 30 attempts"
  sleep 2
done

# Tempo
info "Installing Tempo..."
apply_values "${VALUES_DIR}/tempo-values.yaml" /tmp/tempo-values.yaml
helm upgrade --install tempo grafana/tempo \
  --namespace "${MONITORING_NS}" \
  --version "${TEMPO_CHART_VERSION}" \
  --values /tmp/tempo-values.yaml \
  --wait --timeout 10m

# Mimir
info "Installing Mimir..."
apply_values "${VALUES_DIR}/mimir-values.yaml" /tmp/mimir-values.yaml
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

# Add datasources
info "Configuring datasources..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasources
  namespace: ${MONITORING_NS}
data:
  datasources.yaml: |
    apiVersion: 1
    datasources:
      - name: Mimir
        type: prometheus
        url: http://mimir.${MONITORING_NS}.svc.cluster.local:8080/prometheus
        isDefault: true
      - name: Loki
        type: loki
        url: http://loki.${MONITORING_NS}.svc.cluster.local:3100
      - name: Tempo
        type: tempo
        url: http://tempo.${MONITORING_NS}.svc.cluster.local:3200
EOF

# ── 6. Ingress ─────────────────────────────────────────────────────────────
info "Applying Ingress..."

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
kubectl get pods -n "${MONITORING_NS}" -o wide

echo ""
success "install_LGTM.sh complete"
info "Access: http://<instance-ip>/"
info "Login:  admin / (check secret)"
echo ""
