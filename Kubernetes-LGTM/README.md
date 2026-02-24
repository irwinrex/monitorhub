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
│   └── install_LGTM.sh         ← Phase 5: Loki + Tempo + Mimir + Grafana
│
└── values/
    ├── lgtm-values.yaml        ← Base Helm values: S3, resources, ingress
    └── mtls-patch.yaml         ← mTLS overlay: cert mounts, TLS listeners
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
scp -r ./lgtm-stack admin@<EC2-IP>:~/
ssh admin@<EC2-IP>
cd ~/lgtm-stack
```

### 2 — Set your domain and region
```bash
DOMAIN="grafana.yourdomain.com"
REGION="us-east-1"

# Replace in all files that reference them
sed -i "s/grafana.example.com/${DOMAIN}/g" \
    values/lgtm-values.yaml values/mtls-patch.yaml scripts/install_mTLS.sh

sed -i "s/us-east-1/${REGION}/g" \
    values/lgtm-values.yaml values/mtls-patch.yaml
```

### 3 — Make executable
```bash
chmod +x install_all.sh scripts/install_*.sh
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
      │  HTTPS  →  grafana-ingress-tls-secret (server cert)
      ▼
HAProxy Ingress  (hostNetwork :80/:443)
      │  HTTPS + backend cert verification
      ▼
Grafana pod      (presents grafana-client-tls-secret)
      │  mTLS — verified against lgtm-root-ca-secret
      ├──▶  Loki   :3100  RequireAndVerifyClientCert
      ├──▶  Tempo  :3200  RequireAndVerifyClientCert
      └──▶  Mimir Gateway :443  RequireAndVerifyClientCert
                   │  internal gRPC mTLS
                   ├──▶  Ingester     (mimir-ingester-tls-secret)
                   ├──▶  Store-GW     (mimir-gateway-tls-secret)
                   └──▶  Querier      (mimir-gateway-tls-secret)

OTLP receivers (Tempo):
  :4317 gRPC  — full mTLS  (apps must present a cert signed by lgtm-root-ca)
  :4318 HTTP  — TLS only   (no client cert, easier for SDK migration)
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
| k0s | v1.32.2+k0s.0 |
| Helm | v3.17.1 |
| HAProxy Ingress chart | 1.42.2 |
| cert-manager | v1.17.1 |
| Loki chart | 6.29.0 |
| Tempo chart | 1.21.1 |
| Mimir chart | 5.6.0 |
| Grafana chart | 8.9.1 |

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
