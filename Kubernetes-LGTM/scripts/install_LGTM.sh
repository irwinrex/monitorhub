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

header "Phase 5 — LGTM Stack"

# Skip if already deployed
if helm list -n "${MONITORING_NS}" 2>/dev/null | grep -q lgtm-grafana; then
  header "Phase 5 — LGTM Stack (already installed)"
  success "LGTM stack already deployed"
  exit 0
fi

# ── 1. Namespace & Linkerd ─────────────────────────────────────────────────────
info "Configuring Namespace '${MONITORING_NS}'..."
kubectl create namespace "${MONITORING_NS}" --dry-run=client -o yaml | kubectl apply -f -

if kubectl get ns linkerd &>/dev/null; then
  kubectl annotate namespace "${MONITORING_NS}" linkerd.io/inject=enabled --overwrite
  success "Enabled Linkerd mTLS injection"
fi

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

if [[ -z "${S3_BUCKET:-}" ]]; then
  echo ""
  read -r -p "Enter S3 bucket name: " S3_BUCKET
fi
S3_BUCKET="${S3_BUCKET:-lgtm-observability}"

if [[ -z "${S3_REGION:-}" ]]; then
  read -r -p "Enter S3 region [default: us-east-1]: " S3_REGION
fi
S3_REGION="${S3_REGION:-us-east-1}"

info "S3: Bucket='${S3_BUCKET}', Region='${S3_REGION}'"

# ── 4. Generate Values ───────────────────────────────────────────────────────
generate_values() {
  local service="$1"
  local outfile="/tmp/values-${service}.yaml"
  
  python3 -c "
import yaml

service = '${service}'
bucket = '${S3_BUCKET}'
region = '${S3_REGION}'

with open('${BASE_VALUES}', 'r') as f:
    docs = list(yaml.safe_load_all(f))

full_config = {}
for doc in docs:
    if doc:
        full_config.update(doc)

config = full_config.get(service, {})

def update_nested(d, keys, value):
    for key in keys[:-1]:
        d = d.setdefault(key, {})
    d[keys[-1]] = value

if service == 'loki':
    update_nested(config, ['storage', 's3', 'region'], region)
    update_nested(config, ['storage', 'bucketNames', 'chunks'], bucket)
    update_nested(config, ['storage', 'bucketNames', 'ruler'], bucket)
    update_nested(config, ['storage', 'bucketNames', 'admin'], bucket)
elif service == 'tempo':
    update_nested(config, ['storage', 'trace', 's3', 'bucket'], bucket)
    update_nested(config, ['storage', 'trace', 's3', 'region'], region)
elif service == 'mimir':
    update_nested(config, ['storage', 'bucket_name'], bucket)

with open('${outfile}', 'w') as f:
    yaml.dump(config, f)
"
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
