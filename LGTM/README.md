
# Tempo Authentication Setup with HAProxy Ingress

This guide covers setting up basic authentication for Tempo using HAProxy Ingress Controller with bcrypt password hashing.

## Prerequisites

- HAProxy Ingress Controller v1.46.0+ installed
- Kubernetes cluster with `kubectl` access
- `htpasswd` tool installed (from `apache2-utils`)
- Tempo deployment running in `monitoring` namespace

## Step 1: Generate bcrypt Password Hash

Generate a bcrypt-hashed password using `htpasswd`:

```bash
htpasswd -c -B auth <username>
```

Replace `<username>` with your desired username (e.g., `admin`).

**Example:**
```bash
htpasswd -c -B auth admin
# Enter password when prompted
# Re-type password to confirm
```

This creates a file named `auth` containing:
```
admin:$2y$05$1234567890abcdefghijklmnop...
```

> **Note:** The `-B` flag uses bcrypt hashing (one-way encryption). Passwords cannot be reversed or decrypted.

## Step 2: Create Kubernetes Secret

Create a Kubernetes Secret from the `auth` file:

```bash
kubectl create secret generic tempo-auth \
  --from-file=auth=./auth \
  -n monitoring
```

**Verify the secret was created:**
```bash
kubectl get secrets -n monitoring | grep tempo-auth
kubectl describe secret tempo-auth -n monitoring
```

## Step 3: Update Ingress Configuration

Add HAProxy authentication annotations to your ingress manifest for the Tempo path:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: monitoring-ingress
  namespace: monitoring
  annotations:
    kubernetes.io/ingress.class: haproxy
    haproxy.org/ssl-redirect: "false"
    haproxy.org/path-rewrite: |
      /loki/(.*) /\1
      /tempo/(.*) /\1
spec:
  ingressClassName: haproxy
  rules:
    - http:
        paths:
          - path: /grafana
            pathType: Prefix
            backend:
              service:
                name: grafana-service
                port:
                  name: grafana

          - path: /loki(/|$)(.*)
            pathType: ImplementationSpecific
            backend:
              service:
                name: loki-service
                port:
                  name: loki

          - path: /tempo(/|$)(.*)
            pathType: ImplementationSpecific
            backend:
              service:
                name: tempo-service
                port:
                  name: tempo
            # Add authentication annotations for Tempo
            annotations:
              haproxy.org/auth-type: "basic"
              haproxy.org/auth-secret: "tempo-auth"

          - path: /mimir
            pathType: Prefix
            backend:
              service:
                name: mimir-service
                port:
                  name: mimir
```

**Key annotations:**
- `haproxy.org/auth-type: "basic"` - Enable HTTP basic authentication
- `haproxy.org/auth-secret: "tempo-auth"` - Reference the Kubernetes secret with credentials

## Step 4: Apply Ingress Configuration

```bash
kubectl apply -f monitoring-ingress.yaml
```

**Verify the ingress was updated:**
```bash
kubectl get ingress -n monitoring
kubectl describe ingress monitoring-ingress -n monitoring
```

## Testing Authentication

### Test without credentials (should fail with 401):

```bash
curl -v http://<ingress-ip>:30080/tempo/ready
# Expected: HTTP/1.1 401 Unauthorized
```

### Test with correct credentials (should succeed with 200):

```bash
curl -v -u admin:<password> http://<ingress-ip>:30080/tempo/ready
# Expected: HTTP/1.1 200 OK
```

Replace `<password>` with the password you entered when running `htpasswd`.

### Test with incorrect credentials (should fail with 401):

```bash
curl -v -u admin:wrongpassword http://<ingress-ip>:30080/tempo/ready
# Expected: HTTP/1.1 401 Unauthorized
```

### Test Tempo API with authentication:

```bash
# Query traces with auth
curl -u admin:<password> http://<ingress-ip>:30080/tempo/api/search

# Send traces with auth
curl -X POST \
  -u admin:<password> \
  -H "Content-Type: application/protobuf" \
  -d @traces.pb \
  http://<ingress-ip>:30080/tempo/api/traces
```

## Using Authentication in Applications

When configuring applications to send traces to Tempo, include basic auth credentials:

```bash
# Example: OpenTelemetry exporter
export OTEL_EXPORTER_OTLP_ENDPOINT="http://admin:<password>@<ingress-ip>:30080/tempo"

# Example: curl trace push
curl -X POST \
  -u admin:<password> \
  -H "Content-Type: application/protobuf" \
  --data-binary @spans.pb \
  http://<ingress-ip>:30080/tempo/api/traces
```

## Troubleshooting

### Secret not found error:

```bash
# Verify secret exists
kubectl get secret tempo-auth -n monitoring -o yaml

# Check if secret name matches in ingress annotations
haproxy.org/auth-secret: "tempo-auth"  # Must match secret name
```

### Authentication not working:

```bash
# Check HAProxy controller logs
kubectl logs -n haproxy-controller -l app.kubernetes.io/name=haproxy-ingress -f

# Verify ingress annotations are applied
kubectl get ingress monitoring-ingress -n monitoring -o yaml | grep -A2 auth
```

### 401 errors on valid credentials:

- Ensure the `auth` file contains the correct username/password hash
- Verify the secret was created with the correct file
- Check ingress path matches `/tempo`

## Security Considerations

- **Bcrypt hashing:** Passwords are one-way encrypted and cannot be reversed
- **HTTPS recommended:** For production, use TLS to encrypt credentials in transit
- **Secret storage:** Kubernetes Secrets are base64 encoded but not encrypted by default. Consider enabling encryption at rest
- **Credential rotation:** Periodically regenerate and update credentials

## Updating Credentials

To change the password:

```bash
# 1. Generate new hash
htpasswd -c -B auth admin

# 2. Delete old secret
kubectl delete secret tempo-auth -n monitoring

# 3. Create new secret
kubectl create secret generic tempo-auth \
  --from-file=auth=./auth \
  -n monitoring

# 4. Restart HAProxy controller to reload secret
kubectl rollout restart deployment/haproxy-kubernetes-ingress -n haproxy-controller
```

## Multiple Users

To add multiple users to the `auth` file:

```bash
# Create initial user
htpasswd -c -B auth admin

# Add additional users (without -c flag)
htpasswd -B auth user2
htpasswd -B auth user3
```

The `auth` file will contain:
```
admin:$2y$05$...
user2:$2y$05$...
user3:$2y$05$...
```

Create the secret with all users:

```bash
kubectl create secret generic tempo-auth \
  --from-file=auth=./auth \
  -n monitoring
```

## References

- [HAProxy Ingress Controller Documentation](https://haproxytech.github.io/kubernetes-ingress/)
- [HAProxy Authentication](https://haproxytech.github.io/kubernetes-ingress/docs/configuration/keys/)
- [Kubernetes Secrets](https://kubernetes.io/docs/concepts/configuration/secret/)
- [Tempo Configuration](https://grafana.com/docs/tempo/latest/configuration/)
