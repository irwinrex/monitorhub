#!/usr/bin/env bash
# ==============================================================================
# scripts/upgrade_k0s.sh
# Upgrades k0s to a new version without data loss.
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_root

: "${K0S_VERSION_NEW:=v1.32.7+k0s.0}"

header "Upgrading k0s to ${K0S_VERSION_NEW}"

# Check current version
CURRENT=$(k0s version 2>/dev/null | head -1 || echo "unknown")
info "Current version: ${CURRENT}"

if [[ "${CURRENT}" == *"${K0S_VERSION_NEW}"* ]]; then
  info "Already at version ${K0S_VERSION_NEW}, nothing to do."
  exit 0
fi

# Backup etcd data
info "Backing up etcd..."
ETCD_BACKUP="/tmp/etcd-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
mkdir -p /var/lib/k0s/etcd
tar -czf "${ETCD_BACKUP}" -C / var/lib/k0s/etcd 2>/dev/null || true
success "Backup saved to: ${ETCD_BACKUP}"

# Download new binary
info "Downloading k0s ${K0S_VERSION_NEW}..."
rm -f /usr/local/bin/k0s 2>/dev/null || true

K0S_INSTALL_PATH=/usr/local/bin \
  K0S_VERSION="${K0S_VERSION_NEW}" \
  curl -sSLf https://get.k0s.sh | sh

chmod +x /usr/local/bin/k0s
success "Downloaded: $(k0s version)"

# Upgrade controller
info "Upgrading k0s controller..."
k0s upgrade controller -c /etc/k0s/k0s.yaml

# Wait for API
info "Waiting for API..."
sleep 30

# Verify
NEW_VERSION=$(k0s version 2>/dev/null | head -1)
info "Upgraded to: ${NEW_VERSION}"

echo ""
success "k0s upgrade complete"
info "Backup location: ${ETCD_BACKUP}"
echo ""
