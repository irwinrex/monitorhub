#!/usr/bin/env bash
# ==============================================================================
# scripts/install_Postgres.sh
# Installs PostgreSQL for HA using CloudNativePG (CNPG).
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Note: Running kubectl/helm as root is generally an anti-pattern unless
# your specific framework runs entirely as root.
# require_root

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

# Generate password (use 48 bytes to guarantee >= 32 alphanumeric chars after tr)
POSTGRES_PASSWORD=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 32)

# Install CNPG operator
info "Installing CloudNativePG operator..."

helm repo add cloudnative-pg https://cloudnative-pg.github.io/charts --force-update

# Helm < 3.7 does not support passing the repo name. Updating all is safer.
helm repo update >/dev/null

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

# Ensure the manifest file exists before proceeding
if [[ ! -f "${VALUES_FILE}" ]]; then
  echo "Error: ${VALUES_FILE} not found!" >&2
  exit 1
fi

# 1. Replace password placeholder
# 2. Fix 'storageClassName' -> 'storageClass' (CNPG specific schema fix)
MANIFEST=$(sed \
  -e "s|CHANGEME_PASSWORD|${POSTGRES_PASSWORD}|g" \
  -e "s|storageClassName:|storageClass:|g" \
  "${VALUES_FILE}")

# Apply with retry logic: The CNPG mutating/validating webhooks often take a
# few extra seconds to become fully registered after the operator pod is running.
info "Applying cluster manifest..."
MAX_RETRIES=12
RETRY_COUNT=0
until echo "${MANIFEST}" | kubectl apply -f -; do
  RETRY_COUNT=$((RETRY_COUNT + 1))
  if [ "${RETRY_COUNT}" -ge "${MAX_RETRIES}" ]; then
    echo "Error: Failed to apply PostgreSQL cluster manifest after ${MAX_RETRIES} attempts." >&2
    exit 1
  fi
  echo "CNPG Webhook might not be fully ready. Retrying in 5 seconds... (${RETRY_COUNT}/${MAX_RETRIES})"
  sleep 5
done

# Wait for cluster
info "Waiting for PostgreSQL cluster to be Ready..."
kubectl wait --for=condition=Ready cluster/"${POSTGRES_CLUSTER}" -n "${POSTGRES_NS}" --timeout=5m

# Connection info (CNPG automatically creates a `-rw` service for the primary instance)
POSTGRES_HOST="${POSTGRES_CLUSTER}-rw.${POSTGRES_NS}.svc.cluster.local"

# Save connection info
info "Saving PostgreSQL credentials to Secret..."
kubectl create namespace "${MONITORING_NS}" --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic postgres-connection \
  --from-literal=host="${POSTGRES_HOST}" \
  --from-literal=port="5432" \
  --from-literal=database="${POSTGRES_DB}" \
  --from-literal=user="${POSTGRES_USER}" \
  --from-literal=password="${POSTGRES_PASSWORD}" \
  -n "${MONITORING_NS}" \
  --dry-run=client -o yaml | kubectl apply -f -

success "PostgreSQL installed (HA instances applied)"
echo ""
info "Connection:"
echo "  Host: ${POSTGRES_HOST}"
echo "  Secret: postgres-connection (in ${MONITORING_NS} namespace)"
echo ""
