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
apt-get update -qq
apt-get install -y --no-install-recommends \
  curl wget ca-certificates gnupg \
  iptables arptables ebtables \
  socat conntrack jq python3 python3-yaml >/dev/null
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
swapoff -a
sed -i '/[[:space:]]swap[[:space:]]/d' /etc/fstab
success "Swap disabled"

# ── 4. Kernel modules ─────────────────────────────────────────────────────────
info "Loading kernel modules..."
cat >/etc/modules-load.d/k0s.conf <<'EOF'
overlay
br_netfilter
nf_conntrack
EOF
modprobe overlay
modprobe br_netfilter
modprobe nf_conntrack
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
sysctl --system >/dev/null
success "sysctl applied"

# ── 6. k0s binary ─────────────────────────────────────────────────────────────
# The '+' in the version string (e.g. v1.32.7+k0s.0) causes curl to fail on
# some systems when it appears in the GitHub release tag segment of the URL.
# Fix: use the official get.k0s.sh installer with K0S_VERSION pinned, which
# handles the URL encoding internally. Direct curl is kept as a fallback with
# the '+' percent-encoded as '%2B' in the tag portion of the URL.
info "Downloading k0s ${K0S_VERSION} (arm64)..."

K0S_INSTALL_PATH=/usr/local/bin \
  K0S_VERSION="${K0S_VERSION}" \
  curl -sSLf https://get.k0s.sh | sh

# Verify the installed version matches what we pinned
INSTALLED_VER="$(k0s version 2>/dev/null || true)"
if [[ -z "${INSTALLED_VER}" ]]; then
  die "k0s binary not found after install — check network access to get.k0s.sh"
fi

# If get.k0s.sh installed a different version (shouldn't happen with K0S_VERSION
# set, but guard anyway), fall back to direct download with encoded URL
if [[ "${INSTALLED_VER}" != *"${K0S_VERSION}"* ]]; then
  warn "get.k0s.sh installed ${INSTALLED_VER}, expected ${K0S_VERSION} — trying direct download..."
  # Encode '+' as '%2B' in the tag only; filename keeps literal '+'
  ENCODED_TAG="${K0S_VERSION//+/%2B}"
  curl -sSLf \
    "https://github.com/k0sproject/k0s/releases/download/${ENCODED_TAG}/k0s-${K0S_VERSION}-arm64" \
    -o /usr/local/bin/k0s
  chmod +x /usr/local/bin/k0s
fi

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
for i in $(seq 1 36); do
  k0s kubectl get nodes &>/dev/null 2>&1 && {
    success "API is up"
    break
  }
  [[ $i -eq 36 ]] && die "k0s API timeout.\n  Debug: journalctl -u k0scontroller -n 100"
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
  mkdir -p "${USER_HOME}/.kube"
  cp /root/.kube/config "${USER_HOME}/.kube/config"
  chown "${SUDO_USER}:${SUDO_USER}" "${USER_HOME}/.kube/config"
  success "kubeconfig also at ${USER_HOME}/.kube/config"
fi

info "Waiting for node Ready..."
k0s kubectl wait node --all --for=condition=Ready --timeout=180s
k0s kubectl get nodes -o wide

# ── 10. Helm ──────────────────────────────────────────────────────────────────
info "Installing Helm ${HELM_VERSION} (arm64)..."
curl -sSLf "https://get.helm.sh/helm-${HELM_VERSION}-linux-arm64.tar.gz" |
  tar -xz --strip-components=1 -C /usr/local/bin linux-arm64/helm
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
  k0s kubectl create namespace "$ns" --dry-run=client -o yaml |
    k0s kubectl apply -f -
done
success "Namespaces: ${MONITORING_NS}, ${CERTMANAGER_NS}"

echo ""
success "install_k0s.sh complete"
echo ""
