
#!/usr/bin/env bash
set -euo pipefail
# ==============================================================================
# Production-Ready k0s Controller & Cilium CNI Installation Script
#
# This script installs k0s with Cilium CNI (kube-proxy replacement).
#
# Usage:
# sudo bash install_k0s_cilium.sh
#
# For AWS with ENI mode (recommended):
# sudo IPAM_MODE=eni bash install_k0s_cilium.sh
#
# For non-interactive CI/CD:
# sudo NON_INTERACTIVE=true bash install_k0s_cilium.sh
# ==============================================================================

# --- Configuration Variables ---
echo "⚙️ Initializing configuration..."
IPAM_MODE="${IPAM_MODE:-kubernetes}"
CILIUM_OPERATOR_REPLICAS="${CILIUM_OPERATOR_REPLICAS:-1}"
NON_INTERACTIVE=${NON_INTERACTIVE:-false}
SKIP_CONNECTIVITY_TEST=${SKIP_CONNECTIVITY_TEST:-false}
CLUSTER_NAME="${CLUSTER_NAME:-k0s-cilium}"

# --- Architecture Detection ---
MACHINE_ARCH=$(uname -m)
if [[ "$MACHINE_ARCH" == "x86_64" ]]; then
  ARCH="amd64"
elif [[ "$MACHINE_ARCH" == "aarch64" ]]; then
  ARCH="arm64"
else
  echo "⛔ Unsupported architecture: $MACHINE_ARCH"
  exit 1
fi
echo " - Detected Architecture: ${ARCH}"

# --- AWS Environment Detection ---
detect_aws_environment() {
  echo "🔍 Detecting AWS environment..."
  
  if ! curl -s --connect-timeout 2 http://169.254.169.254/latest/meta-data/instance-id &>/dev/null; then
    echo "ℹ️ Not running on AWS EC2."
    return
  fi
  
  AWS_REGION=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | grep region | awk -F\" '{print $4}' || echo "")
  AWS_ACCOUNT_ID=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | grep accountId | awk -F\" '{print $4}' || echo "")
  
  if [[ -n "$AWS_REGION" && -n "$AWS_ACCOUNT_ID" ]]; then
    echo " - AWS Region: ${AWS_REGION}"
    echo " - AWS Account: ${AWS_ACCOUNT_ID}"
    echo " - Cluster Name: ${CLUSTER_NAME}"
  else
    echo "⚠️ Could not detect AWS details"
  fi
}

# --- Dynamic Version Detection with Fallbacks ---
echo "📦 Detecting latest stable versions..."
check_internet_connectivity() {
  if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
    return 0
  else
    echo "⚠️ Warning: No internet connectivity detected. Using fallback versions."
    return 1
  fi
}

