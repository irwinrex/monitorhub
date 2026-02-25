#!/usr/bin/env bash
# ==============================================================================
# scripts/install_Postgres.sh
# Installs PostgreSQL 17 for HA (2 instances) using CloudNativePG (CNPG).
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_root
require_kubeconfig
require_helm

# --- Configuration ---
: "${POSTGRES_VERSION:=0.22.1}" # Operator Helm Chart Version
: "${POSTGRES_NS:=postgres}"
: "${POSTGRES_CLUSTER:=monitoring-pg}"
: "${POSTGRES_DB:=grafana}"
: "${POSTGRES_USER:=grafana}"
: "${POSTGRES_PASSWORD:=changeme}"
: "${MONITORING_NS:=monitoring}"

header "Phase X — PostgreSQL 17 for HA (2 Instances)"

# Skip if already installed
if kubectl get cluster "${POSTGRES_CLUSTER}" -n "${POSTGRES_NS}" &>/dev/null; then
  header "PostgreSQL (already installed)"
  success "PostgreSQL cluster already running"
  exit 0
fi

# Install CNPG operator
info "Installing CloudNativePG operator..."
helm repo add cloudnative-pg https://cloudnative-pg.github.io/charts --force-update
helm repo update cloudnative-pg >/dev/null

kubectl create namespace "${POSTGRES_NS}" --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install cloudnative-pg cloudnative-pg/cloudnative-pg \
  --namespace "${POSTGRES_NS}" \
  --version "${POSTGRES_VERSION}" \
  --wait --timeout 5m

# Create PostgreSQL cluster
info "Creating PostgreSQL 17 cluster..."

if [[ "${POSTGRES_PASSWORD}" == "changeme" ]]; then
  POSTGRES_PASSWORD=$(openssl rand -base64 16)
  info "Generated random password"
fi

kubectl apply -f - <<EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: ${POSTGRES_CLUSTER}-superuser
  namespace: ${POSTGRES_NS}
type: Opaque
stringData:
  username: postgres
  password: ${POSTGRES_PASSWORD}
---
apiVersion: v1
kind: Secret
metadata:
  name: ${POSTGRES_CLUSTER}-app-secret
  namespace: ${POSTGRES_NS}
type: Opaque
stringData:
  username: ${POSTGRES_USER}
  password: ${POSTGRES_PASSWORD}
  dbname: ${POSTGRES_DB}
---
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: ${POSTGRES_CLUSTER}
  namespace: ${POSTGRES_NS}
spec:
  instances: 2
  imageName: ghcr.io/cloudnative-pg/postgresql:17.2
  
  primaryUpdateStrategy: switchover
  
  storage:
    size: 10Gi
    storageClass: standard

  superuserSecret:
    name: ${POSTGRES_CLUSTER}-superuser

  bootstrap:
    initdb:
      database: ${POSTGRES_DB}
      owner: ${POSTGRES_USER}
      secret:
        name: ${POSTGRES_CLUSTER}-app-secret

  resources:
    requests:
      cpu: 250m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 256Mi
EOF

# Wait for cluster
info "Waiting for PostgreSQL 17 cluster to become ready..."
kubectl wait --for=condition=Ready cluster/"${POSTGRES_CLUSTER}" -n "${POSTGRES_NS}" --timeout=5m

# Connection info: Use -rw for the primary instance
POSTGRES_HOST="${POSTGRES_CLUSTER}-rw.${POSTGRES_NS}.svc.cluster.local"

# Save connection info for Grafana
kubectl create secret generic postgres-connection \
  --from-literal=host="${POSTGRES_HOST}" \
  --from-literal=port="5432" \
  --from-literal=database="${POSTGRES_DB}" \
  --from-literal=user="${POSTGRES_USER}" \
  --from-literal=password="${POSTGRES_PASSWORD}" \
  -n "${MONITORING_NS}" \
  --dry-run=client -o yaml | kubectl apply -f -

success "PostgreSQL 17 installed and secret created in ${MONITORING_NS}"
echo "  Primary Host: ${POSTGRES_HOST}"
echo "  Instances: 2"
