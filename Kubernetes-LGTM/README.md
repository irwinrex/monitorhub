# LGTM Stack — Deployment Guide
## k0s · Single Node · t4g.xlarge · Debian 12 ARM64 · HAproxy · mTLS

---

## Project Structure

```
.
├── install_all.sh              ← Run this for a full install
│
├── scripts/
│   ├── lib/
│   │   └── common.sh           ← Shared: versions, colours, helpers (sourced, not run)
│   ├── install_k0s.sh          ← Phase 1: system prep + k0s + Helm
│   ├── install_HAproxy.sh      ← Phase 2: HAproxy Ingress Controller
│   ├── install_secrets.sh      ← Phase 3: Grafana admin secret
│   ├── install_LGTM.sh         ← Phase 4: Loki + Tempo + Mimir + Grafana
│   └── backup_all.sh           ← Backup LGTM data to S3
│
└── values/
    ├── haproxy-values.yaml     ← HAproxy Ingress configuration
    ├── ingress-values.yaml     ← IngressClass configuration
    ├── loki-values.yaml        ← Loki configuration: S3, resources
    ├── tempo-values.yaml       ← Tempo configuration: S3, resources, alertmanager
    ├── mimir-values.yaml       ← Mimir configuration: S3, resources
    ├── alertmanager-values.yaml ← Alertmanager standalone (optional)
    └── grafana-values.yaml    ← Grafana configuration: datasources, ingress
```

Each script in `scripts/` can be run standalone or via `install_all.sh`.
All version pins live in `scripts/lib/common.sh`.

---

## Pre-requisites

| | Detail |
|---|---|
| Instance | t4g.xlarge · 4 vCPU / 16 GB · Debian 12 ARM64 · fresh install |
| IAM role | EC2 instance role with S3 access (policy below) |
| S3 bucket | Base name you provide (e.g., `lgtm-observability`) |
| Security group | Ports 22, 80, 443 open inbound |
| DNS | A record: `grafana.yourdomain.com` → EC2 public IP |

**S3 Bucket Naming:**
When you provide a base bucket name (e.g., `lgtm-observability`), the installer creates separate buckets for each component:
- `lgtm-observability-loki-data` - Loki logs
- `lgtm-observability-tempo-data` - Tempo traces
- `lgtm-observability-mimir-data` - Mimir metrics (blocks)
- `lgtm-observability-mimir-data-alertmanager` - Mimir alertmanager state
- `lgtm-observability-mimir-data-ruler` - Mimir ruler rules
- `lgtm-observability-grafana-data` - Grafana dashboards/datasources

**IAM Policy (attach to EC2 instance role):**
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
# Interactive mode (will prompt for S3 bucket after Phase 4)
sudo bash install_all.sh

# Non-interactive mode (skip all prompts)
sudo bash install_all.sh -y

# With S3 configuration via flags
sudo bash install_all.sh --bucket-name lgtm-observability --bucket-region us-east-1 -y

# Shorthand
sudo bash install_all.sh -b lgtm-observability -r us-east-1 -y

# With environment variables
S3_BUCKET=lgtm-observability S3_REGION=us-east-1 sudo -E bash install_all.sh -y

# With custom Grafana password
GRAFANA_ADMIN_PASSWORD="strong-password" sudo bash install_all.sh -y
```

### 4 — Upgrade components
```bash
# Upgrade k0s
UPGRADE=true sudo bash scripts/install_k0s.sh

# Redeploy LGTM (after editing values files)
SKIP_K0S=true SKIP_HAPROXY=true SKIP_SECRETS=true SKIP_BACKUP=true sudo bash install_all.sh

# Upgrade specific component
helm upgrade --install loki grafana-community/loki \
  --namespace monitoring \
  --version 6.53.0 \
  --values values/loki-values.yaml
```

### 5 — Help
```bash
sudo bash install_all.sh --help
```

---

## Running Scripts Individually

Every script in `scripts/` is fully standalone:

```bash
# Run each phase separately (in order)
sudo bash scripts/install_k0s.sh
sudo bash scripts/install_HAproxy.sh
sudo bash scripts/install_secrets.sh
sudo bash scripts/install_LGTM.sh

# Backup (optional)
sudo bash scripts/backup_all.sh
```

### Resume after failure

If `install_all.sh` fails partway, fix the issue and skip completed phases:

```bash
# Example: failed at Phase 4 — skip 1, 2, and 3
SKIP_K0S=true SKIP_HAPROXY=true SKIP_SECRETS=true sudo bash install_all.sh

