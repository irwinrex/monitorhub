#!/usr/bin/env bash
# ==============================================================================
# scripts/backup_all.sh
# Daily backup script for k0s, PostgreSQL, and LGTM stack
# Uploads to S3 with 90-day retention, keeps 30 days locally
#
# Usage:
#   S3_BUCKET=my-bucket S3_REGION=us-east-1 ./scripts/backup_all.sh
#   Or edit S3_BUCKET below for persistent configuration
#
# Schedule: Daily at 2 AM via cron
#   echo "0 2 * * * S3_BUCKET=my-bucket /root/backup_all.sh" >> /etc/crontab
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/backup-common.sh"

# ══════════════════════════════════════════════════════════════════════════════
# CONFIGURATION - Prompts for S3 bucket, handles rest via environment or defaults
# ══════════════════════════════════════════════════════════════════════════════

# Prompt for S3 bucket (required for backup)
# Skip prompts if already configured via environment (e.g., from install_all.sh)
if [[ -z "${S3_BUCKET:-}" ]]; then
  echo ""
  echo -e "${CYAN}=== S3 Backup Configuration ===${NC}"
  echo ""
  read -p "Enter S3 bucket name for backups: " S3_BUCKET

  if [[ -z "${S3_BUCKET}" ]]; then
    die "S3_BUCKET is required. Backup aborted."
  fi

  read -p "Enter S3 prefix (default: lgtm-backup): " S3_PREFIX_INPUT
  : "${S3_PREFIX:=${S3_PREFIX_INPUT:-lgtm-backup}}"

  read -p "Enter S3 region (default: us-east-1): " S3_REGION_INPUT
  : "${S3_REGION:=${S3_REGION_INPUT:-us-east-1}}"

  read -p "Local retention days (default: 7): " LOCAL_RETENTION_INPUT
  : "${LOCAL_RETENTION_DAYS:=${LOCAL_RETENTION_INPUT:-7}}"
else
  # Use environment variables, set defaults if not provided
  : "${S3_PREFIX:=lgtm-backup}"
  : "${S3_REGION:=us-east-1}"
  : "${LOCAL_RETENTION_DAYS:=7}"
fi

# S3 retention (for display only - you handle expiration manually)
: "${S3_RETENTION_DAYS:=90}"

# Backup directory
: "${BACKUP_DIR:=/var/backups/lgtm}"

# k0s config directory
: "${K0S_CONFIG_DIR:=/var/lib/k0s}"

# Component-specific settings
: "${GRAFANA_URL:=http://grafana.monitoring.svc:3000}"
: "${POSTGRES_HOST:=monitoring-pg-rw.postgres.svc.cluster.local}"
: "${POSTGRES_DB:=grafana}"
: "${POSTGRES_USER:=grafana}"

# ══════════════════════════════════════════════════════════════════════════════

header "LGTM Stack Backup"

# Check prerequisites
if ! check_s3_config; then
  die "S3_BUCKET not configured. Set S3_BUCKET environment variable."
fi

# Create backup directory
mkdir -p "${BACKUP_DIR}"

BACKUP_TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_PATH="${BACKUP_DIR}/${BACKUP_TIMESTAMP}"
mkdir -p "${BACKUP_PATH}"

