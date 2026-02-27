#!/usr/bin/env bash
# ==============================================================================
# install_all.sh
# Root-level orchestrator — runs all phases in order.
#
# Usage:
#   sudo bash install_all.sh
#
# With S3 configuration via flags:
#   sudo bash install_all.sh --bucket-name my-bucket --bucket-region us-east-1
#
# Or with environment variables:
#   S3_BUCKET=my-bucket S3_REGION=us-east-1 sudo -E bash install_all.sh
#
# Non-interactive mode:
#   sudo bash install_all.sh -y
#   sudo bash install_all.sh --yes
#
# Skip completed phases after a partial/failed install:
#   SKIP_K0S=true SKIP_HAPROXY=true sudo bash install_all.sh
#
# Available skip flags:
#   SKIP_K0S=true        skip scripts/install_k0s.sh
#   SKIP_HAPROXY=true    skip scripts/install_HAProxy.sh
#   SKIP_SECRETS=true    skip scripts/install_secrets.sh
#   SKIP_LGTM=true       skip scripts/install_LGTM.sh
#   SKIP_BACKUP=true     skip scripts/backup_all.sh
#
# Project structure expected:
#   install_all.sh          ← this file
#   scripts/
#     lib/common.sh
#     install_k0s.sh
#     install_HAProxy.sh
#     install_secrets.sh
#     install_LGTM.sh
#   values/
#     loki-values.yaml
#     tempo-values.yaml
#     mimir-values.yaml
#     grafana-values.yaml
#     haproxy-values.yaml
#     ingress-values.yaml
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${ROOT_DIR}/scripts"
VALUES_DIR="${ROOT_DIR}/values"

# shellcheck source=scripts/lib/common.sh
source "${SCRIPTS_DIR}/lib/common.sh"

require_root

# ── Parse arguments ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -b|--bucket-name)
      S3_BUCKET="$2"
      shift 2
      ;;
    --bucket-name=*)
      S3_BUCKET="${1#*=}"
      shift
      ;;
    -r|--bucket-region)
      S3_REGION="$2"
      shift 2
      ;;
    --bucket-region=*)
      S3_REGION="${1#*=}"
      shift
      ;;
    -y|--yes)
      YES="true"
      shift
      ;;
    -h|--help)
      echo "Usage: sudo bash install_all.sh [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  -b, --bucket-name NAME     S3 bucket name for backups"
      echo "  -r, --bucket-region REGION S3 region (e.g., us-east-1)"
      echo "  -y, --yes                  Run in non-interactive mode"
      echo "  -h, --help                 Show this help message"
      echo ""
      echo "Examples:"
      echo "  sudo bash install_all.sh"
      echo "  sudo bash install_all.sh --bucket-name my-bucket --bucket-region us-east-1 -y"
      echo "  S3_BUCKET=my-bucket S3_REGION=us-east-1 sudo -E bash install_all.sh -y"
      exit 0
      ;;
    *)
      warn "Unknown option: $1"
      shift
      ;;
  esac
done

# Export for child scripts
export S3_BUCKET="${S3_BUCKET:-}"
export S3_REGION="${S3_REGION:-}"

# ── Skip flags ────────────────────────────────────────────────────────────────────
SKIP_K0S="${SKIP_K0S:-false}"
SKIP_HAPROXY="${SKIP_HAPROXY:-false}"
SKIP_SECRETS="${SKIP_SECRETS:-false}"
SKIP_LGTM="${SKIP_LGTM:-false}"
SKIP_BACKUP="${SKIP_BACKUP:-false}"
YES="${YES:-false}"

# ── Phase runner helpers ──────────────────────────────────────────────────────
_phase_banner() {
  echo ""
  echo -e "${BOLD}${CYAN}┌──────────────────────────────────────────────────────┐${NC}"
  printf "${BOLD}${CYAN}│  %-52s│${NC}\n" "$*"
  echo -e "${BOLD}${CYAN}└──────────────────────────────────────────────────────┘${NC}"
}

_run_phase() {
  local num="$1" label="$2" skip_flag="$3" script="$4"
  if [[ "${skip_flag}" == "true" ]]; then
    echo -e "${YELLOW}  ↷  Phase ${num}: ${label} — SKIPPED${NC}"
    return
  fi
  _phase_banner "Phase ${num}: ${label}"
  local t=$SECONDS
  bash "${script}"
  echo -e "${GREEN}  ✓  Phase ${num} complete in $((SECONDS - t))s${NC}"
}

# ══════════════════════════════════════════════════════════════════════════════
# Pre-flight: verify all required files are present before starting
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  LGTM Full Stack Install                                 ║${NC}"
echo -e "${BOLD}║  k0s · HAProxy · Loki/Tempo/Mimir/Grafana             ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

info "Verifying required files..."
MISSING=false

for script in \
  "${SCRIPTS_DIR}/lib/common.sh" \
  "${SCRIPTS_DIR}/install_k0s.sh" \
  "${SCRIPTS_DIR}/install_HAProxy.sh" \
  "${SCRIPTS_DIR}/install_secrets.sh" \
  "${SCRIPTS_DIR}/install_LGTM.sh" \
  "${SCRIPTS_DIR}/backup_all.sh"; do
  if [[ -f "$script" ]]; then
    info "  found: ${script##"${ROOT_DIR}/"}"
  else
    warn "  MISSING: ${script##"${ROOT_DIR}/"}"
    MISSING=true
  fi
