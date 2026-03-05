# LGTM Stack — Deployment Guide
## k0s · Single Node · HAProxy Ingress · DaemonSet

---

## Project Structure

```
.
├── install_all.sh              ← Run this for a full install
│
├── scripts/
│   ├── lib/
│   │   └── common.sh           ← Shared: versions, colours, helpers
│   ├── install_k0s.sh          ← Phase 1: k0s + Helm
│   ├── install_secrets.sh      ← Phase 2: Grafana admin secret
│   ├── install_LGTM.sh         ← Phase 3: Loki + Tempo + Mimir + Grafana
│   └── install_HAproxy.sh      ← Phase 4: HAProxy Ingress + Ingress routes
│
└── values/
    ├── haproxy-values.yaml     ← HAProxy DaemonSet configuration
    ├── ingress.yaml            ← Ingress routes (Grafana, Mimir, Loki, Tempo)
    ├── loki-values.yaml         ← Loki: S3 storage
    ├── tempo-values.yaml        ← Tempo: S3 storage
    ├── mimir-values.yaml        ← Mimir: S3 storage
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
| Security group | Ports 22, 80 open inbound |

**S3 Buckets Created:**
- `lgtm-observability-loki-data` - Loki logs
- `lgtm-observability-tempo-data` - Tempo traces
- `lgtm-observability-mimir-data` - Mimir metrics
- `lgtm-observability-mimir-data-alertmanager` - Mimir alertmanager
- `lgtm-observability-mimir-data-ruler` - Mimir ruler
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

# Custom Grafana password
GRAFANA_ADMIN_PASSWORD="strong-password" sudo bash install_all.sh -y
```

### 4 — Skip phases
```bash
# Only deploy HAProxy
SKIP_K0S=true SKIP_SECRETS=true SKIP_LGTM=true SKIP_BACKUP=true sudo bash install_all.sh

# Redeploy LGTM only
SKIP_K0S=true SKIP_HAPROXY=true SKIP_SECRETS=true SKIP_BACKUP=true sudo bash install_all.sh
```

---

## Access

After deployment:

| Service | URL |
|---|---|
| Grafana | http://<NODE_IP>/ |
| Mimir (metrics) | http://<NODE_IP>/metrics |
| Loki (logs) | http://<NODE_IP>/logs |
| Tempo (traces) | http://<NODE_IP>/traces |

**HAProxy Stats:** http://<NODE_IP>:1024 (admin/admin)

---

## Grafana Credentials

The Grafana admin password is stored in a Kubernetes secret.

### Get password:
```bash
# Method 1: From secret
kubectl get secret grafana-admin -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d

# Method 2: From secret (one-liner)
kubectl get secret grafana-admin -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d && echo

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

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     External                                 │
│   http://<NODE_IP>/  → Grafana                             │
│   http://<NODE_IP>/metrics → Mimir                         │
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
                     │   Mimir    │
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
| Mimir | http://mimir-gateway.monitoring.svc.cluster.local:80/prometheus |
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
| Mimir | 6.0.5 |
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