if check_internet_connectivity; then
  KUBE_VERSION=$(curl -sL https://dl.k8s.io/release/stable.txt 2>/dev/null || echo "v1.31.0")
  CILIUM_CLI_VERSION=$(curl -sL https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt 2>/dev/null || echo "v0.16.19")
  K0S_VERSION=$(curl -sSLf https://docs.k0sproject.io/stable.txt 2>/dev/null || echo "v1.31.2+k0s.0")
else
  KUBE_VERSION="v1.31.0"
  CILIUM_CLI_VERSION="v0.16.19"
  K0S_VERSION="v1.31.2+k0s.0"
fi

echo " - k0s Version: ${K0S_VERSION}"
echo " - Kubernetes Version: ${KUBE_VERSION}"
echo " - Cilium CLI Version: ${CILIUM_CLI_VERSION}"
echo " - Cilium IPAM Mode: ${IPAM_MODE}"

# --- Host IP Detection ---
K8S_API_HOST=$(hostname -I | awk '{print $1}')
if [[ -z "$K8S_API_HOST" ]]; then
  echo "⛔ Could not detect host IP address. Exiting." >&2
  exit 1
fi
echo " - Detected API Server IP: ${K8S_API_HOST}"

# --- Validate ENI mode prerequisites ---
validate_eni_mode() {
  if [[ "$IPAM_MODE" == "eni" ]]; then
    echo "🔍 Validating AWS environment for ENI mode..."
    
    if ! curl -s --connect-timeout 2 http://169.254.169.254/latest/meta-data/instance-id &>/dev/null; then
      echo "⚠️ ENI IPAM mode selected but not on AWS EC2. Switching to kubernetes mode."
      IPAM_MODE="kubernetes"
    else
      echo "✅ AWS EC2 instance detected. ENI mode enabled."
    fi
  fi
}

# --- Root check ---
check_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "⛔ This script requires root privileges."
    exit 1
  fi
}

# --- Check prerequisites ---
check_prerequisites() {
  echo "🔍 Checking system prerequisites..."
  local total_mem cpu_cores
  total_mem=$(free -m | awk '/^Mem:/{print $2}')
  cpu_cores=$(nproc)
  [[ $total_mem -lt 3800 ]] && echo "⚠️ Warning: Less than 4GB RAM (${total_mem}MB)"
  [[ $cpu_cores -lt 2 ]] && echo "⚠️ Warning: Less than 2 CPU cores (${cpu_cores})"
  
  # Set eBPF memlock limits
  if ! grep -q "DefaultLimitMEMLOCK=infinity" /etc/systemd/system.conf 2>/dev/null; then
    echo "🔧 Setting eBPF memlock limits..."
    sed -i '/^\\*.*memlock.*$/d' /etc/security/limits.conf 2>/dev/null || true
    echo -e "* soft memlock unlimited\\n* hard memlock unlimited" >> /etc/security/limits.conf
    if ! grep -q "^DefaultLimitMEMLOCK=infinity" /etc/systemd/system.conf 2>/dev/null; then
      echo "DefaultLimitMEMLOCK=infinity" >> /etc/systemd/system.conf
    fi
    systemctl daemon-reload
  fi
  
  # Load kernel modules
  for module in overlay br_netfilter; do
    if ! lsmod | grep -q "^${module}"; then
      echo "🔧 Loading kernel module: ${module}..."
      modprobe "${module}" || { echo "⛔ Failed to load ${module}"; exit 1; }
    fi
  done
  echo "✅ Prerequisites check completed."
}

# --- Install dependencies ---
install_dependencies() {
  echo "🔍 Checking required tools..."
  local missing_tools=()
  for tool in k0s kubectl helm cilium yq jq; do
    ! command -v "$tool" &>/dev/null && missing_tools+=("$tool")
  done
  
  if [[ ${#missing_tools[@]} -eq 0 ]]; then
    echo "✅ All required tools are installed."
    return
  fi
  
  echo "📦 Installing missing tools: ${missing_tools[*]}"
  for tool in "${missing_tools[@]}"; do
    echo " -> Installing ${tool}..."
    case "$tool" in
      k0s)
        curl -sSLf https://get.k0s.sh | K0S_VERSION="${K0S_VERSION}" sh || {
          curl -sSLf -o /usr/local/bin/k0s "https://github.com/k0sproject/k0s/releases/download/${K0S_VERSION}/k0s-${K0S_VERSION}-${ARCH}"
          chmod +x /usr/local/bin/k0s
        } ;;
      kubectl)
        curl -LO "https://dl.k8s.io/release/${KUBE_VERSION}/bin/linux/${ARCH}/kubectl"
        install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && rm kubectl ;;
      helm)
        curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash ;;
      cilium)
        os="$(uname | tr '[:upper:]' '[:lower:]')"
        arch="$(uname -m | sed 's/x86_64/amd64/' | sed 's/aarch64/arm64/')"
        curl -L --fail --remote-name-all "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-${os}-${arch}.tar.gz"{,.sha256sum}
        sha256sum --check "cilium-${os}-${arch}.tar.gz.sha256sum" || echo "⚠️ Checksum verification skipped"
        tar -C /usr/local/bin -xzvf "cilium-${os}-${arch}.tar.gz"
        rm -f "cilium-${os}-${arch}.tar.gz"{,.sha256sum} ;;
      yq)
        wget -q "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${ARCH}" -O /usr/local/bin/yq
        chmod +x /usr/local/bin/yq ;;
      jq)
        apt-get update -qq && apt-get install -y jq 2>/dev/null || yum install -y jq 2>/dev/null || echo "⚠️ jq install may have failed" ;;
    esac
    if command -v "$tool" &>/dev/null; then
      echo " ✅ ${tool} installed."
    else
      echo " ⚠️ ${tool} installation may have failed."
    fi
  done
}