echo ""
info "Backup started at $(date)"
info "S3 Bucket: s3://${S3_BUCKET}"
info "Local retention: ${LOCAL_RETENTION_DAYS} days"
info "S3 retention: ${S3_RETENTION_DAYS} days"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# 1. Backup k0s Configuration
# ─────────────────────────────────────────────────────────────────────────────
backup_k0s() {
  info "=== Backing up k0s ==="
  
  local k0s_backup_dir="${BACKUP_PATH}/k0s"
  mkdir -p "${k0s_backup_dir}"
  
  # Backup k0s manifests
  if [[ -d "${K0S_CONFIG_DIR}/manifests" ]]; then
    cp -r "${K0S_CONFIG_DIR}/manifests" "${k0s_backup_dir}/"
  fi
  
  # Backup k0s configuration
  if [[ -f "${K0S_CONFIG_DIR}/k0s.yaml" ]]; then
    cp "${K0S_CONFIG_DIR}/k0s.yaml" "${k0s_backup_dir}/"
  fi
  
  # Backup etcd data (critical for cluster state)
  if [[ -d "${K0S_CONFIG_DIR}/pki/etcd" ]]; then
    cp -r "${K0S_CONFIG_DIR}/pki/etcd" "${k0s_backup_dir}/"
  fi
  
  # Backup Helm repos state
  if [[ -f "${HOME}/.config/helm/repositories.yaml" ]]; then
    cp "${HOME}/.config/helm/repositories.yaml" "${k0s_backup_dir}/"
  fi
  
  # Export kubeconfig
  if [[ -f "/var/lib/k0s/pki/admin.conf" ]]; then
    cp "/var/lib/k0s/pki/admin.conf" "${k0s_backup_dir}/admin.conf"
  fi
  
  # Compress
  tar -czf "${BACKUP_DIR}/k0s_${BACKUP_TIMESTAMP}.tar.gz" -C "${BACKUP_PATH}" k0s
  
  # Upload to S3
  backup_to_s3 "${BACKUP_DIR}/k0s_${BACKUP_TIMESTAMP}.tar.gz" "${S3_PREFIX}/k0s/k0s_${BACKUP_TIMESTAMP}.tar.gz"
  
  success "k0s backup complete"
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. Backup PostgreSQL
# ─────────────────────────────────────────────────────────────────────────────
backup_postgres() {
  info "=== Backing up PostgreSQL ==="
  
  local pg_backup_dir="${BACKUP_PATH}/postgres"
  mkdir -p "${pg_backup_dir}"
  
  # Get PostgreSQL password
  POSTGRES_PASSWORD="$(kubectl get secret postgres-connection -n monitoring -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)"
  
  if [[ -z "${POSTGRES_PASSWORD}" ]]; then
    warn "Cannot get PostgreSQL password, skipping database backup"
    return 1
  fi
  
  # Run pg_dump
  PGPASSWORD="${POSTGRES_PASSWORD}" pg_dump \
    -h "${POSTGRES_HOST}" \
    -U "${POSTGRES_USER}" \
    -d "${POSTGRES_DB}" \
    -f "${pg_backup_dir}/grafana.sql" \
    --format=custom \
    --compress=5
  
  # Backup PostgreSQL configs
  kubectl get postgresql -n postgres -o yaml > "${pg_backup_dir}/cluster-config.yaml" 2>/dev/null || true
  
  # Compress
  tar -czf "${BACKUP_DIR}/postgres_${BACKUP_TIMESTAMP}.tar.gz" -C "${BACKUP_PATH}" postgres
  
  # Upload to S3
  backup_to_s3 "${BACKUP_DIR}/postgres_${BACKUP_TIMESTAMP}.tar.gz" "${S3_PREFIX}/postgres/postgres_${BACKUP_TIMESTAMP}.tar.gz"
  
  success "PostgreSQL backup complete"
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. Backup LGTM Stack
# ─────────────────────────────────────────────────────────────────────────────
backup_lgtm() {
  info "=== Backing up LGTM Stack ==="
  
  local lgtm_backup_dir="${BACKUP_PATH}/lgtm"
  mkdir -p "${lgtm_backup_dir}"
  
  # ── Grafana ──
  info "Backing up Grafana..."
  local grafana_dir="${lgtm_backup_dir}/grafana"
  mkdir -p "${grafana_dir}"
  
  # Backup dashboards
  GRAFANA_API_KEY="${GRAFANA_API_KEY:-$(kubectl get secret grafana-api-key -n monitoring -o jsonpath='{.data.key}' 2>/dev/null | base64 -d || echo "")}"
  
  if [[ -n "${GRAFANA_API_KEY}" ]]; then
    curl -s -H "Authorization: Bearer ${GRAFANA_API_KEY}" \
      "${GRAFANA_URL}/api/search?type=dash-db" | jq -r '.[].uid' 2>/dev/null | while read uid; do
        if [[ -n "${uid}" ]]; then
          curl -s -H "Authorization: Bearer ${GRAFANA_API_KEY}" \
            "${GRAFANA_URL}/api/dashboards/uid/${uid}" | jq '.dashboard' > "${grafana_dir}/${uid}.json" 2>/dev/null || true
        fi
      done
  fi
  
  # Backup datasources
  if [[ -n "${GRAFANA_API_KEY}" ]]; then
    curl -s -H "Authorization: Bearer ${GRAFANA_API_KEY}" \
      "${GRAFANA_URL}/api/datasources" | jq '.' > "${grafana_dir}/datasources.json" 2>/dev/null || true
  fi
  
  # Export Grafana config
  kubectl get secret grafana -n monitoring -o yaml > "${grafana_dir}/secret.yaml" 2>/dev/null || true
  kubectl get configmap grafana -n monitoring -o yaml > "${grafana_dir}/configmap.yaml" 2>/dev/null || true
  
  # ── Loki ──
  info "Backing up Loki..."
  local loki_dir="${lgtm_backup_dir}/loki"
  mkdir -p "${loki_dir}"
  
  kubectl get statefulset loki -n monitoring -o yaml > "${loki_dir}/statefulset.yaml" 2>/dev/null || true
  kubectl get configmap loki -n monitoring -o yaml > "${loki_dir}/configmap.yaml" 2>/dev/null || true
  
  # ── Tempo ──
  info "Backing up Tempo..."
  local tempo_dir="${lgtm_backup_dir}/tempo"
  mkdir -p "${tempo_dir}"
  
  kubectl get statefulset tempo -n monitoring -o yaml > "${tempo_dir}/statefulset.yaml" 2>/dev/null || true
  kubectl get configmap tempo -n monitoring -o yaml > "${tempo_dir}/configmap.yaml" 2>/dev/null || true
  
  # ── Mimir ──
  info "Backing up Mimir..."
  local mimir_dir="${lgtm_backup_dir}/mimir"
  mkdir -p "${mimir_dir}"
  
  kubectl get statefulset mimir -n monitoring -o yaml > "${mimir_dir}/statefulset.yaml" 2>/dev/null || true
  kubectl get configmap mimir -n monitoring -o yaml > "${mimir_dir}/configmap.yaml" 2>/dev/null || true
  
  # Backup Helm releases
  helm repo list 2>/dev/null > "${lgtm_backup_dir}/helm-repos.txt" || true
  
  # Compress
  tar -czf "${BACKUP_DIR}/lgtm_${BACKUP_TIMESTAMP}.tar.gz" -C "${BACKUP_PATH}" lgtm
  
  # Upload to S3
  backup_to_s3 "${BACKUP_DIR}/lgtm_${BACKUP_TIMESTAMP}.tar.gz" "${S3_PREFIX}/lgtm/lgtm_${BACKUP_TIMESTAMP}.tar.gz"
  
  success "LGTM backup complete"
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. Cleanup Old Local Backups
# ─────────────────────────────────────────────────────────────────────────────
cleanup_old_backups() {
  info "=== Cleaning up local backups ==="
  
  if [[ "${CLEANUP_LOCAL_AFTER_S3}" == "true" ]]; then
    info "Aggressive cleanup enabled - removing ALL local backups after S3 upload"
    
    # Remove current backup files
    rm -f "${BACKUP_DIR}"/k0s_*.tar.gz 2>/dev/null || true
    rm -f "${BACKUP_DIR}"/postgres_*.tar.gz 2>/dev/null || true
    rm -f "${BACKUP_DIR}"/lgtm_*.tar.gz 2>/dev/null || true
    rm -rf "${BACKUP_PATH}" 2>/dev/null || true
  else
    # Clean up backup directories older than retention period
    find "${BACKUP_DIR}" -maxdepth 1 -type d -name "??????_??????" -mtime +"${LOCAL_RETENTION_DAYS}" -exec rm -rf {} \; 2>/dev/null || true
    
    # Clean up old tar.gz files
    find "${BACKUP_DIR}" -maxdepth 1 -type f -name "*.tar.gz" -mtime +"${LOCAL_RETENTION_DAYS}" -delete 2>/dev/null || true
  fi
  
  success "Local cleanup complete"
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. Cleanup Old Local Backups
# ─────────────────────────────────────────────────────────────────────────────
info "=== S3 Retention Note ==="
echo ""
echo "S3 bucket: s3://${S3_BUCKET}/${S3_PREFIX}"
echo "S3 retention: ${S3_RETENTION_DAYS} days (you manage expiration manually)"
echo ""
echo "IMPORTANT: Configure S3 Lifecycle Policy for ${S3_BUCKET}:"
echo "  - Transition to Glacier/Deep Archive after ${S3_RETENTION_DAYS} days"
echo "  - Or configure bucket expiration"
echo ""
echo "AWS CLI command to set lifecycle:"
echo "  aws s3api put-bucket-lifecycle-configuration \\"
echo "    --bucket ${S3_BUCKET} \\"
echo "    --lifecycle-configuration file://lifecycle.json"
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# RUN BACKUPS
# ══════════════════════════════════════════════════════════════════════════════

# Backup k0s
backup_k0s || true

# Backup PostgreSQL
backup_postgres || true

# Backup LGTM
backup_lgtm || true

# Cleanup
cleanup_old_backups

echo ""
success "=== All backups completed at $(date) ==="
echo ""
info "Local backup location: ${BACKUP_DIR}"
info "S3 location: s3://${S3_BUCKET}/${S3_PREFIX}"
echo ""
