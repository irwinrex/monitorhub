#!/usr/bin/env bash
# ==============================================================================
# scripts/install_HAproxy.sh
# Installs HAproxy Kubernetes Ingress Controller into kube-system.
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
INGRESS_YAML="${SCRIPT_DIR}/../values/ingress.yaml"

if [[ ! -f "${HAPROXY_VALUES}" ]]; then
  die "Values file not found: ${HAPROXY_VALUES}"
fi

if [[ ! -f "${INGRESS_YAML}" ]]; then
  die "Ingress file not found: ${INGRESS_YAML}"
fi

# 2. Clean Previous Failed Installs (if any)
# ------------------------------------------------------------------------------
# If a previous install failed, Helm upgrade gets stuck.
# Only uninstall if the release is in a broken state.

STATUS=$(helm status haproxy-ingress -n kube-system -o jsonpath='{.info.status}' 2>/dev/null || echo "not-found")

if [[ "$STATUS" == "failed" || "$STATUS" == "pending-install" || "$STATUS" == "pending-upgrade" || "$STATUS" == "pending-rollback" ]]; then
  warn "Found broken Helm release (status: $STATUS). Uninstalling..."
  helm uninstall haproxy-ingress -n kube-system --wait || true
fi

# 3. Pre-flight: Check Port 80 availability on ALL schedulable nodes
# ------------------------------------------------------------------------------
# HAProxy uses hostNetwork, so it binds to the node it lands on — not necessarily
# the host running this script.

info "Checking port 80 availability on schedulable nodes..."

NODES=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

PORT_CONFLICT=0
for NODE in $NODES; do
  if ss -tulpn 2>/dev/null | grep -qE ':(80)\s'; then
    if ! ss -tulpn 2>/dev/null | grep -E ':(80)\s' | grep -qi "haproxy"; then
      warn "Port 80 is in use on this host (node: $(hostname)):"
      ss -tulpn | grep -E ':(80)\s' || true
      PORT_CONFLICT=1
    fi
  fi
  if ss -tulpn 2>/dev/null | grep -qE ':8080\s'; then
    warn "Port 8080 is in use — this may be a previous HAProxy install that failed"
    ss -tulpn | grep -E ':8080\s' || true
  fi
done

if [[ $PORT_CONFLICT -eq 1 ]]; then
  die "Port 80 conflict detected. Stop the conflicting service before installing HAProxy (hostNetwork mode)."
fi

# 4. Install / Upgrade
# ------------------------------------------------------------------------------
# Always run helm upgrade --install to apply any YAML changes
info "Updating Helm repositories..."
helm repo add haproxytech https://haproxytech.github.io/helm-charts --force-update
helm repo update haproxytech >/dev/null

info "Deploying HAProxy Ingress (chart version ${HAPROXY_CHART_VERSION})..."

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
  warn "Helm install failed (exit code: $EXIT_CODE)."
  warn "--- DEBUG INFO ---"

  echo "[Pod Status]"
  kubectl get pods -n kube-system -l app.kubernetes.io/instance=haproxy-ingress || true

  echo ""
  echo "[Recent Events]"
  kubectl get events -n kube-system --sort-by='.lastTimestamp' 2>/dev/null | tail -n 15 || true

  echo ""
  echo "[Pod Details]"
  POD_NAME=$(kubectl get pods -n kube-system \
    -l app.kubernetes.io/instance=haproxy-ingress \
    -o jsonpath="{.items[0].metadata.name}" 2>/dev/null || echo "")
  if [[ -n "$POD_NAME" ]]; then
    kubectl describe pod -n kube-system "$POD_NAME" || true
    echo ""
    echo "[Pod Logs (last 50 lines)]"
    kubectl logs -n kube-system "$POD_NAME" --tail=50 || true
  fi

  die "Installation failed. See debug info above."
fi

# 5. Post-install: Verify HAProxy is actually bound to port 80
# ------------------------------------------------------------------------------
info "Verifying HAProxy port binding..."
sleep 3

HAPROXY_PORT=$(ss -tulpn 2>/dev/null | grep -i haproxy | grep -oE ':(80|8080|443)' | head -1 | tr -d ':' || echo "")

if [[ "$HAPROXY_PORT" == "80" ]]; then
  success "HAProxy is correctly bound to port 80."
elif [[ "$HAPROXY_PORT" == "8080" ]]; then
  echo ""
  warn "=========================================================="
  warn "  HAProxy is bound to port 8080 instead of port 80!"
  warn "=========================================================="
  warn "This means hostNetwork port 80 binding failed silently."
  warn ""
  warn "Common causes:"
  warn "  1. Something else owns port 80 on the node HAProxy landed on"
  warn "  2. The pod lacks NET_BIND_SERVICE capability for ports < 1024"
  warn "  3. The node has net.ipv4.ip_unprivileged_port_start > 80"
  warn ""
  warn "Diagnose with:"
  warn "  ss -tulpn | grep ':80'"
  warn "  kubectl describe pod -n kube-system <haproxy-pod>"
  warn "  sysctl net.ipv4.ip_unprivileged_port_start"
  warn ""
  die "Port binding verification failed. HAProxy is not on port 80."
else
  warn "Could not determine HAProxy's bound port via ss (pod may be on a remote node)."
  warn "Manually verify: ss -tulpn | grep haproxy"
fi

# 6. Verify Ingress controller is ready
# ------------------------------------------------------------------------------
info "Checking Ingress controller readiness..."

READY=$(kubectl get pods -n kube-system \
  -l app.kubernetes.io/instance=haproxy-ingress \
  -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo "false")

if [[ "$READY" != "true" ]]; then
  warn "HAProxy pod is not yet Ready. Check: kubectl get pods -n kube-system -l app.kubernetes.io/instance=haproxy-ingress"
else
  success "HAProxy pod is Ready."
fi

# 7. Apply Ingress routes
# ------------------------------------------------------------------------------
info "Applying Ingress routes..."
kubectl delete ingress -n monitoring --all 2>/dev/null || true
kubectl apply -f "${INGRESS_YAML}"

success "install_HAproxy.sh complete"
info "HAProxy bound to host ports 80 (HTTP) | Stats on :1024"
echo ""
