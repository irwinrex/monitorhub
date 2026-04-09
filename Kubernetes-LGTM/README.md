# LGTM Stack — Deployment Guide
## k0s · Expandable Controller · HAProxy Ingress · DaemonSet

---

## Project Structure

```
.
├── install_all.sh              ← Run this for a full install
│
├── scripts/
│   ├── lib/
│   │   └── common.sh           ← Shared: versions, colours, helpers
│   ├── install_k0s.sh          ← Phase 1: k0s Controller + Helm
│   ├── install_secrets.sh      ← Phase 2: Grafana admin secret
│   ├── install_LGTM.sh         ← Phase 3: Loki + Tempo + Prometheus + Grafana
│   └── install_HAproxy.sh      ← Phase 4: HAProxy Ingress + Ingress routes
│
└── values/
    ├── haproxy-values.yaml     ← HAProxy DaemonSet configuration
    ├── ingress.yaml            ← Ingress routes (Grafana, Prometheus, Loki, Tempo)
    ├── loki-values.yaml         ← Loki: S3 storage
    ├── tempo-values.yaml        ← Tempo: S3 storage
    ├── mimir-values.yaml        ← Prometheus: S3 storage
    ├── grafana-values.yaml      ← Grafana: datasources
    └── alertmanager-values.yaml ← Alertmanager (optional)
```

---

## Pre-requisites

| | Detail |
|---|---|
| Instance | t4g.xlarge · 4 vCPU / 16 GB · Debian 12 ARM64 · fresh |
| IAM role | EC2 instance role with S3 access |
| S3 bucket | Base name you provide (e.g., `lgtm-observability`) |
| Security group | Ports 22, 80, 6443 (API), 10250 (Kubelet) open inbound |

**Note:** For multi-node expansion, ensure ports 6443 and 10250 are open between nodes.

---

## Expansion (Adding Nodes)

This setup installs k0s as a controller with the worker role enabled on the primary node. To add more worker nodes to the cluster:

1. **Generate a join token on the primary node:**
   ```bash
   sudo k0s token create --role worker
   ```

2. **On the new node, install k0s as a worker:**
   ```bash
   curl -sSLf https://get.k0s.sh | sudo sh
   sudo k0s install worker <TOKEN>
   sudo k0s start
   ```

---

**S3 Buckets Created:**
- `lgtm-observability-loki-data` - Loki logs
- `lgtm-observability-tempo-data` - Tempo traces
- `lgtm-observability-mimir-data` - Prometheus metrics
- `lgtm-observability-mimir-data-alertmanager` - Prometheus alertmanager
- `lgtm-observability-mimir-data-ruler` - Prometheus ruler
- `lgtm-observability-grafana-data` - Grafana dashboards

**IAM Policy:**
```json
{
  "Effect": "Allow",
  "Action": ["s3:GetObject","s3:PutObject","s3:DeleteObject","s3:ListBucket"],
  "Resource": [
    "arn:aws:s3:::lgtm-observability*",
    "arn:aws:s3:::lgtm-observability*/*"
  ]
}
```

---

## Deployment

### 1 — Upload
```bash
scp -r ./Kubernetes-LGTM admin@<EC2-IP>:~/
ssh admin@<EC2-IP>
cd ~/Kubernetes-LGTM
```

### 2 — Make executable
```bash
chmod +x install_all.sh scripts/*.sh
```

### 3 — Full install
```bash
# Interactive
sudo bash install_all.sh

# Non-interactive
sudo bash install_all.sh -y

# With S3 config
sudo bash install_all.sh -b lgtm-observability -r us-east-1 -y

# With environment variables
S3_BUCKET=lgtm-observability S3_REGION=us-east-1 sudo -E bash install_all.sh -y

# Force recreate secrets (new passwords)
sudo bash install_all.sh -y -f
```

### 4 — Skip phases
```bash
# Only deploy HAProxy
SKIP_K0S=true SKIP_SECRETS=true SKIP_LGTM=true sudo bash install_all.sh

# Redeploy LGTM only
SKIP_K0S=true SKIP_HAPROXY=true SKIP_SECRETS=true sudo bash install_all.sh
```

### Command-line Options

| Option | Description |
|---|---|
| `-b, --bucket-name` | S3 base bucket name |
| `-r, --region` | S3 region (e.g., us-west-2) |
| `-y, --yes` | Non-interactive mode |
| `-f, --force` | Force recreate secrets |
| `-h, --help` | Show help |

