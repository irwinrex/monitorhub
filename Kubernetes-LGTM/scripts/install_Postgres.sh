#!/usr/bin/env bash
# ==============================================================================
# scripts/install_Postgres.sh
# Installs PostgreSQL for HA on k0s using CloudNativePG (CNPG).
# - Automatically installs the Rancher Local Path Provisioner for storage.
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# require_root # Not needed for k0s default setup
require_kubeconfig
require_helm

: "${POSTGRES_VERSION:=0.22.1}"
: "${POSTGRES_NS:=postgres}"
: "${POSTGRES_CLUSTER:=monitoring-pg}"
: "${POSTGRES_DB:=grafana}"
: "${POSTGRES_USER:=grafana}"
: "${MONITORING_NS:=monitoring}"

header "Phase 3 — PostgreSQL for HA (2 Instances)"

# --- Add-on: Install Local Path Provisioner, essential for k0s ---
info "Ensuring a default StorageClass exists..."
if ! kubectl get sc local-path &>/dev/null; then
  info "Local Path Provisioner not found. Installing for k0s..."

  # 1. Install the Local Path Provisioner from the official YAML
  kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml

  # 2. Wait for the provisioner deployment to be ready
  info "Waiting for provisioner to become ready..."
  kubectl -n local-path-storage rollout status deployment/local-path-provisioner --timeout=2m

  # 3. Mark its storageclass as the default for the cluster
  info "Marking 'local-path' as the default StorageClass..."
  kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

  success "Local Path Provisioner installed."
else
  info "Local Path Provisioner already installed. Skipping."
fi
# --- End Add-on ---

# Detect the cluster's default StorageClass (will be 'local-path' now)
DEFAULT_SC=$(kubectl get sc -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}')

if [ -z "${DEFAULT_SC}" ]; then
  echo "Error: Could not find any default StorageClass even after installation attempt." >&2
  exit 1
fi
info "Using StorageClass: ${DEFAULT_SC}"

# Skip if postgres cluster is already installed
if kubectl get cluster "${POSTGRES_CLUSTER}" -n "${POSTGRES_NS}" &>/dev/null; then
  header "PostgreSQL (already installed)"
  success "PostgreSQL cluster already running"
  exit 0
fi

# Generate a secure password
POSTGRES_PASSWORD=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 32)

# Install CloudNativePG operator
info "Installing CloudNativePG operator..."
helm repo add cloudnative-pg https://cloudnative-pg.github.io/charts --force-update
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
if [[ ! -f "${VALUES_FILE}" ]]; then
  echo "Error: ${VALUES_FILE} not found!" >&2
  exit 1
fi

# 1. Replace password placeholder
# 2. Replace 'storageClassName: <any>' with 'storageClass: <actual_sc_name>'
MANIFEST=$(sed \
  -e "s|CHANGEME_PASSWORD|${POSTGRES_PASSWORD}|g" \
  -e "s|storageClassName:.*|storageClass: ${DEFAULT_SC}|g" \
  "${VALUES_FILE}")

# Apply the cluster manifest with a retry loop to handle the webhook delay
info "Applying cluster manifest..."
MAX_RETRIES=15
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

# Wait for the PostgreSQL cluster to become ready
info "Waiting for PostgreSQL cluster to be Ready..."
kubectl wait --for=condition=Ready cluster/"${POSTGRES_CLUSTER}" -n "${POSTGRES_NS}" --timeout=5m

# Connection info
POSTGRES_HOST="${POSTGRES_CLUSTER}-rw.${POSTGRES_NS}.svc.cluster.local"

# Save connection info into a secret for other apps to use
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
echo "  Storage Class used: ${DEFAULT_SC}"
echo ""
