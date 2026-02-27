# LGTM Stack — Deployment Guide
## k0s · Single Node · t4g.xlarge · Debian 12 ARM64 · HAProxy · mTLS

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
│   ├── install_HAProxy.sh      ← Phase 2: HAProxy Ingress Controller
│   ├── install_mTLS.sh         ← Phase 3: cert-manager + PKI + 6 certs
│   ├── install_secrets.sh      ← Phase 4: Grafana admin secret
│   ├── install_LGTM.sh         ← Phase 5: Loki + Tempo + Mimir + Grafana
│   └── backup_all.sh           ← Backup LGTM data to S3
│
└── values/
    ├── haproxy-values.yaml     ← HAProxy Ingress configuration
    ├── ingress-values.yaml     ← IngressClass configuration
    ├── loki-values.yaml        ← Loki configuration: S3, resources
    ├── tempo-values.yaml       ← Tempo configuration: S3, resources
    ├── mimir-values.yaml       ← Mimir configuration: S3, resources
    └── grafana-values.yaml     ← Grafana configuration: datasources, ingress
```

Each script in `scripts/` can be run standalone or via `install_all.sh`.
All version pins live in `scripts/lib/common.sh`.

---

## Pre-requisites

| | Detail |
|---|---|
| Instance | t4g.xlarge · 4 vCPU / 16 GB · Debian 12 ARM64 · fresh install |
| IAM role | EC2 instance role with S3 access (policy below) |
| S3 bucket | `lgtm-observability` in your region |
| Security group | Ports 22, 80, 443 open inbound |
| DNS | A record: `grafana.yourdomain.com` → EC2 public IP |

**IAM Policy (attach to EC2 instance role):**
```json
{
  "Effect": "Allow",
  "Action": ["s3:GetObject","s3:PutObject","s3:DeleteObject","s3:ListBucket"],
  "Resource": [
    "arn:aws:s3:::lgtm-observability",
    "arn:aws:s3:::lgtm-observability/*"
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

### 2 — Set your domain, region, and S3 bucket
```bash
DOMAIN="grafana.yourdomain.com"
REGION="us-east-1"
S3_BUCKET="lgtm-observability"

# Replace in all files that reference them
sed -i "s/grafana.example.com/${DOMAIN}/g" \
    values/*.yaml scripts/install_mTLS.sh

sed -i "s/us-east-1/${REGION}/g" \
    values/*.yaml

sed -i "s/\${S3_BUCKET}/${S3_BUCKET}/g" \
    values/*.yaml

sed -i "s/\${S3_REGION}/${REGION}/g" \
    values/*.yaml
```

### 3 — Make executable
```bash
chmod +x install_all.sh scripts/*.sh
```

### 4 — Full install
```bash
sudo bash install_all.sh

# Or with a custom Grafana password
GRAFANA_ADMIN_PASSWORD="strong-password" sudo -E bash install_all.sh
```

---

## Running Scripts Individually

Every script in `scripts/` is fully standalone:

```bash
# Run each phase separately (in order)
sudo bash scripts/install_k0s.sh
sudo bash scripts/install_HAProxy.sh
sudo bash scripts/install_mTLS.sh
sudo bash scripts/install_secrets.sh
sudo bash scripts/install_LGTM.sh
```

### Resume after failure

If `install_all.sh` fails partway, fix the issue and skip completed phases:

```bash
# Example: failed at Phase 3 — skip 1 and 2
SKIP_K0S=true SKIP_HAPROXY=true sudo bash install_all.sh

# Re-deploy LGTM only (e.g. after editing values files)
SKIP_K0S=true SKIP_HAPROXY=true SKIP_MTLS=true SKIP_SECRETS=true \
    sudo bash install_all.sh
```

Available flags: `SKIP_K0S` `SKIP_HAPROXY` `SKIP_MTLS` `SKIP_SECRETS` `SKIP_LGTM`

---

## mTLS Architecture

```
Browser / Client
      │  HTTPS ( AWS ALB )  
      ▼
HAProxy Ingress  (hostNetwork :80)
      │  HTTP 
      ▼
Grafana pod      (gRPC 9100/ALWAYS_AUTHENTICATE)
      │
      ├──▶  Loki   :9095  gRPC  RequireAndVerifyClientCert
      │                   (write/read logs)
      │
      ├──▶  Tempo  :9096 gRPC  RequireAndVerifyClientCert
      │                   (query traces)
      │
      └──▶  Mimir  :9095 gRPC  RequireAndVerifyClientCert
                        (query/metric storage)

OTLP receivers (Tempo):
  :4317 gRPC  — full mTLS  (apps must present a cert signed by lgtm-root-ca)
  :4318 HTTP  — TLS only   (no client cert, easier for SDK migration)

External Clients (Promtail, Agents):
  ─────────────────────────────────────
  Write logs/traces/metrics to LGTM
  All connections use mTLS verified against lgtm-root-ca-secret
```

---

## Cert Operations

```bash
# Check all certs (all should be Ready=True)
kubectl get certificates -n monitoring

# Force immediate renewal (cert-manager re-issues within seconds)
kubectl delete secret loki-tls-secret -n monitoring

# Export root CA for browser/OS trust
kubectl get secret lgtm-root-ca-secret -n monitoring \
    -o jsonpath='{.data.ca\.crt}' | base64 -d > lgtm-root-ca.crt

# Import — macOS
sudo security add-trusted-cert -d -r trustRoot \
    -k /Library/Keychains/System.keychain lgtm-root-ca.crt

# Import — Debian/Ubuntu
sudo cp lgtm-root-ca.crt /usr/local/share/ca-certificates/
sudo update-ca-certificates
```

---

## Version Pins

All versions are in `scripts/lib/common.sh`. Bump deliberately.

| Component | Version |
|---|---|
| k0s | v1.34.3+k0s.0 |
| Helm | v3.17.1 |
| HAProxy Ingress chart | 1.48.0 |
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
# k0s not starting
journalctl -u k0scontroller -n 100 --no-pager

# Pod stuck Pending/CrashLoopBackOff
kubectl describe pod <name> -n monitoring
kubectl logs <pod> -n monitoring --previous

# Cert not issuing
kubectl describe certificaterequest -n monitoring

# Grafana datasource TLS errors
kubectl logs -n monitoring -l app.kubernetes.io/name=grafana | grep -i tls

# HAProxy not routing
kubectl logs -n kube-system -l app.kubernetes.io/name=kubernetes-ingress
```
