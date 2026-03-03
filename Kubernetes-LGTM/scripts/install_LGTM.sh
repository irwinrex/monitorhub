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

# Chart repository aliases
LOKI_REPO="grafana"
TEMPO_REPO="grafana"
MIMIR_REPO="grafana"
GRAFANA_REPO="grafana"
ALERTMANAGER_REPO="grafana"

# ── Helpers ────────────────────────────────────────────────────────────────────

# check_version_drift <release> <namespace> <desired-version>
# Returns 0 if release is already at desired chart version (skip), 1 if not (deploy).
check_version_drift() {
  local release="$1"
  local namespace="$2"
  local desired_version="$3"

  local deployed_chart
  deployed_chart=$(helm list -n "${namespace}" \
    --filter "^${release}$" \
    --output json 2>/dev/null |
    grep -o '"chart":"[^"]*"' |
    grep -o '[0-9][^"]*' || true)

  if [[ "${deployed_chart}" == *"${desired_version}"* ]]; then
    return 0
  fi
  return 1
}

# safe_statefulset_upgrade <release> <namespace>
# Orphan-deletes the StatefulSet so Helm can recreate it without touching the PVC.
# Required when volumeClaimTemplates or other immutable fields change.
safe_statefulset_upgrade() {
  local release="$1"
  local namespace="$2"

  if kubectl get statefulset "${release}" -n "${namespace}" &>/dev/null; then
    info "Orphan-deleting StatefulSet '${release}' to allow safe Helm upgrade (PVC preserved)..."
    kubectl delete statefulset "${release}" \
      --namespace "${namespace}" \
      --cascade=orphan
    kubectl wait --for=delete statefulset/"${release}" \
      --namespace "${namespace}" \
      --timeout=60s
    success "StatefulSet '${release}' removed — PVC intact"
  fi
}

# apply_values <template> <output>
apply_values() {
  local template="$1"
  local output="$2"
  envsubst <"${template}" >"${output}"
}

# ── 1. Namespace ──────────────────────────────────────────────────────────────
info "Configuring Namespace '${MONITORING_NS}'..."
kubectl create namespace "${MONITORING_NS}" --dry-run=client -o yaml | kubectl apply -f -

# ── 2. Pre-flight ─────────────────────────────────────────────────────────────
if ! kubectl get secret grafana-admin -n "${MONITORING_NS}" &>/dev/null; then
  die "Secret 'grafana-admin' not found. Run: sudo bash scripts/install_secrets.sh"
fi

# ── 3. S3 Configuration ───────────────────────────────────────────────────────
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

# Generate component-specific bucket names
S3_BUCKET_LOKI="${S3_BUCKET}-loki"
S3_BUCKET_TEMPO="${S3_BUCKET}-tempo"
S3_BUCKET_MIMIR="${S3_BUCKET}-mimir"
S3_BUCKET_GRAFANA="${S3_BUCKET}-grafana"

export S3_BUCKET S3_REGION S3_BUCKET_LOKI S3_BUCKET_TEMPO S3_BUCKET_MIMIR S3_BUCKET_GRAFANA

info "S3 Configuration:"
echo "  Base Bucket:  ${S3_BUCKET}"
echo "  Loki Bucket:  ${S3_BUCKET_LOKI}"
echo "  Tempo Bucket: ${S3_BUCKET_TEMPO}"
echo "  Mimir Bucket: ${S3_BUCKET_MIMIR}"
echo "  Grafana Bucket: ${S3_BUCKET_GRAFANA}"
echo "  Region:       ${S3_REGION}"

VALUES_DIR="$(resolve_values_dir)"

# ── 4. Helm Repos ─────────────────────────────────────────────────────────────
# grafana-community hosts Loki (from 2026-03-16) and Tempo (from 2026-01-30).
helm repo add grafana https://grafana.github.io/helm-charts --force-update
helm repo add grafana-community https://grafana-community.github.io/helm-charts --force-update
helm repo update >/dev/null

info "Helm repos configured"
info "  - ${LOKI_REPO}/loki:${LOKI_CHART_VERSION}"
info "  - ${TEMPO_REPO}/tempo:${TEMPO_CHART_VERSION}"
info "  - ${MIMIR_REPO}/mimir-distributed:${MIMIR_CHART_VERSION}"
info "  - ${GRAFANA_REPO}/grafana:${GRAFANA_CHART_VERSION}"
info "  - ${ALERTMANAGER_REPO}/alertmanager:${ALERTMANAGER_CHART_VERSION}"