done

for vfile in \
  "${VALUES_DIR}/loki-values.yaml" \
  "${VALUES_DIR}/tempo-values.yaml" \
  "${VALUES_DIR}/mimir-values.yaml" \
  "${VALUES_DIR}/grafana-values.yaml" \
  "${VALUES_DIR}/haproxy-values.yaml" \
  "${VALUES_DIR}/ingress-values.yaml"; do
  if [[ -f "$vfile" ]]; then
    info "  found: ${vfile##"${ROOT_DIR}/"}"
  else
    warn "  MISSING: ${vfile##"${ROOT_DIR}/"}"
    MISSING=true
  fi
done

[[ "${MISSING}" == "false" ]] || die "Missing files detected — ensure the full project is uploaded."
success "All required files present"

# ── Confirm ───────────────────────────────────────────────────────────────────
if [[ "${YES}" != "true" ]]; then
  echo ""
  warn "This will install k0s, HAProxy, and LGTM stack."
  warn "Intended for a FRESH Debian 12 ARM64 instance (t4g.xlarge)."
  echo ""
  read -r -p "  Continue? [y/N] " confirm
  [[ "${confirm,,}" == "y" ]] || {
    info "Aborted."
    exit 0
  }
else
  info "Running in non-interactive mode (YES=true)"
fi

TOTAL_START=$SECONDS

# ══════════════════════════════════════════════════════════════════════════════
# Phases
# ══════════════════════════════════════════════════════════════════════════════
_run_phase 1 "k0s — System prep + Kubernetes + Helm" \
  "${SKIP_K0S}" "${SCRIPTS_DIR}/install_k0s.sh"

_run_phase 2 "HAProxy — Ingress Controller" \
  "${SKIP_HAPROXY}" "${SCRIPTS_DIR}/install_HAProxy.sh"

_run_phase 3 "Secrets — Grafana admin credentials" \
  "${SKIP_SECRETS}" "${SCRIPTS_DIR}/install_secrets.sh"

_run_phase 4 "LGTM — Loki · Tempo · Mimir · Grafana" \
  "${SKIP_LGTM}" "${SCRIPTS_DIR}/install_LGTM.sh"

# ── S3 Backup Configuration (asked after LGTM install) ────────────────────────
if [[ "${SKIP_BACKUP}" != "true" ]]; then
  echo ""
  info "=== S3 Backup Configuration ==="
  echo ""
  
  if [[ -z "${S3_BUCKET:-}" ]]; then
    read -r -p "Enter S3 bucket name for backups: " S3_BUCKET
  else
    info "Using S3 bucket from argument: ${S3_BUCKET}"
  fi
  
  if [[ -z "${S3_BUCKET}" ]]; then
    warn "No S3 bucket provided - backup phase will be skipped"
    SKIP_BACKUP=true
  else
    if [[ -z "${S3_REGION:-}" ]]; then
      read -r -p "Enter S3 region (default: us-east-1): " S3_REGION_INPUT
      S3_REGION="${S3_REGION_INPUT:-us-east-1}"
    else
      info "Using S3 region from argument: ${S3_REGION}"
    fi
    
    read -r -p "Enter S3 prefix (default: lgtm-backup): " S3_PREFIX_INPUT
    S3_PREFIX="${S3_PREFIX_INPUT:-lgtm-backup}"
    
    read -r -p "Local retention days (default: 7): " LOCAL_RETENTION_INPUT
    LOCAL_RETENTION_DAYS="${LOCAL_RETENTION_INPUT:-7}"
    
    echo ""
    info "S3 Backup: s3://${S3_BUCKET}/${S3_PREFIX} (${S3_REGION})"
    info "Local retention: ${LOCAL_RETENTION_DAYS} days"
    echo ""
    
    export S3_BUCKET S3_PREFIX S3_REGION LOCAL_RETENTION_DAYS
  fi
fi

_run_phase 6 "Backup — S3 backup configuration" \
  "${SKIP_BACKUP}" "${SCRIPTS_DIR}/backup_all.sh"

# ══════════════════════════════════════════════════════════════════════════════
# Done
# ══════════════════════════════════════════════════════════════════════════════
TOTAL_MIN=$(((SECONDS - TOTAL_START) / 60))
TOTAL_SEC=$(((SECONDS - TOTAL_START) % 60))

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  All phases complete in ${TOTAL_MIN}m ${TOTAL_SEC}s                              ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "  Nodes:       kubectl get nodes -o wide"
echo "  Pods:        kubectl get pods -n monitoring -o wide"
echo "  Helm:        helm list -n monitoring"
echo "  Certs:       kubectl get certificates -n monitoring"
echo ""
echo "  Grafana:     https://grafana.example.com"
echo "               (DNS A record → this instance's public IP)"
echo ""
echo "  Export root CA for browser trust:"
echo "    kubectl get secret lgtm-root-ca-secret -n monitoring \\"
echo "      -o jsonpath='{.data.ca\\.crt}' | base64 -d > lgtm-root-ca.crt"
echo ""
