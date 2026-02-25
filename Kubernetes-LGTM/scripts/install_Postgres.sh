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

: "${POSTGRES_VERSION:=1.24.0}"
: "${POSTGRES_NS:=postgres}"
: "${POSTGRES_CLUSTER:=monitoring-pg}"
: "${POSTGRES_DB:=grafana}"
: "${POSTGRES_USER:=grafana}"
: "${POSTGRES_PASSWORD:=changeme}"

header "Phase X — PostgreSQL for HA"

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

success "CloudNativePG operator installed"

# Create PostgreSQL cluster
info "Creating PostgreSQL cluster..."

# Generate password if not provided
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
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: ${POSTGRES_CLUSTER}
  namespace: ${POSTGRES_NS}
spec:
  instances: 2
  primaryUpdateStrategy: unsupervised
  imageName: ghcr.io/cloudnative-pg/postgresql:17.5.0
  
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
      
  # High Availability - 2 replicas
  ha:
    enabled: true
    replicas: 2
    
  # Resources
  resources:
    requests:
      cpu: 250m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 256Mi
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
EOF

# Wait for cluster
info "Waiting for PostgreSQL cluster..."
sleep 30

# Get connection info
POSTGRES_HOST="${POSTGRES_CLUSTER}.${POSTGRES_NS}.svc.cluster.local"

info "PostgreSQL cluster created!"
echo ""
info "Connection info:"
echo "  Host: ${POSTGRES_HOST}"
echo "  Port: 5432"
echo "  Database: ${POSTGRES_DB}"
echo "  User: ${POSTGRES_USER}"
echo "  Password: (check secret: ${POSTGRES_CLUSTER}-app-secret)"
echo ""

# Save connection info for Grafana
kubectl create secret generic postgres-connection \
  --from-literal=host="${POSTGRES_HOST}" \
  --from-literal=port="5432" \
  --from-literal=database="${POSTGRES_DB}" \
  --from-literal=user="${POSTGRES_USER}" \
  --from-literal=password="${POSTGRES_PASSWORD}" \
  -n "${MONITORING_NS}" \
  --dry-run=client -o yaml | kubectl apply -f -

success "PostgreSQL secret created in ${MONITORING_NS}"

echo ""
success "install_Postgres.sh complete"
echo "  PostgreSQL: ${POSTGRES_HOST}:5432/${POSTGRES_DB}"
echo "  HA: 3 replicas"
echo ""