# ── 5. Local Path Provisioner ─────────────────────────────────────────────────
info "Installing Local Path Provisioner..."
if ! kubectl get sc local-path &>/dev/null; then
  kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml
  kubectl -n local-path-storage rollout status deployment/local-path-provisioner --timeout=2m
  kubectl patch storageclass local-path \
    -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
  success "Local Path Provisioner installed"
else
  info "Local Path Provisioner already installed"
fi

# ── 6. Helm Deploy ────────────────────────────────────────────────────────────

# Loki
if ! check_version_drift "loki" "${MONITORING_NS}" "${LOKI_CHART_VERSION}"; then
  info "Installing/Upgrading Loki ${LOKI_CHART_VERSION}..."
  apply_values "${VALUES_DIR}/loki-values.yaml" /tmp/loki-values.yaml
  safe_statefulset_upgrade "loki" "${MONITORING_NS}"
  helm upgrade --install loki "${LOKI_REPO}/loki" \
    --namespace "${MONITORING_NS}" \
    --version "${LOKI_CHART_VERSION}" \
    --values /tmp/loki-values.yaml \
    --atomic \
    --timeout 10m
  success "Loki ${LOKI_CHART_VERSION} deployed"
else
  success "Loki ${LOKI_CHART_VERSION} already deployed — skipping"
fi

# Tempo
if ! check_version_drift "tempo" "${MONITORING_NS}" "${TEMPO_CHART_VERSION}"; then
  info "Installing/Upgrading Tempo ${TEMPO_CHART_VERSION}..."
  apply_values "${VALUES_DIR}/tempo-values.yaml" /tmp/tempo-values.yaml
  helm upgrade --install tempo "${TEMPO_REPO}/tempo" \
    --namespace "${MONITORING_NS}" \
    --version "${TEMPO_CHART_VERSION}" \
    --values /tmp/tempo-values.yaml \
    --atomic \
    --timeout 5m
  success "Tempo ${TEMPO_CHART_VERSION} deployed"
else
  success "Tempo ${TEMPO_CHART_VERSION} already deployed — skipping"
fi

# Mimir
if ! check_version_drift "mimir" "${MONITORING_NS}" "${MIMIR_CHART_VERSION}"; then
  info "Installing/Upgrading Mimir ${MIMIR_CHART_VERSION}..."
  apply_values "${VALUES_DIR}/mimir-values.yaml" /tmp/mimir-values.yaml
  helm upgrade --install mimir "${MIMIR_REPO}/mimir-distributed" \
    --namespace "${MONITORING_NS}" \
    --version "${MIMIR_CHART_VERSION}" \
    --values /tmp/mimir-values.yaml \
    --wait --timeout 10m
  success "Mimir ${MIMIR_CHART_VERSION} deployed"
else
  success "Mimir ${MIMIR_CHART_VERSION} already deployed — skipping"
fi

# Grafana
if ! check_version_drift "grafana" "${MONITORING_NS}" "${GRAFANA_CHART_VERSION}"; then
  info "Installing/Upgrading Grafana ${GRAFANA_CHART_VERSION}..."
  helm upgrade --install grafana "${GRAFANA_REPO}/grafana" \
    --namespace "${MONITORING_NS}" \
    --version "${GRAFANA_CHART_VERSION}" \
    --values "${VALUES_DIR}/grafana-values.yaml" \
    --wait --timeout 10m
  success "Grafana ${GRAFANA_CHART_VERSION} deployed"
else
  success "Grafana ${GRAFANA_CHART_VERSION} already deployed — skipping"
fi

# Alertmanager
if ! check_version_drift "alertmanager" "${MONITORING_NS}" "${ALERTMANAGER_CHART_VERSION}"; then
  info "Installing/Upgrading Alertmanager ${ALERTMANAGER_CHART_VERSION}..."
  helm upgrade --install alertmanager "${ALERTMANAGER_REPO}/alertmanager" \
    --namespace "${MONITORING_NS}" \
    --version "${ALERTMANAGER_CHART_VERSION}" \
    --values "${VALUES_DIR}/alertmanager-values.yaml" \
    --wait --timeout 5m
  success "Alertmanager ${ALERTMANAGER_CHART_VERSION} deployed"
else
  success "Alertmanager ${ALERTMANAGER_CHART_VERSION} already deployed — skipping"
fi

# ── 7. Datasources ────────────────────────────────────────────────────────────
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

# ── 8. Ingress ────────────────────────────────────────────────────────────────
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

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
kubectl get pods -n "${MONITORING_NS}" -o wide

echo ""
success "install_LGTM.sh complete"
info "Access: http://<instance-ip>/"
info "Login:  admin / (check secret)"
echo ""