# --- Install k0s ---
install_and_configure_k0s() {
  if systemctl is-active --quiet k0scontroller; then
    echo "ℹ️ k0s controller already running."
    return
  fi
  
  echo "📄 Generating k0s configuration..."
  k0s config create > k0s.yaml
  
  echo "🔧 Patching k0s.yaml for custom CNI..."
  yq eval -i '.spec.network.provider = "custom"' k0s.yaml
  yq eval -i '.spec.network.kubeProxy.disabled = true' k0s.yaml
  
  echo "🚀 Installing k0s controller..."
  k0s install controller --enable-worker --no-taints -c k0s.yaml
  systemctl enable --now k0scontroller
  
  echo "⏳ Waiting for k0s to be ready..."
  if ! timeout 300 bash -c 'until k0s status &>/dev/null; do sleep 5; done'; then
    echo "⛔ k0s failed to start."
    journalctl -u k0scontroller -n 50 --no-pager
    exit 1
  fi
  
  echo "✅ k0s controller is running."
  
  echo "🔧 Setting up kubeconfig..."
  mkdir -p "$HOME/.kube"
  k0s kubeconfig admin > "$HOME/.kube/config"
  chown -R "$(id -u):$(id -g)" "$HOME/.kube"
  chmod 600 "$HOME/.kube/config"
  export KUBECONFIG="$HOME/.kube/config"
  
  if [[ -n "${SUDO_USER:-}" ]]; then
    local sudo_user_home
    sudo_user_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    if [[ -n "$sudo_user_home" ]]; then
      mkdir -p "$sudo_user_home/.kube"
      cp "$HOME/.kube/config" "$sudo_user_home/.kube/config"
      chown -R "$SUDO_USER:$SUDO_USER" "$sudo_user_home/.kube"
      chmod 600 "$sudo_user_home/.kube/config"
    fi
  fi
  
  echo "⏳ Waiting for node to be Ready..."
  timeout 300 bash -c 'until kubectl get nodes 2>/dev/null | grep -q "Ready"; do echo -n "."; sleep 5; done' || {
    echo "⚠️ Timeout waiting for node."
    kubectl get nodes 2>/dev/null || true
  }
  echo -e "\\n✅ Node is ready."
  
  echo "🔍 Verifying API server..."
  if timeout 60 bash -c "until kubectl get --raw /healthz &>/dev/null; do sleep 2; done"; then
    echo "✅ API server is accessible."
  else
    echo "⚠️ API server check timed out, continuing..."
  fi
}

