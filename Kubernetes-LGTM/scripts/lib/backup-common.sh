#!/usr/bin/env bash
# ==============================================================================
# scripts/lib/backup-common.sh
# Common backup functions for S3-based backups
# ==============================================================================

# S3 Configuration (set via environment or edit here)
: "${S3_BUCKET:="}"
: "${S3_REGION:="us-east-1"}"
: "${S3_PREFIX:="lgtm-backup"}"
: "${LOCAL_RETENTION_DAYS:=30}"
: "${S3_RETENTION_DAYS:=90}"
: "${BACKUP_SCHEDULE:="0 2 * * *"}"  # Daily at 2 AM

check_s3_config() {
  if [[ -z "${S3_BUCKET}" ]]; then
    warn "S3_BUCKET not set - backup to S3 disabled"
    return 1
  fi
  return 0
}

backup_to_s3() {
  local source_path="$1"
  local s3_key="$2"
  
  if ! check_s3_config; then
    warn "Skipping S3 backup - not configured"
    return 1
  fi
  
  info "Uploading to s3://${S3_BUCKET}/${s3_key}"
  
  if command -v aws &>/dev/null; then
    aws s3 sync "${source_path}" "s3://${S3_BUCKET}/${s3_key}" \
      --storage-class STANDARD \
      --region "${S3_REGION}" \
      --sse AES256
  elif command -v mc &>/dev/null; then
    mc mirror "${source_path}" "minio/${S3_BUCKET}/${s3_key}"
  else
    die "Neither aws CLI nor mc (MinIO client) found for S3 backup"
  fi
  
  success "Uploaded to S3: ${s3_key}"
}

restore_from_s3() {
  local s3_key="$1"
  local dest_path="$2"
  
  if ! check_s3_config; then
    die "Cannot restore - S3 not configured"
  fi
  
  info "Restoring from s3://${S3_BUCKET}/${s3_key}"
  
  if command -v aws &>/dev/null; then
    aws s3 sync "s3://${S3_BUCKET}/${s3_key}" "${dest_path}" \
      --region "${S3_REGION}"
  elif command -v mc &>/dev/null; then
    mc mirror "minio/${S3_BUCKET}/${s3_key}" "${dest_path}"
  fi
  
  success "Restored from S3: ${s3_key}"
}

get_backup_timestamp() {
  date +"%Y%m%d_%H%M%S"
}

backup_grafana_dashboards() {
  local backup_dir="/tmp/grafana-backup-$(get_backup_timestamp)"
  local s3_key="${S3_PREFIX}/grafana/dashboards/$(get_backup_timestamp)"
  
  info "Backing up Grafana dashboards..."
  
  mkdir -p "${backup_dir}"
  
  # Export dashboards via API
  GRAFANA_URL="${GRAFANA_URL:-http://grafana.monitoring.svc:3000}"
  GRAFANA_API_KEY="${GRAFANA_API_KEY:-$(kubectl get secret grafana-api-key -n monitoring -o jsonpath='{.data.key}' 2>/dev/null | base64 -d || echo "")}"
  
  if [[ -n "${GRAFANA_API_KEY}" ]]; then
    curl -s -H "Authorization: Bearer ${GRAFANA_API_KEY}" \
      "${GRAFANA_URL}/api/search?type=dash-db" | jq -r '.[].uid' | while read uid; do
        curl -s -H "Authorization: Bearer ${GRAFANA_API_KEY}" \
          "${GRAFANA_URL}/api/dashboards/uid/${uid}" | jq '.dashboard' > "${backup_dir}/${uid}.json"
      done
  fi
  
  if ls "${backup_dir}"/*.json &>/dev/null; then
    backup_to_s3 "${backup_dir}" "${s3_key}"
  fi
  
  rm -rf "${backup_dir}"
}

backup_postgres() {
  local backup_dir="/tmp/postgres-backup-$(get_backup_timestamp)"
  local s3_key="${S3_PREFIX}/postgres/$(get_backup_timestamp).sql"
  
  info "Backing up PostgreSQL..."
  
  mkdir -p "${backup_dir}"
  
  POSTGRES_HOST="${POSTGRES_HOST:-monitoring-pg-rw.postgres.svc.cluster.local}"
  POSTGRES_USER="${POSTGRES_USER:-grafana}"
  POSTGRES_DB="${POSTGRES_DB:-grafana}"
  POSTGRES_PASSWORD="$(kubectl get secret postgres-connection -n monitoring -o jsonpath='{.data.password}' | base64 -d)"
  
  PGPASSWORD="${POSTGRES_PASSWORD}" pg_dump \
    -h "${POSTGRES_HOST}" \
    -U "${POSTGRES_USER}" \
    -d "${POSTGRES_DB}" \
    -f "${backup_dir}/dump.sql" \
    --format=custom \
    --compress=5
  
  backup_to_s3 "${backup_dir}/dump.sql" "${s3_key}"
  
  rm -rf "${backup_dir}"
}

cleanup_old_local_backups() {
  local backup_dir="$1"
  local days="${LOCAL_RETENTION_DAYS:-30}"
  
  info "Cleaning up local backups older than ${days} days..."
  find "${backup_dir}" -type f -mtime +"${days}" -delete 2>/dev/null || true
  find "${backup_dir}" -type d -empty -delete 2>/dev/null || true
}
