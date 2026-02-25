#!/usr/bin/env bash
# ==============================================================================
# scripts/install_HAProxy.sh
# Installs HAProxy Kubernetes Ingress Controller into kube-system.
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
require_helm

# 1. Setup Environment
# ------------------------------------------------------------------------------
if [[ -z "${KUBECONFIG:-}" ]]; then
  if [[ -f "/root/.kube/config" ]]; then
    export KUBECONFIG="/root/.kube/config"
  elif [[ -f "/var/lib/k0s/pki/admin.conf" ]]; then
    export KUBECONFIG="/var/lib/k0s/pki/admin.conf"
  fi
fi

: "${HAPROXY_CHART_VERSION:=1.44.3}"
HAPROXY_VALUES="${SCRIPT_DIR}/../values/haproxy-values.yaml"

if [[ ! -f "${HAPROXY_VALUES}" ]]; then
  die "Values file not found: ${HAPROXY_VALUES}"
fi

header "Phase 2 — HAProxy Ingress Controller ${HAPROXY_CHART_VERSION}"

# 2. Check & Clean Previous Installs (The Fix)
# ------------------------------------------------------------------------------
# If a previous install failed, Helm upgrade often gets stuck.
# We detect 'failed' status and uninstall it to ensure a clean slate.
if helm list -n kube-system -q | grep -q "^haproxy-ingress$"; then
  STATUS=$(helm status haproxy-ingress -n kube-system -o jsonpath='{.info.status}' 2>/dev/null || echo "unknown")

  if [[ "$STATUS" == "deployed" ]]; then
    # If marked deployed, check if pods are actually running
    if kubectl get pods -n kube-system -l app.kubernetes.io/instance=haproxy-ingress 2>/dev/null | grep -q "Running"; then
      success "HAProxy is already installed and healthy. Skipping."
      exit 0
    else
      warn "HAProxy is deployed but pods are not running. Re-installing..."
    fi
  elif [[ "$STATUS" == "failed" || "$STATUS" == "pending-install" || "$STATUS" == "pending-upgrade" ]]; then
    warn "Found broken Helm release (Status: $STATUS). Uninstalling to fix..."
    helm uninstall haproxy-ingress -n kube-system --wait || true
  fi
fi

# 3. Pre-flight: Check Port 80 availability
# ------------------------------------------------------------------------------
# If Nginx/Apache/Traefik is holding port 80, HAProxy (hostNetwork) will Crash.
if ss -tulpn 2>/dev/null | grep -q ":80 "; then
  if ! ss -tulpn 2>/dev/null | grep ":80 " | grep -q "haproxy"; then
    warn "Port 80 is occupied by another process:"
    ss -tulpn | grep ":80 "
    die "Cannot install HAProxy (hostNetwork) because Port 80 is in use. Stop the conflicting service."
  fi
fi

# 4. Install
# ------------------------------------------------------------------------------
info "Updating Helm repositories..."
helm repo add haproxytech https://haproxytech.github.io/helm-charts --force-update
helm repo update haproxytech >/dev/null

info "Deploying HAProxy Ingress..."

# Use set +e to capture failure and print debug info
set +e
helm upgrade --install haproxy-ingress haproxytech/kubernetes-ingress \
  --namespace kube-system \
  --version "${HAPROXY_CHART_VERSION}" \
  --wait --timeout 10m \
  --values "${HAPROXY_VALUES}"
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -ne 0 ]]; then
  echo ""
  warn "Helm install failed with exit code $EXIT_CODE."
  warn "--- DEBUG INFO ---"

  echo "[Pods Status]"
  kubectl get pods -n kube-system -l app.kubernetes.io/instance=haproxy-ingress

  echo ""
  echo "[Recent Events]"
  kubectl get events -n kube-system --sort-by='.lastTimestamp' | tail -n 10

  echo ""
  echo "[Pod Details]"
  POD_NAME=$(kubectl get pods -n kube-system -l app.kubernetes.io/instance=haproxy-ingress -o jsonpath="{.items[0].metadata.name}" 2>/dev/null || echo "")
  if [[ -n "$POD_NAME" ]]; then
    kubectl describe pod -n kube-system "$POD_NAME"
  fi

  die "Installation failed. See debug info above."
fi

success "install_HAProxy.sh complete"
info "HAProxy bound to host ports 80/443"
echo ""
