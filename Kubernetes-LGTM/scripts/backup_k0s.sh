#!/usr/bin/env bash
# ==============================================================================
# scripts/backup_k0s.sh
# Backup and restore for k0s cluster.
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

BACKUP_DIR="/var/backups/k0s"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# ── Backup ───────────────────────────────────────────────────────────────────
backup() {
  require_root
  
  mkdir -p "${BACKUP_DIR}"
  
  local backup_file="${BACKUP_DIR}/k0s-backup-${TIMESTAMP}.tar.gz"
  
  info "Creating backup..."
  
  # Backup etcd data
  tar -czf "${backup_file}" \
    -C / var/lib/k0s/etcd \
    -C / etc/k0s \
    -C / var/lib/k0s/pki 2>/dev/null || true
  
  # Backup kubeconfig
  cp /var/lib/k0s/pki/admin.conf "${BACKUP_DIR}/kubeconfig-${TIMESTAMP}" 2>/dev/null || true
  
  success "Backup: ${backup_file}"
  
  # List backups
  ls -la "${BACKUP_DIR}" | tail -5
}

# ── Restore ──────────────────────────────────────────────────────────────────
restore() {
  require_root
  
  local backup_file="$1"
  
  if [[ -z "${backup_file}" ]]; then
    echo "Usage: $0 restore <backup-file>"
    ls -la "${BACKUP_DIR}"
    exit 1
  fi
  
  if [[ ! -f "${backup_file}" ]]; then
    die "Backup file not found: ${backup_file}"
  fi
  
  info "Stopping k0s..."
  k0s stop || true
  
  info "Restoring from ${backup_file}..."
  tar -xzf "${backup_file}" -C /
  
  info "Starting k0s..."
  k0s start
  
  success "Restore complete"
}

# ── Main ───────────────────────────────────────────────────────────────────
case "${1:-}" in
  backup)
    backup
    ;;
  restore)
    restore "${2:-}"
    ;;
  *)
    echo "Usage: $0 {backup|restore <file>}"
    echo ""
    echo "Commands:"
    echo "  backup          - Create backup of k0s data"
    echo "  restore <file> - Restore from backup"
    ls -la "${BACKUP_DIR}" 2>/dev/null || echo "No backups yet"
    ;;
esac