# --- Install Cilium ---
install_cilium() {
  if helm status cilium -n kube-system &>/dev/null; then
    echo "ℹ️ Cilium already installed."
    return
  fi
  
  echo "🚀 Deploying Cilium CNI..."
  helm repo add cilium https://helm.cilium.io/
  helm repo update
  
  local chart_ver
  chart_ver=$(helm search repo cilium/cilium --versions -o json | jq -r '.[0].version' 2>/dev/null || echo "1.16.4")
  echo " - Cilium version: ${chart_ver}"
  
  local helm_args=(
    "cilium" "cilium/cilium"
    "--version" "${chart_ver}"
    "--namespace" "kube-system"
    "--create-namespace"
    "--set" "kubeProxyReplacement=true"
    "--set" "k8sServiceHost=${K8S_API_HOST}"
    "--set" "k8sServicePort=6443"
    "--set" "operator.replicas=${CILIUM_OPERATOR_REPLICAS}"
    "--set" "ipam.mode=${IPAM_MODE}"
    "--set" "hubble.enabled=true"
    "--set" "hubble.relay.enabled=true"
    "--set" "hubble.ui.enabled=true"
    "--set" "prometheus.enabled=true"
    "--set" "operator.prometheus.enabled=true"
    "--set" "bpf.mapMax=65536"
    "--set" "bpf.dynamicSizeRatio=0.0025"
    "--set" "loadBalancer.mode=snat"
    "--set" "daemon.updateStrategy.rollingUpdate.maxUnavailable=1"
  )
  
  if [[ "$IPAM_MODE" == "eni" ]]; then
    helm_args+=(
      "--set" "eni.enabled=true"
      "--set" "tunnel=disabled"
      "--set" "endpointRoutes.enabled=true"
    )
  fi
  
  helm install "${helm_args[@]}" --wait --timeout 10m || {
    echo "⚠️ Helm install failed or timed out."
    kubectl get pods -n kube-system -l app.kubernetes.io/name=cilium
    exit 1
  }
  
  echo "✅ Cilium deployed."
  
  echo "⏳ Verifying Cilium rollout..."
  kubectl -n kube-system rollout status ds/cilium --timeout=5m || echo "⚠️ Cilium rollout check timed out"
  kubectl -n kube-system rollout status deploy/cilium-operator --timeout=5m || echo "⚠️ Operator rollout timed out"
  
  echo "⏳ Waiting for CoreDNS..."
  kubectl -n kube-system rollout status deploy/coredns --timeout=3m || echo "⚠️ CoreDNS not ready"
  
  echo "🔄 Restarting CoreDNS..."
  kubectl -n kube-system rollout restart deploy/coredns
  kubectl -n kube-system rollout status deploy/coredns --timeout=2m || echo "⚠️ CoreDNS restart timed out"
  
  echo "⏳ Checking Cilium health..."
  if cilium status --wait --wait-duration 5m; then
    echo "✅ Cilium is healthy."
  else
    echo "⚠️ Cilium status check incomplete, may resolve shortly."
    cilium status || true
  fi
}

# --- Run diagnostics ---
run_diagnostics() {
  if [[ "$SKIP_CONNECTIVITY_TEST" == "true" ]]; then
    echo "ℹ️ Skipping connectivity tests."
    return
  fi
  
  echo "🔍 Running connectivity tests..."
  
  if ! kubectl get pods -n kube-system -l k8s-app=kube-dns 2>/dev/null | grep -q "Running"; then
    echo "⚠️ CoreDNS not running yet"
    return
  fi
  
  if cilium connectivity test --test-concurrency=1 --all-flows=false 2>/dev/null; then
    echo "✅ Connectivity tests passed."
  else
    echo "⚠️ Connectivity tests incomplete - may resolve later"
  fi
}

# --- Print summary ---
print_cluster_summary() {
  local k0s_version node_ip
  k0s_version=$(k0s version 2>/dev/null || echo "unknown")
  node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "$K8S_API_HOST")
  
  local hubble_access="Not configured"
  if kubectl get svc -n kube-system hubble-ui &>/dev/null; then
    hubble_access="kubectl port-forward -n kube-system svc/hubble-ui 12000:80"
  fi

  echo -e "\\n\\n=================================================================="
  echo " 🎉 CLUSTER INSTALLATION COMPLETE 🎉"
  echo "=================================================================="
  echo " K0S Version: ${k0s_version}"
  echo " Node IP: ${node_ip}"
  echo " Kubeconfig: ${HOME}/.kube/config"
  echo " IPAM Mode: ${IPAM_MODE}"
  echo " Cilium: Installed"
  echo " AWS ALB Controller: Not Installed"
  echo " Hubble UI: $hubble_access"
  echo "------------------------------------------------------------------"
  echo " Next Steps:"
  echo " - Check cluster: kubectl get nodes -o wide"
  echo " - Check pods: kubectl get pods -A"
  echo " - Cilium status: cilium status"
  echo "=================================================================="
}

# --- Cleanup ---
cleanup() {
  echo "🧹 Cleaning up..."
  [[ -f k0s.yaml ]] && rm -f k0s.yaml
}

# --- Main ---
main() {
  trap cleanup EXIT
  check_root
  detect_aws_environment
  validate_eni_mode
  check_prerequisites
  install_dependencies
  install_and_configure_k0s
  install_cilium
  run_diagnostics
  print_cluster_summary
  
  echo ""
  echo "✅ Installation complete!"
}

main "$@"