---

## Access

After deployment:

| Service | URL | Auth |
|---|---|---|
| Grafana | http://<NODE_IP>/ | admin / (check secret) |
| Prometheus (metrics) | http://<NODE_IP>/metrics | admin / (check secret) |
| Loki (logs) | http://<NODE_IP>/logs | admin / (check secret) |
| Tempo (traces) | http://<NODE_IP>/traces | admin / (check secret) |

**HAProxy Stats:** http://<NODE_IP>:1024 (admin/admin)

---

## Grafana Credentials

The Grafana admin password is stored in a Kubernetes secret.

### Get password:
```bash
# From secret
kubectl get secret grafana-admin -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d

# Default username: admin
```

### Set custom password:
```bash
# During install
GRAFANA_ADMIN_PASSWORD="your-password" sudo bash install_all.sh

# Or update existing secret
kubectl create secret generic grafana-admin \
  -n monitoring \
  --from-literal=admin-user=admin \
  --from-literal=admin-password=your-password \
  -o yaml --dry-run=client | kubectl apply -f -
```

---

## Basic Auth Credentials (HAProxy)

The HAProxy basic auth is required for Prometheus, Loki, and Tempo endpoints.

### Default credentials:
- **Username:** admin
- **Password:** (auto-generated, displayed at end of install)

### Get password:
```bash
kubectl get secret lgtm-basic-auth -n monitoring -o jsonpath='{.data.password}' | base64 -d
```

### Recreate with custom password:
```bash
# Force recreate secrets
sudo bash install_all.sh -y -f
```

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     External                                 │
│   http://<NODE_IP>/  → Grafana                             │
│   http://<NODE_IP>/metrics → Prometheus                         │
│   http://<NODE_IP>/logs    → Loki                          │
│   http://<NODE_IP>/traces → Tempo                          │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  HAProxy Ingress (DaemonSet, hostPort :80)                 │
│  - Ingress routes managed via values/ingress.yaml           │
└──────────────────────────┬──────────────────────────────────┘
                           │
        ┌──────────────────┼──────────────────┐
        ▼                  ▼                  ▼
   ┌─────────┐        ┌─────────┐       ┌─────────┐
   │ Grafana │        │  Loki   │       │  Tempo  │
   │  :80    │        │  :3100  │       │  :4318  │
   └────┬────┘        └────┬────┘       └────┬────┘
        │                   │                  │
        └───────────────────┼──────────────────┘
                            ▼
                     ┌─────────────┐
                     │   Prometheus    │
                     │  :80       │
                     └─────────────┘

┌─────────────────────────────────────────────────────────────┐
│  S3 Storage                                                │
│  - loki-data, tempo-data, mimir-data                      │
└─────────────────────────────────────────────────────────────┘
```

---

## Grafana Datasources

Pre-configured:

| Datasource | URL |
|---|---|
| Prometheus | http://mimir-gateway.monitoring.svc.cluster.local:80/prometheus |
| Loki | http://loki.monitoring.svc.cluster.local:3100 |
| Tempo | http://tempo.monitoring.svc.cluster.local:4318 |
| Alertmanager | http://mimir-gateway.monitoring.svc.cluster.local:80/alertmanager |

---

## Versions

All versions in `scripts/lib/common.sh`:

| Component | Version |
|---|---|
| k0s | v1.34.3+k0s.0 |
| Helm | v3.17.1 |
| HAProxy Ingress | 1.49.0 |
| Loki | 6.53.0 |
| Tempo | 1.24.4 |
| Prometheus | 6.0.5 |
| Grafana | 10.5.15 |

---

## Troubleshooting

```bash
# HAProxy logs
kubectl logs -n kube-system -l app.kubernetes.io/instance=haproxy-ingress

# HAProxy config
kubectl exec -n kube-system deploy/haproxy-ingress-kubernetes-ingress -- cat /etc/haproxy/haproxy.cfg

# Check ingress
kubectl get ingress -n monitoring

# Check services
kubectl get svc -n monitoring

# Check pods
kubectl get pods -n monitoring -o wide

# Port forward to Grafana
kubectl port-forward -n monitoring svc/grafana 3000:80

# Test connectivity
kubectl run test --rm -it --image=busybox --restart=Never -- \
  wget -qO- http://loki.monitoring.svc.cluster.local:3100/ready
```
