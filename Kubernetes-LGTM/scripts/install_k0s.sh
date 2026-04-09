#!/usr/bin/env bash
# ==============================================================================
# Production-safe k0s installer (hardened)
# Controller-only install; worker nodes can be joined later via k0s token.
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

LOG_FILE="/var/log/k0s-install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_FILE="${SCRIPT_DIR}/lib/common.sh"

# ------------------------------------------------------------------------------
# Validate common.sh exists and exports required variables
# ------------------------------------------------------------------------------
if [[ ! -f "$COMMON_FILE" ]]; then
  echo "[ERROR] Missing common.sh at ${COMMON_FILE}"
  echo "[INFO] Create ${COMMON_FILE} with versions from common.sh"
  echo "  K0S_VERSION, HELM_VERSION, YQ_VERSION, etc."
  exit 1
fi

# shellcheck source=/dev/null
source "$COMMON_FILE"

# Versions are expected from common.sh:
: "${K0S_VERSION:?K0S_VERSION must be set in common.sh}"
: "${HELM_VERSION:?HELM_VERSION must be set in common.sh}"

# Optional versions - use common.sh values or fallbacks
YQ_VERSION="${YQ_VERSION:-v4.52.5}"

require_root

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

retry() {
  local n=0 max=5 delay=5
  until "$@"; do
    n=$((n + 1))
    if ((n >= max)); then
      echo "[ERROR] Command failed after ${n} attempts: $*" >&2
      return 1
    fi
    echo "[WARN] Attempt ${n}/${max} failed, retrying in ${delay}s..." >&2
    sleep $delay
  done
}

ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
aarch64 | arm64) ARCH="arm64" ;;
x86_64 | amd64) ARCH="amd64" ;;
*)
  echo "[ERROR] Unsupported architecture: $ARCH_RAW"
  exit 1
  ;;
esac

# ------------------------------------------------------------------------------
# System Setup
# ------------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
retry apt-get update -qq
retry apt-get install -y --no-install-recommends \
  curl ca-certificates jq socat conntrack iptables >/dev/null

# Kernel modules
modprobe overlay 2>/dev/null || true
modprobe br_netfilter 2>/dev/null || true

# Persist sysctl across reboots
cat >/etc/sysctl.d/99-k0s.conf <<'EOF'
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
sysctl --system >/dev/null 2>&1 || true

# Swap — disable at runtime only (fstab untouched; add a comment why)
# k0s works with swap but disabling avoids kubelet warnings
if swapon --show | grep -q .; then
  echo "[WARN] Disabling swap for this session (fstab not modified)"
  swapoff -a
fi

# ------------------------------------------------------------------------------
# Port Check
# ------------------------------------------------------------------------------
SKIP_K0S_INSTALL=false
for port in 80 443; do
  if ss -tuln | awk '{print $5}' | grep -qw ":${port}$\|\.${port}$"; then
    echo "[WARN] Port ${port} already in use — will continue anyway"
  fi
done

# Check if k0s already running
if systemctl is-active --quiet k0scontroller 2>/dev/null; then
  echo "[INFO] k0s already running — will skip install"
  SKIP_K0S_INSTALL=true
fi

# ------------------------------------------------------------------------------
# Install k0s (with checksum verification)
# ------------------------------------------------------------------------------
K0S_BIN="/usr/local/bin/k0s"
K0S_URL="https://github.com/k0sproject/k0s/releases/download/${K0S_VERSION}/k0s-${K0S_VERSION}-${ARCH}"
K0S_TMP="/tmp/k0s-${K0S_VERSION}-${ARCH}"

if [[ -f "$K0S_BIN" ]] && "$K0S_BIN" version 2>/dev/null | grep -qF "$K0S_VERSION"; then
  echo "[INFO] k0s ${K0S_VERSION} already installed — skipping"
else
  echo "[INFO] Downloading k0s ${K0S_VERSION} (${ARCH})"
  retry curl -fL "${K0S_URL}" -o "${K0S_TMP}"
  retry curl -fL "${K0S_URL}.sha256" -o "${K0S_TMP}.sha256"

  # Verify checksum (format: <hash> <filename>)
  (cd /tmp && sha256sum -c "${K0S_TMP##*/}.sha256")

  install -m 0755 "${K0S_TMP}" "$K0S_BIN"
  rm -f "${K0S_TMP}" "${K0S_TMP}.sha256"
fi

# ------------------------------------------------------------------------------
# Reset Guard (opt-in, explicitly destructive)
# ------------------------------------------------------------------------------
if [[ "${FORCE_RESET:-false}" == "true" ]]; then
  echo "[WARN] FORCE_RESET=true — performing destructive reset"
  systemctl stop k0scontroller 2>/dev/null || true
  "$K0S_BIN" reset --debug 2>/dev/null || true
  rm -rf /var/lib/k0s /run/k0s /etc/k0s
fi

# ------------------------------------------------------------------------------
# Config
# ------------------------------------------------------------------------------
mkdir -p /etc/k0s

if [[ ! -f /etc/k0s/k0s.yaml ]]; then
  "$K0S_BIN" config create >/etc/k0s/k0s.yaml
