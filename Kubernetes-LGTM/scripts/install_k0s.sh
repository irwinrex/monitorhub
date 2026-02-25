#!/usr/bin/env bash
# ==============================================================================
# scripts/install_k0s.sh
# Debian 12 ARM64 system prep + k0s single-node install + Helm bootstrap.
#
# Run standalone:   sudo bash scripts/install_k0s.sh
# Run via all:      called automatically by install_all.sh
#
# After this script:
#   • k0s running as systemd service
#   • /root/.kube/config populated
#   • helm at /usr/local/bin/helm
#   • Helm repos: haproxytech, jetstack, grafana
#   • Namespaces: monitoring, cert-manager
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root

header "Phase 1 — k0s  |  Debian 12 ARM64  |  t4g.xlarge"

# ── 1. System packages ────────────────────────────────────────────────────────
info "Installing system dependencies..."
apt-get update -qq || die "apt-get update failed - check network connectivity"
apt-get install -y --no-install-recommends \
  curl wget ca-certificates gnupg \
  iptables arptables ebtables \
  socat conntrack jq python3 python3-yaml >/dev/null || die "Failed to install system packages"
success "System packages installed"

# ── 2. iptables-legacy ────────────────────────────────────────────────────────
# Debian 12 defaults to nftables. k0s/kube-proxy require iptables-legacy
# or NAT rules are silently broken and pods lose external connectivity.
info "Switching to iptables-legacy (Debian 12 requirement)..."
update-alternatives --set iptables /usr/sbin/iptables-legacy
update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
update-alternatives --set arptables /usr/sbin/arptables-legacy
update-alternatives --set ebtables /usr/sbin/ebtables-legacy
success "iptables-legacy active"

# ── 3. Swap off ───────────────────────────────────────────────────────────────
info "Disabling swap..."
swapoff -a 2>/dev/null || true
sed -i '/[[:space:]]swap[[:space:]]/d' /etc/fstab 2>/dev/null || true
success "Swap disabled"

# ── 4. Kernel modules ─────────────────────────────────────────────────────────
info "Loading kernel modules..."
cat >/etc/modules-load.d/k0s.conf <<'EOF'
overlay
br_netfilter
nf_conntrack
EOF
for mod in overlay br_netfilter nf_conntrack; do
  if ! modprobe "$mod" 2>/dev/null; then
    warn "Module $mod failed to load - may already be built-in"
  fi
done
success "Kernel modules loaded"

# ── 5. sysctl ─────────────────────────────────────────────────────────────────
info "Applying sysctl tunables..."
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
sysctl --system >/dev/null || die "Failed to apply sysctl settings"

info "Verifying sysctl settings..."
SYSCTL_OK=true
for param in net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables fs.inotify.max_user_watches; do
  value=$(sysctl -n "$param" 2>/dev/null || echo "0")
  if [[ "$value" == "0" || -z "$value" ]]; then
    warn "  FAILED: $param not set correctly"
    SYSCTL_OK=false
  else
    info "  OK: $param = $value"
  fi
done
[[ "$SYSCTL_OK" == "true" ]] || die "Sysctl verification failed"
success "sysctl applied and verified"

# ── 6. k0s binary ─────────────────────────────────────────────────────────────
info "Downloading k0s ${K0S_VERSION} (arm64)..."
curl -sSLf --max-time 300 \
  "https://github.com/k0sproject/k0s/releases/download/${K0S_VERSION}/k0s-${K0S_VERSION}-arm64" \
  -o /usr/local/bin/k0s || die "Failed to download k0s binary"
chmod +x /usr/local/bin/k0s
success "k0s: $(k0s version)"

# ── 7. k0s config ─────────────────────────────────────────────────────────────
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
# Disable konnectivity — not needed without separate worker nodes (~30 MB saved)
spec.setdefault("konnectivity", {})["enabled"] = False
with open(path, "w") as f:
    yaml.dump(cfg, f, default_flow_style=False)
print("  k0s config patched")
PYEOF

# ── 8. k0s systemd service ────────────────────────────────────────────────────
info "Installing k0s systemd service..."
k0s install controller --single -c /etc/k0s/k0s.yaml
k0s start

info "Waiting for k0s API server..."
for ((i=1; i<=36; i++)); do
  k0s kubectl get nodes &>/dev/null 2>&1 && {
    success "API is up"
    break
  }
  if [[ $i -eq 36 ]]; then
    die "k0s API timeout.\n  Debug: journalctl -u k0scontroller -n 100"
  fi
  printf '.'
  sleep 5
done
echo

# ── 9. kubeconfig ─────────────────────────────────────────────────────────────
info "Exporting kubeconfig..."
mkdir -p /root/.kube
k0s kubeconfig admin >/root/.kube/config
chmod 600 /root/.kube/config
export KUBECONFIG=/root/.kube/config

if [[ -n "${SUDO_USER:-}" ]]; then
  USER_HOME="$(getent passwd "${SUDO_USER}" | cut -d: -f6)"
  if [[ -n "$USER_HOME" && "$USER_HOME" != "/" ]]; then
    mkdir -p "${USER_HOME}/.kube"
    cp /root/.kube/config "${USER_HOME}/.kube/config"
    chown "${SUDO_USER}:${SUDO_USER}" "${USER_HOME}/.kube/config"
    success "kubeconfig also at ${USER_HOME}/.kube/config"
  else
    success "kubeconfig at /root/.kube/config (no sudo user home)"
  fi
fi

info "Waiting for node Ready..."
k0s kubectl wait node --all --for=condition=Ready --timeout=180s
k0s kubectl get nodes -o wide

# ── 10. Helm ──────────────────────────────────────────────────────────────────
info "Installing Helm ${HELM_VERSION} (arm64)..."
curl -sSLf --max-time 300 "https://get.helm.sh/helm-${HELM_VERSION}-linux-arm64.tar.gz" |
  tar -xz --strip-components=1 -C /usr/local/bin linux-arm64/helm || die "Failed to download/install Helm"
chmod +x /usr/local/bin/helm
success "Helm: $(helm version --short)"

info "Adding Helm repos..."
helm repo add haproxytech https://haproxytech.github.io/helm-charts --force-update
helm repo add jetstack https://charts.jetstack.io --force-update
helm repo add grafana https://grafana.github.io/helm-charts --force-update
helm repo update >/dev/null
success "Helm repos: haproxytech, jetstack, grafana"

# ── 11. Namespaces ────────────────────────────────────────────────────────────
info "Creating namespaces..."
for ns in "${MONITORING_NS}" "${CERTMANAGER_NS}"; do
  if k0s kubectl get namespace "$ns" &>/dev/null 2>&1; then
    info "Namespace '$ns' already exists"
  else
    k0s kubectl create namespace "$ns"
    success "Created namespace: $ns"
  fi
done
success "Namespaces: ${MONITORING_NS}, ${CERTMANAGER_NS}"

echo ""
success "install_k0s.sh complete"
echo ""
