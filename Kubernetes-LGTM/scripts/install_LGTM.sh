#!/usr/bin/env bash
# ==============================================================================
# scripts/install_LGTM.sh
# Deploys Loki, Tempo, Mimir, and Grafana via Helm.
#
# Run standalone:   sudo bash scripts/install_LGTM.sh
# Run via all:      called automatically by install_all.sh
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_root
require_kubeconfig
require_helm

# Default Chart Versions
: "${LOKI_CHART_VERSION:=6.32.0}"
: "${TEMPO_CHART_VERSION:=1.22.0}"
: "${MIMIR_CHART_VERSION:=5.7.0}"
: "${GRAFANA_CHART_VERSION:=9.1.0}"
: "${MONITORING_NS:=monitoring}"
: "${GRAFANA_DOMAIN:=grafana.example.com}"

header "Phase 5 — LGTM Stack  |  Loki · Tempo · Mimir · Grafana"

# Skip if LGTM already deployed
if helm list -n "${MONITORING_NS}" 2>/dev/null | grep -q lgtm-grafana; then
  header "Phase 5 — LGTM Stack (already installed)"
  success "LGTM stack already deployed"
  exit 0
fi

# ── 1. Namespace & Linkerd Injection ────────────────────────────────────────────
info "Configuring Namespace '${MONITORING_NS}'..."

kubectl create namespace "${MONITORING_NS}" --dry-run=client -o yaml | kubectl apply -f -

if kubectl get ns linkerd &>/dev/null; then
  kubectl annotate namespace "${MONITORING_NS}" linkerd.io/inject=enabled --overwrite
  success "Enabled Linkerd mTLS injection for ${MONITORING_NS}"
else
  warn "Linkerd not found. mTLS will NOT be enabled."
fi

# ── 2. Pre-flight: Grafana Secret ───────────────────────────────────────────────
if ! kubectl get secret grafana-admin -n "${MONITORING_NS}" &>/dev/null; then
  die "Secret 'grafana-admin' not found.\n  Run: sudo bash scripts/install_secrets.sh"
fi

# ── 3. Configuration (S3) ───────────────────────────────────────────────────
VALUES_DIR="${SCRIPT_DIR}/../values"
BASE_VALUES="${VALUES_DIR}/lgtm-values.yaml"

if [[ ! -f "${BASE_VALUES}" ]]; then
  die "Values file not found: ${BASE_VALUES}"
fi

# Interactive S3 Configuration
if [[ -z "${S3_BUCKET:-}" ]]; then
  echo ""
  read -r -p "Enter S3 bucket name [default: lgtm-observability]: " S3_INPUT
  S3_BUCKET="${S3_INPUT:-lgtm-observability}"
fi

if [[ -z "${S3_REGION:-}" ]]; then
  echo ""
  read -r -p "Enter S3 region [default: us-east-1]: " REGION_INPUT
  S3_REGION="${REGION_INPUT:-us-east-1}"
fi

# Update values file
sed -i "s/bucketNames: chunks: .*/bucketNames: chunks: \"${S3_BUCKET}\"/" "${BASE_VALUES}"
sed -i "s/bucket_name: .*/bucket_name: \"${S3_BUCKET}\"/" "${BASE_VALUES}"
sed -i "s/region: .*/region: \"${S3_REGION}\"/" "${BASE_VALUES}"

info "Configuration: Bucket='${S3_BUCKET}', Region='${S3_REGION}'"

# ── 4. Helm Deployment ───────────────────────────────────────────────────────────
helm repo add grafana https://grafana.github.io/helm-charts --force-update
helm repo update grafana >/dev/null

helm_deploy() {
  local release="$1"
  local chart="$2"
  local version="$3"
  local timeout="${4:-10m}"

  if helm list -n "${MONITORING_NS}" -q | grep -q "^${release}$"; then
    info "Upgrading ${release}..."
  else
    info "Installing ${release} (${chart} ${version})..."
  fi

  helm upgrade --install "${release}" "${chart}" \
    --namespace "${MONITORING_NS}" \
    --version "${version}" \
    --values "${BASE_VALUES}" \
    --wait \
    --timeout "${timeout}" \
    --atomic

  success "${release} Ready"
}

# Deploy in order
helm_deploy lgtm-loki    grafana/loki              "${LOKI_CHART_VERSION}"    5m
helm_deploy lgtm-tempo   grafana/tempo             "${TEMPO_CHART_VERSION}"    5m
helm_deploy lgtm-mimir   grafana/mimir-distributed  "${MIMIR_CHART_VERSION}"   10m
helm_deploy lgtm-grafana grafana/grafana            "${GRAFANA_CHART_VERSION}" 5m

# ── 5. Apply Ingress Rules ───────────────────────────────────────────────────────
info "Applying Ingress Rules..."

INGRESS_VALUES="${VALUES_DIR}/ingress-values.yaml"
if [[ -f "${INGRESS_VALUES}" ]]; then
  kubectl apply -f "${INGRESS_VALUES}"
  success "Ingress rules applied"
else
  warn "Ingress values file not found: ${INGRESS_VALUES}"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
info "Status of ${MONITORING_NS}:"
kubectl get pods -n "${MONITORING_NS}" -o wide | head -n 10

echo ""
success "install_LGTM.sh complete"
info "Access points (HTTP):"
info "  Grafana: http://<IP>/"
info "  Mimir:   http://<IP>/mimir"
info "  Loki:    http://<IP>/loki"
info "  Tempo:   http://<IP>/tempo"
info "  Login:   admin / (check secret)"
echo ""
