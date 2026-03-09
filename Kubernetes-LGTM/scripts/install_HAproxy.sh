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

require_helm

# Setup Environment
# ------------------------------------------------------------------------------
: "${HAPROXY_CHART_VERSION:=1.49.0}"
HAPROXY_VALUES="${SCRIPT_DIR}/../values/haproxy-values.yaml"
INGRESS_YAML="${SCRIPT_DIR}/../values/ingress.yaml"

if [[ ! -f "${HAPROXY_VALUES}" ]]; then
  die "Values file not found: ${HAPROXY_VALUES}"
fi

if [[ ! -f "${INGRESS_YAML}" ]]; then
  die "Ingress file not found: ${INGRESS_YAML}"
fi

# 1. Clean Previous Failed Installs (if any)
# ------------------------------------------------------------------------------
STATUS=$(helm status haproxy-ingress -n kube-system -o jsonpath='{.info.status}' 2>/dev/null || echo "not-found")

if [[ "$STATUS" == "failed" || "$STATUS" == "pending-install" || "$STATUS" == "pending-upgrade" || "$STATUS" == "pending-rollback" ]]; then
  warn "Found broken Helm release (status: $STATUS). Uninstalling..."
  helm uninstall haproxy-ingress -n kube-system --wait || true
fi

# Unconditionally purge stale rate-limit keys from the ConfigMap (if present).
CM_NAME="haproxy-ingress-kubernetes-ingress"
if kubectl get configmap "${CM_NAME}" -n kube-system &>/dev/null; then
  info "Purging stale rate-limit keys from ConfigMap/${CM_NAME} (if present)..."
  for KEY in rate-limit-requests rate-limit-period rate-limit-size rate-limit-status-code; do
    if kubectl get configmap "${CM_NAME}" -n kube-system \
      -o jsonpath="{.data.${KEY}}" 2>/dev/null | grep -q .; then
      kubectl patch configmap "${CM_NAME}" -n kube-system \
        --type=json \
        -p="[{\"op\":\"remove\",\"path\":\"/data/${KEY}\"}]"
      info "  Removed stale key: ${KEY}"
    fi
  done
fi

# 2. Pre-flight: Check Port 80 availability
# ------------------------------------------------------------------------------
info "Checking port 80 availability on this host..."

if ss -tulpn 2>/dev/null | grep -qE '\b:80\b' &&
  ! ss -tulpn 2>/dev/null | grep -E '\b:80\b' | grep -qi haproxy; then
  warn "Port 80 is in use on this host:"
  ss -tulpn | grep -E '\b:80\b' || true
  die "Port 80 conflict detected. Stop the conflicting service before installing HAProxy."
fi

if ss -tulpn 2>/dev/null | grep -qE '\b:8080\b'; then
  warn "Port 8080 is in use — this may be a previous HAProxy install that failed:"
  ss -tulpn | grep -E '\b:8080\b' || true
fi

# 3. Install / Upgrade
# ------------------------------------------------------------------------------
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

# 4. Post-install: Verify HAProxy is actually bound to port 80
# ------------------------------------------------------------------------------
info "Waiting for HAProxy to bind to port 80 (up to 40s)..."

HAPROXY_PORT=""
for i in $(seq 1 20); do
  HAPROXY_PORT=$(ss -tulpn 2>/dev/null | grep -i haproxy | grep -oE ':(80|8080|443)' | head -1 | tr -d ':' || echo "")
  [[ -n "$HAPROXY_PORT" ]] && break
  sleep 2
done

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

# 5. Verify Ingress controller is ready
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

# 6. Apply Ingress routes
# ------------------------------------------------------------------------------
# Resolve NODE_IP — try cloud metadata endpoints for public IP first,
# then fall back to kubectl InternalIP (bare metal / private-only VMs).
resolve_public_ip() {
  local IP=""

  # AWS
  IP=$(curl -sf --max-time 2 \
    http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "")
  [[ -n "$IP" ]] && {
    echo "$IP"
    return
  }

  # GCP
  IP=$(curl -sf --max-time 2 \
    -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip" \
    2>/dev/null || echo "")
  [[ -n "$IP" ]] && {
    echo "$IP"
    return
  }

  # Azure
  IP=$(curl -sf --max-time 2 \
    -H "Metadata: true" \
    "http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/publicIpAddress?api-version=2021-02-01" \
    2>/dev/null || echo "")
  [[ -n "$IP" ]] && {
    echo "$IP"
    return
  }

  # Hetzner
  IP=$(curl -sf --max-time 2 \
    http://169.254.169.254/hetzner/v1/metadata/public-ipv4 2>/dev/null || echo "")
  [[ -n "$IP" ]] && {
    echo "$IP"
    return
  }

  # DigitalOcean
  IP=$(curl -sf --max-time 2 \
    http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address 2>/dev/null || echo "")
  [[ -n "$IP" ]] && {
    echo "$IP"
    return
  }

  echo ""
}

info "Resolving node IP..."
PUBLIC_IP=$(resolve_public_ip)
PRIVATE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "")

if [[ -n "$PUBLIC_IP" ]]; then
  NODE_IP="$PUBLIC_IP"
  info "  Public IP  (metadata): ${PUBLIC_IP}"
  [[ -n "$PRIVATE_IP" ]] && info "  Private IP (kubectl):  ${PRIVATE_IP}"
elif [[ -n "$PRIVATE_IP" ]]; then
  NODE_IP="$PRIVATE_IP"
  warn "  No public IP found via metadata — using private IP: ${PRIVATE_IP}"
  warn "  HAProxy will only be reachable within the private network."
else
  NODE_IP=""
  warn "  Could not determine node IP. Verify manually after install."
fi

info "Applying Ingress routes..."
kubectl apply -f "${INGRESS_YAML}"

info "Restarting HAProxy via Helm to pick up new config..."
helm upgrade haproxy-ingress haproxytech/kubernetes-ingress \
  --namespace kube-system \
  --reuse-values \
  --wait --timeout 5m || true

success "install_HAproxy.sh complete"
info "HAProxy bound to host ports 80 (HTTP) | Stats on :1024"

if [[ -n "${NODE_IP}" ]]; then
  info "Access via ${NODE_IP}:"
  info "  Grafana  → http://${NODE_IP}/"
  info "  Prometheus → http://${NODE_IP}/metrics"
  info "  Loki     → http://${NODE_IP}/logs"
  info "  Tempo    → http://${NODE_IP}/traces"
  if [[ -n "${PRIVATE_IP}" && "${NODE_IP}" != "${PRIVATE_IP}" ]]; then
    info "Also reachable on private network via ${PRIVATE_IP}"
  fi
fi
echo ""