# Re-deploy LGTM only (e.g. after editing values files)
SKIP_K0S=true SKIP_HAPROXY=true SKIP_SECRETS=true SKIP_BACKUP=true \
    sudo bash install_all.sh
```

Available flags: `SKIP_K0S` `SKIP_HAPROXY` `SKIP_SECRETS` `SKIP_LGTM` `SKIP_BACKUP`

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         External                                │
│   Browser → https://grafana.yourdomain.com                     │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  HAproxy Ingress (hostNetwork :80/:443)                        │
└──────────────────────────┬──────────────────────────────────────┘
                           │
           ┌───────────────┼───────────────┐
           ▼               ▼               ▼
    ┌──────────┐    ┌──────────┐    ┌──────────┐
    │ Grafana  │    │  Loki    │    │  Tempo   │
    │   :3000  │    │   :3100  │    │   :3200  │
    └────┬─────┘    └────┬─────┘    └────┬─────┘
         │               │               │
         └───────────────┼───────────────┘
                         ▼
                  ┌────────────┐
                  │   Mimir    │
                  │  :80/metrics (gateway)
                  │  :80/alertmanager
                  └────────────┘

┌─────────────────────────────────────────────────────────────────┐
│  S3 Storage (persistent data)                                  │
│  - loki-data, tempo-data, mimir-data                           │
│  - mimir-data-alertmanager, mimir-data-ruler                   │
└─────────────────────────────────────────────────────────────────┘
```

---

## Grafana Datasources

The stack comes pre-configured with these datasources:

| Datasource | URL | Purpose |
|---|---|---|
| Mimir | `http://mimir-gateway.monitoring.svc.cluster.local:80/prometheus` | Metrics (Prometheus-compatible) |
| Loki | `http://loki.monitoring.svc.cluster.local:3100` | Logs |
| Tempo | `http://tempo.monitoring.svc.cluster.local:3200` | Traces |
| Alertmanager | `http://mimir-gateway.monitoring.svc.cluster.local:80/alertmanager` | Alert management |

---

## Backup

All versions are in `scripts/lib/common.sh`. Bump deliberately.

| Component | Version |
|---|---|
| k0s | v1.34.3+k0s.0 |
| Helm | v3.17.1 |
| HAproxy Ingress chart | 1.48.0 |
| Linkerd | stable-2.14.11 |
| cert-manager | v1.17.1 |
| Loki chart | 6.53.0 |
| Tempo chart | 1.24.4 |
| Mimir chart | 6.0.5 |
| Grafana chart | 10.5.15 |

---

## Backup

Backup LGTM data to S3:
```bash
sudo bash scripts/backup_all.sh
```

---

## Troubleshooting

```bash
# ── k0s ─────────────────────────────────────────────────────────────
# k0s not starting
journalctl -u k0scontroller -n 100 --no-pager

# Check k0s status
k0s status
k0s kubectl get nodes

# ── Pods ─────────────────────────────────────────────────────────────
# List all pods
kubectl get pods -n monitoring -o wide

# Pod stuck Pending/CrashLoopBackOff
kubectl describe pod <name> -n monitoring
kubectl logs <pod> -n monitoring --previous

# Check specific component logs
kubectl logs -n monitoring loki-0
kubectl logs -n monitoring tempo-0
kubectl logs -n monitoring mimir-compactor-0
kubectl logs -n monitoring mimir-alertmanager-0
kubectl logs -n monitoring -l app.kubernetes.io/name=grafana

# ── Storage ───────────────────────────────────────────────────────────
# Check PVC status
kubectl get pvc -n monitoring

# Check StorageClass
kubectl get sc

# ── Helm ─────────────────────────────────────────────────────────────
# List helm releases
helm list -n monitoring

# Debug helm upgrade
helm upgrade --install <release> <chart> \
  --namespace monitoring \
  --values values/<values>.yaml \
  --dry-run --debug

# Rollback helm release
helm rollback <release> -n monitoring

# ── Networking ────────────────────────────────────────────────────────
# HAproxy not routing
kubectl logs -n kube-system -l app.kubernetes.io/name=kubernetes-ingress

# Test service connectivity from within cluster
kubectl run test --rm -it --image=busybox --restart=Never -- \
  wget -qO- http://loki.monitoring.svc.cluster.local:3100/ready

# Port-forward to Grafana
kubectl port-forward -n monitoring svc/grafana 3000:3000

# ── S3 ───────────────────────────────────────────────────────────────
# Check S3 bucket exists
aws s3 ls | grep lgtm

# Verify IAM permissions
aws s3 cp test.txt s3://<bucket>/test.txt
```
