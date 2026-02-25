#!/usr/bin/env bash
# ==============================================================================
# scripts/install_Postgres.sh
# Installs PostgreSQL for HA using CloudNativePG (CNPG).
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_root
require_kubeconfig
require_helm

: "${POSTGRES_VERSION:=0.22.1}"
: "${POSTGRES_NS:=postgres}"
: "${POSTGRES_CLUSTER:=monitoring-pg}"
: "${POSTGRES_DB:=grafana}"
: "${POSTGRES_USER:=grafana}"
: "${MONITORING_NS:=monitoring}"

header "Phase 3 — PostgreSQL for HA (2 Instances)"

# Skip if already installed
if kubectl get cluster "${POSTGRES_CLUSTER}" -n "${POSTGRES_NS}" &>/dev/null; then
  header "PostgreSQL (already installed)"
  success "PostgreSQL cluster already running"
  exit 0
fi

# Generate password (use base64 for URL-safe characters)
POSTGRES_PASSWORD=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)

# Install CNPG operator
info "Installing CloudNativePG operator..."

helm repo add cloudnative-pg https://cloudnative-pg.github.io/charts --force-update
helm repo update cloudnative-pg >/dev/null

kubectl create namespace "${POSTGRES_NS}" --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install cloudnative-pg cloudnative-pg/cloudnative-pg \
  --namespace "${POSTGRES_NS}" \
  --version "${POSTGRES_VERSION}" \
  --create-namespace \
  --wait --timeout 5m

success "CloudNativePG operator installed"

# Create PostgreSQL cluster
info "Creating PostgreSQL cluster..."

VALUES_FILE="${SCRIPT_DIR}/../values/postgres-values.yaml"

# Replace password placeholder
sed "s|CHANGEME_PASSWORD|${POSTGRES_PASSWORD}|g" "${VALUES_FILE}" | kubectl apply -f -

# Wait for cluster
info "Waiting for PostgreSQL cluster..."
kubectl wait --for=condition=Ready cluster/"${POSTGRES_CLUSTER}" -n "${POSTGRES_NS}" --timeout=5m

# Connection info
POSTGRES_HOST="${POSTGRES_CLUSTER}-rw.${POSTGRES_NS}.svc.cluster.local"

# Save connection info
kubectl create namespace "${MONITORING_NS}" --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic postgres-connection \
  --from-literal=host="${POSTGRES_HOST}" \
  --from-literal=port="5432" \
  --from-literal=database="${POSTGRES_DB}" \
  --from-literal=user="${POSTGRES_USER}" \
  --from-literal=password="${POSTGRES_PASSWORD}" \
  -n "${MONITORING_NS}" \
  --dry-run=client -o yaml | kubectl apply -f -

success "PostgreSQL installed (2 instances)"
echo ""
info "Connection:"
echo "  Host: ${POSTGRES_HOST}"
echo "  Secret: postgres-connection"
echo ""