fi

# Install yq — pin to a specific version from common.sh (falls back to default)
YQ_URL="https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${ARCH}"
YQ_TMP="/tmp/yq_linux_${ARCH}"

if ! command -v yq &>/dev/null || ! yq --version 2>/dev/null | grep -qF "${YQ_VERSION}"; then
  echo "[INFO] Installing yq ${YQ_VERSION}"

  retry curl -fL "${YQ_URL}" -o "${YQ_TMP}"

  # Try to verify checksum, but don't fail if checksums file format is unexpected
  YQ_CHECKSUMS_URL="https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/checksums"
  if retry curl -fL "${YQ_CHECKSUMS_URL}" -o "${YQ_TMP}.checksums" 2>/dev/null; then
    EXPECTED_SHA=$(grep "yq_linux_${ARCH}$" "${YQ_TMP}.checksums" 2>/dev/null | awk '{print $1}' || true)
    if [[ -n "$EXPECTED_SHA" ]]; then
      echo "${EXPECTED_SHA}  ${YQ_TMP}" | sha256sum -c
    else
      echo "[WARN] Could not find checksum for yq_linux_${ARCH}, skipping verification"
    fi
    rm -f "${YQ_TMP}.checksums"
  else
    echo "[WARN] Could not download checksums, skipping verification"
  fi

  install -m 0755 "${YQ_TMP}" /usr/local/bin/yq
  rm -f "${YQ_TMP}"
fi

# Patch k0s config
python3 - <<'PYEOF'
import yaml
path = "/etc/k0s/k0s.yaml"
with open(path) as f:
    cfg = yaml.safe_load(f)
spec = cfg.setdefault("spec", {})
spec.setdefault("network", {})["provider"] = "kuberouter"
spec.setdefault("network", {}).setdefault("kubeRouter", {})["metricsPort"] = 8282
spec.setdefault("api", {}).setdefault("extraArgs", {}).update({
    "max-requests-inflight": "400",
    "max-mutating-requests-inflight": "200",
})
with open(path, "w") as f:
    yaml.dump(cfg, f, default_flow_style=False)
print("k0s config patched: kube-router metricsPort=8282, API tuning")
PYEOF

# Allow future worker nodes to join:
# k0s token create --role=worker   (run after install)
# No extra config needed for single-controller + separate workers topology.

# ------------------------------------------------------------------------------
# Install & Start Service
# ------------------------------------------------------------------------------
if ! systemctl is-active --quiet k0scontroller 2>/dev/null; then
  echo "[INFO] Installing k0s controller service"
  # --enable-worker keeps this node schedulable.
  # Remove --enable-worker if this will be a dedicated control-plane only.
  "$K0S_BIN" install controller --enable-worker -c /etc/k0s/k0s.yaml
  "$K0S_BIN" start
else
  echo "[INFO] k0scontroller already running — skipping install"
fi

# ------------------------------------------------------------------------------
# Export kubeconfig (only if installing k0s)
# ------------------------------------------------------------------------------
if [[ "${SKIP_K0S_INSTALL:-false}" != "true" ]]; then
  KUBECONFIG_FILE="/var/lib/k0s/pki/admin.conf"

  # Setup for root
  mkdir -p /root/.kube
  cp "$KUBECONFIG_FILE" /root/.kube/config
  chmod 600 /root/.kube/config

  # Setup for current user (if running as non-root)
  if [[ -n "${SUDO_USER:-}" ]]; then
    USER_HOME="$(getent passwd "${SUDO_USER}" | cut -d: -f6)"
    mkdir -p "${USER_HOME}/.kube"
    cp "$KUBECONFIG_FILE" "${USER_HOME}/.kube/config"
    chown "${SUDO_USER}:${SUDO_USER}" "${USER_HOME}/.kube/config"
    chmod 600 "${USER_HOME}/.kube/config"
    export KUBECONFIG="${USER_HOME}/.kube/config"
  else
    export KUBECONFIG=/root/.kube/config
  fi

  # Persist for future shell sessions
  if ! grep -qF 'KUBECONFIG=' /etc/environment 2>/dev/null; then
    echo "KUBECONFIG=${KUBECONFIG}" >> /etc/environment
  fi
fi

# ------------------------------------------------------------------------------
# Wait for API Server
# ------------------------------------------------------------------------------
echo "[INFO] Waiting for k0s API to become ready..."
for i in $(seq 1 60); do
  if "$K0S_BIN" kubectl get nodes >/dev/null 2>&1; then
    echo "[INFO] API ready after ~$((i * 2))s"
    break
  fi
  if ((i == 60)); then
    echo "[ERROR] API did not become ready in 120s"
    journalctl -u k0scontroller --no-pager -n 50 || true
    exit 1
  fi
  sleep 2
done

# ------------------------------------------------------------------------------
# Install standalone kubectl
# ------------------------------------------------------------------------------
# K0S_VERSION example: v1.29.2+k0s.0  →  KUBE_VERSION: v1.29.2
KUBE_VERSION="${K0S_VERSION%%+*}"

