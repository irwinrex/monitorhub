#!/usr/bin/env bash
# ==============================================================================
# scripts/install_k0s.sh
# Debian 12 ARM64 system prep + k0s single-node install + Helm + kubectl.
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root

header "Phase 1 — k0s  |  Debian 12 ARM64  |  t4g.xlarge"

# ── 0. Check Existing Installation ────────────────────────────────────────────
SKIP_INSTALL=false

# Check if service is active and node is Ready
if command -v k0s &>/dev/null && systemctl is-active --quiet k0scontroller; then
  export KUBECONFIG=/var/lib/k0s/pki/admin.conf
  if k0s kubectl get nodes --no-headers 2>/dev/null | grep -q " Ready"; then
    success "k0s is already installed, running, and healthy. Skipping core installation."
    SKIP_INSTALL=true
  fi
fi

# ── 1. System Packages & Config (Always Run) ──────────────────────────────────
info "Configuring system dependencies..."

rm -f /etc/apt/sources.list.d/kubernetes*.list

apt-get update -qq
apt-get install -y --no-install-recommends \
  curl wget ca-certificates gnupg \
  iptables arptables ebtables \
  socat conntrack jq python3 python3-yaml >/dev/null

update-alternatives --set iptables /usr/sbin/iptables-legacy &>/dev/null || true
update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy &>/dev/null || true
update-alternatives --set arptables /usr/sbin/arptables-legacy &>/dev/null || true
update-alternatives --set ebtables /usr/sbin/ebtables-legacy &>/dev/null || true

swapoff -a
sed -i '/[[:space:]]swap[[:space:]]/d' /etc/fstab

cat >/etc/modules-load.d/k0s.conf <<'EOF'
overlay
br_netfilter
nf_conntrack
EOF
modprobe overlay
modprobe br_netfilter
modprobe nf_conntrack

cat >/etc/sysctl.d/99-k0s.conf <<'EOF'
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.netfilter.nf_conntrack_max                     = 524288
net.netfilter.nf_conntrack_tcp_timeout_established = 86400
fs.inotify.max_user_watches    = 524288
fs.inotify.max_user_instances  = 512
fs.file-max                    = 1048576
vm.overcommit_memory = 1
vm.panic_on_oom      = 0
EOF
sysctl --system >/dev/null

success "System configuration applied"

# ── 2. k0s Installation (Only if not healthy) ─────────────────────────────────
if [[ "$SKIP_INSTALL" == "false" ]]; then

  info "Downloading k0s ${K0S_VERSION} (arm64)..."
  rm -f /usr/local/bin/k0s 2>/dev/null || true
  
  K0S_INSTALL_PATH=/usr/local/bin \
    K0S_VERSION="${K0S_VERSION}" \
    curl -sSLf https://get.k0s.sh | sh

  # Fallback for version mismatch
  INSTALLED_VER="$(k0s version 2>/dev/null || true)"
  if [[ "${INSTALLED_VER}" != *"${K0S_VERSION}"* ]]; then
    ENCODED_TAG="${K0S_VERSION//+/%2B}"
    curl -sSLf \
      "https://github.com/k0sproject/k0s/releases/download/${ENCODED_TAG}/k0s-${K0S_VERSION}-arm64" \
      -o /usr/local/bin/k0s
    chmod +x /usr/local/bin/k0s
  fi

  info "Generating k0s config..."
  mkdir -p /etc/k0s
  k0s config create >/etc/k0s/k0s.yaml

  python3 - <<'PYEOF'
import yaml
path = "/etc/k0s/k0s.yaml"
with open(path) as f:
    cfg = yaml.safe_load(f)
spec = cfg.setdefault("spec", {})
spec.setdefault("api", {}).setdefault("extraArgs", {}).update({
    "max-requests-inflight":          "400",
    "max-mutating-requests-inflight": "200",
})
with open(path, "w") as f:
    yaml.dump(cfg, f, default_flow_style=False)
PYEOF

  info "Resetting and Installing k0s systemd service..."
  k0s stop >/dev/null 2>&1 || true
  k0s reset >/dev/null 2>&1 || true
  rm -rf /var/lib/k0s /run/k0s
  systemctl daemon-reload

  k0s install controller --single -c /etc/k0s/k0s.yaml
  k0s start

  info "Waiting for k0s API server..."
  for i in $(seq 1 60); do
    if k0s kubectl get nodes >/dev/null 2>&1; then
      success "API is up"
      break
    fi
    [[ $i -eq 60 ]] && die "k0s API timeout."
    printf '.'
    sleep 2
  done
  echo

  info "Waiting for node registration..."
  for i in $(seq 1 60); do
    NODE_COUNT=$(k0s kubectl get nodes --no-headers 2>/dev/null | wc -l || echo 0)
    if [[ "$NODE_COUNT" -gt 0 ]]; then
      break
    fi
    printf '.'
    sleep 2
  done
  echo
fi

# ── 3. Post-Install Config (Always Run) ───────────────────────────────────────

info "Installing/Updating kubectl binary..."
# Extract pure version (e.g. v1.32.7) from v1.32.7+k0s.0 by stripping everything after +
KUBE_VERSION="${K0S_VERSION%+*}"
if ! command -v kubectl &>/dev/null || [[ "$(kubectl version --client -o json | jq -r .clientVersion.gitVersion)" != "${KUBE_VERSION}" ]]; then
  curl -sSLf "https://dl.k8s.io/release/${KUBE_VERSION}/bin/linux/arm64/kubectl" -o /usr/local/bin/kubectl
  chmod +x /usr/local/bin/kubectl
  success "kubectl ${KUBE_VERSION} installed"
fi

info "Configuring kubeconfig for kubectl..."
# 1. Setup for Root
mkdir -p /root/.kube
k0s kubeconfig admin >/root/.kube/config
chmod 600 /root/.kube/config
export KUBECONFIG=/root/.kube/config

# 2. Setup for Sudo User (if exists)
if [[ -n "${SUDO_USER:-}" ]]; then
  USER_HOME="$(getent passwd "${SUDO_USER}" | cut -d: -f6)"
  mkdir -p "${USER_HOME}/.kube"
  cp /root/.kube/config "${USER_HOME}/.kube/config"
  chown -R "${SUDO_USER}:${SUDO_USER}" "${USER_HOME}/.kube"
  chmod 600 "${USER_HOME}/.kube/config"
  success "kubeconfig configured for user: ${SUDO_USER}"
fi

info "Verifying node status (via kubectl)..."
kubectl wait node --all --for=condition=Ready --timeout=180s >/dev/null
kubectl get nodes -o wide

info "Installing Helm..."
if ! command -v helm &>/dev/null; then
  curl -sSLf "https://get.helm.sh/helm-${HELM_VERSION}-linux-arm64.tar.gz" |
    tar -xz --strip-components=1 -C /usr/local/bin linux-arm64/helm
  chmod +x /usr/local/bin/helm
fi

info "Updating Helm repos..."
helm repo add haproxytech https://haproxytech.github.io/helm-charts --force-update
helm repo add jetstack https://charts.jetstack.io --force-update
helm repo add grafana https://grafana.github.io/helm-charts --force-update
helm repo update >/dev/null

info "Creating namespaces..."
for ns in "${MONITORING_NS}" "${CERTMANAGER_NS}"; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

echo ""
success "install_k0s.sh complete"
echo ""
