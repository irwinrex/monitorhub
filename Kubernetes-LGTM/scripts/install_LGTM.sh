#!/usr/bin/env bash
# ==============================================================================
# scripts/install_LGTM.sh
# Deploys Loki, Tempo, Prometheus, Grafana via Helm.
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
PROMETHEUS_REPO="prometheus-community"
GRAFANA_REPO="grafana"

# ── Helpers ────────────────────────────────────────────────────────────────────

# check_version_drift <release> <namespace> <desired-version>
# Returns 0 if release is already at desired chart version (skip), 1 if not (deploy).
check_version_drift() {
  local release="$1"
  local namespace="$2"
  local desired_version="$3"

  # Use proper JSON parsing to avoid substring matches (e.g. 6.0.5 matching 6.0.50)
  local deployed_chart
  deployed_chart=$(helm list -n "${namespace}" \
    --filter "^${release}$" \
    --output json 2>/dev/null |
    python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['chart'] if d else '')" 2>/dev/null || true)

  # Extract version suffix after last '-' (e.g. "loki-6.53.0" → "6.53.0")
  local deployed_version="${deployed_chart##*-}"

  if [[ "${deployed_version}" == "${desired_version}" ]]; then
    if kubectl get pods -n "${namespace}" -l "app.kubernetes.io/instance=${release}" 2>/dev/null | grep -q "Running"; then
      return 0
    fi
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
# Runs envsubst — validates substitution worked, aborts if any ${VAR} remain unresolved
apply_values() {
  local template="$1"
  local output="$2"
  envsubst <"${template}" >"${output}"

  # Validate — silent envsubst failures produce broken values that Helm accepts
  # without error but cause runtime crashes
  if grep -qE '\$\{[A-Z_]+\}' "${output}"; then
    die "envsubst failed — unresolved variables in ${output}:
$(grep -E '\$\{[A-Z_]+\}' "${output}")"
  fi
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

# Only prompt if not already set by parent (install_all.sh passes these via env)
if [[ -z "${S3_BUCKET:-}" ]]; then
  read -r -p "S3 bucket name: " S3_BUCKET
  S3_BUCKET="${S3_BUCKET:-lgtm-observability}"
fi

if [[ -z "${S3_REGION:-}" ]]; then
  read -r -p "S3 region [default: us-east-1]: " S3_REGION
  S3_REGION="${S3_REGION:-us-east-1}"
fi

# Configure all derived bucket names via shared helper in common.sh
# This is idempotent — safe to call even when vars are already exported
configure_s3_buckets "${S3_BUCKET}" "${S3_REGION}"

info "S3 Configuration:"
print_s3_config

VALUES_DIR="$(resolve_values_dir)"

# ── 4. Helm Repos ─────────────────────────────────────────────────────────────
# grafana-community hosts Loki (from 2026-03-16) and Tempo (from 2026-01-30).
helm repo add grafana https://grafana.github.io/helm-charts --force-update
helm repo add grafana-community https://prometheus-community.github.io/helm-charts --force-update
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm repo update >/dev/null

info "Helm repos configured"
info "  - ${LOKI_REPO}/loki:${LOKI_CHART_VERSION}"
info "  - ${TEMPO_REPO}/tempo:${TEMPO_CHART_VERSION}"
info "  - ${PROMETHEUS_REPO}/kube-prometheus-stack:${PROMETHEUS_CHART_VERSION}"
info "  - ${GRAFANA_REPO}/grafana:${GRAFANA_CHART_VERSION}"

# ── 5. Helm Deploy ────────────────────────────────────────────────────────────

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

# Prometheus
if ! check_version_drift "prometheus" "${MONITORING_NS}" "${PROMETHEUS_CHART_VERSION}"; then
  info "Installing/Upgrading Prometheus ${PROMETHEUS_CHART_VERSION}..."
  apply_values "${VALUES_DIR}/prometheus-values.yaml" /tmp/prometheus-values.yaml
  helm upgrade --install prometheus "${PROMETHEUS_REPO}/kube-prometheus-stack" \
    --namespace "${MONITORING_NS}" \
    --version "${PROMETHEUS_CHART_VERSION}" \
    --values /tmp/prometheus-values.yaml \
    --wait --timeout 10m
  success "Prometheus ${PROMETHEUS_CHART_VERSION} deployed"
else
  success "Prometheus ${PROMETHEUS_CHART_VERSION} already deployed — skipping"
fi

# Grafana
# Datasources are fully configured in grafana-values.yaml — no separate ConfigMap needed
if ! check_version_drift "grafana" "${MONITORING_NS}" "${GRAFANA_CHART_VERSION}"; then
  info "Installing/Upgrading Grafana ${GRAFANA_CHART_VERSION}..."
  apply_values "${VALUES_DIR}/grafana-values.yaml" /tmp/grafana-values.yaml
  helm upgrade --install grafana "${GRAFANA_REPO}/grafana" \
    --namespace "${MONITORING_NS}" \
    --version "${GRAFANA_CHART_VERSION}" \
    --values /tmp/grafana-values.yaml \
    --wait --timeout 10m
  success "Grafana ${GRAFANA_CHART_VERSION} deployed"
else
  success "Grafana ${GRAFANA_CHART_VERSION} already deployed — skipping"
fi

# ── 7. Ingress ────────────────────────────────────────────────────────────────
# Note: Ingress is now handled by HAProxy's extraBackends in haproxy-values.yaml
# HAProxy is deployed AFTER LGTM in install_all.sh
info "LGTM deployment complete - Ingress will be configured by HAProxy"
info "Access Grafana:     http://<ip>/ (no auth)"
info "Access Prometheus:  http://<ip>/prometheus (basic auth required)"
info "Access Loki:        http://<ip>/loki (basic auth required)"
info "Access Tempo:       http://<ip>/tempo (basic auth required)"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
kubectl get pods -n "${MONITORING_NS}" -o wide

echo ""
success "install_LGTM.sh complete"
info "Access Grafana:     http://<ip>/ (no auth)"
info "Access Prometheus:  http://<ip>/prometheus (basic auth required)"
info "Access Loki:        http://<ip>/loki (basic auth required)"
info "Access Tempo:       http://<ip>/tempo (basic auth required)"
info "Login Grafana:      admin / (check secret)"
echo ""