# Validate extracted version
if [[ ! "$KUBE_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "[ERROR] Could not derive clean Kubernetes version from K0S_VERSION=${K0S_VERSION}"
  exit 1
fi

KUBECTL_BIN="/usr/local/bin/kubectl"
KUBECTL_TMP="/tmp/kubectl-${KUBE_VERSION}"

if [[ -f "$KUBECTL_BIN" ]] && kubectl version --client 2>/dev/null | grep -qF "${KUBE_VERSION}"; then
  echo "[INFO] kubectl ${KUBE_VERSION} already installed — skipping"
else
  echo "[INFO] Installing kubectl ${KUBE_VERSION}"
  retry curl -fL \
    "https://dl.k8s.io/release/${KUBE_VERSION}/bin/linux/${ARCH}/kubectl" \
    -o "${KUBECTL_TMP}"

  # Download checksum - note: dl.k8s.io returns raw hash, not a checksums file
  retry curl -fL \
    "https://dl.k8s.io/release/${KUBE_VERSION}/bin/linux/${ARCH}/kubectl.sha256" \
    -o "${KUBECTL_TMP}.sha256"

  # Verify checksum (dl.k8s.io sha256 files contain just the hash)
  EXPECTED_SHA=$(cat "${KUBECTL_TMP}.sha256")
  echo "${EXPECTED_SHA}  ${KUBECTL_TMP}" | sha256sum -c

  install -m 0755 "${KUBECTL_TMP}" "$KUBECTL_BIN"
  rm -f "${KUBECTL_TMP}" "${KUBECTL_TMP}.sha256"
fi

# Quick smoke-test
kubectl version --client 2>/dev/null || true

# ------------------------------------------------------------------------------
# Install Helm (with checksum verification)
# ------------------------------------------------------------------------------
HELM_ARCHIVE="helm-${HELM_VERSION}-linux-${ARCH}.tar.gz"
HELM_URL="https://get.helm.sh/${HELM_ARCHIVE}"
HELM_TMP="/tmp/${HELM_ARCHIVE}"

if command -v helm &>/dev/null && helm version --short 2>/dev/null | grep -qF "${HELM_VERSION}"; then
  echo "[INFO] Helm ${HELM_VERSION} already installed — skipping"
else
  echo "[INFO] Installing Helm ${HELM_VERSION}"
  retry curl -fL "${HELM_URL}" -o "${HELM_TMP}"
  retry curl -fL "${HELM_URL}.sha256" -o "${HELM_TMP}.sha256"

  # Verify checksum (get.helm.sh sha256 files contain just the hash)
  EXPECTED_SHA=$(cat "${HELM_TMP}.sha256")
  echo "${EXPECTED_SHA}  ${HELM_TMP}" | sha256sum -c

  # Extract - note: tarball contains linux-${ARCH}/helm
  tar -xzf "${HELM_TMP}" -C /tmp
  install -m 0755 "/tmp/linux-${ARCH}/helm" /usr/local/bin/helm

  # Cleanup extracted directory
  rm -rf "/tmp/linux-${ARCH}" "${HELM_TMP}" "${HELM_TMP}.sha256"
fi

# ------------------------------------------------------------------------------
# Local Path Provisioner
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LPP_FILE="${SCRIPT_DIR}/components/local-path-storage.yaml"
echo "[DEBUG] SCRIPT_DIR=${SCRIPT_DIR}"
echo "[DEBUG] LPP_FILE=${LPP_FILE}"
ls -la "${SCRIPT_DIR}/components/"

echo "[INFO] Installing Local Path Provisioner from local YAML"

if [[ ! -f "${LPP_FILE}" ]]; then
  echo "[ERROR] LPP YAML not found at ${LPP_FILE}"
  exit 1
fi

# Skip if already installed
if kubectl get deployment local-path-provisioner -n local-path-storage &>/dev/null; then
  echo "[INFO] Local Path Provisioner already installed — skipping"
else
  kubectl apply -f "${LPP_FILE}"
fi

# Wait for namespace to exist then check deployment
echo "[INFO] Waiting for Local Path Provisioner deployment..."
kubectl wait --for=jsonpath='{.status.phase}'=Active namespace/local-path-storage --timeout=60s 2>/dev/null || true
kubectl -n local-path-storage rollout status deployment/local-path-provisioner --timeout=180s

# Set as default StorageClass
kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

echo "[SUCCESS] Local Path Provisioner ready"

# ------------------------------------------------------------------------------
# Final Validation
# ------------------------------------------------------------------------------
echo "[INFO] Waiting for all nodes to be Ready..."
kubectl wait node --all --for=condition=Ready --timeout=300s

echo ""
kubectl get nodes -o wide
echo ""
kubectl get storageclass
echo ""

# Print join token hint for future worker nodes
echo "------------------------------------------------------------"
echo "  To add worker nodes later, run on THIS controller:"
echo "    k0s token create --role=worker"
echo "  Then on each worker:"
echo "    k0s install worker --token-file <token-file>"
echo "    k0s start"
echo "------------------------------------------------------------"

# ------------------------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------------------------
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/linux-* /tmp/local-path-storage.yaml 2>/dev/null || true

echo "[SUCCESS] k0s installation complete — log: ${LOG_FILE}"
