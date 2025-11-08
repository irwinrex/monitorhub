# Grafana LGTM Stack with Alloy (Bearer Token Authentication)

Complete setup guide for deploying Grafana, Loki, Mimir, Tempo (LGTM) with Grafana Alloy on Kubernetes with bearer token authentication.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    Applications/Services                     │
│  (Django, Python, Go, etc. with OpenTelemetry SDK)          │
└────────────────┬────────────────────────────────────────────┘
                 │
                 │ Authorization: Bearer <token>
                 │ POST /observability/v1/{logs,metrics,traces}
                 ↓
         ┌───────────────────────────┐
         │  AWS ALB or HAProxy        │
         │  /observability (prefix)   │
         └─────────┬─────────────────┘
                   │
                   ↓
         ┌──────────────────────┐
         │  Grafana Alloy       │
         │  (Bearer Token Auth) │
         │  Verifies token ✓    │
         └──────────┬───────────┘
                    │
        ┌───────────┼───────────┐
        ↓           ↓           ↓
      Loki       Mimir       Tempo
    (no auth)   (no auth)   (no auth)
        │           │           │
        └───────────┼───────────┘
                    ↓
            ┌──────────────────┐
            │     Grafana      │
            │  (Visualize)     │
            └──────────────────┘
```

## Features

- ✅ **Bearer Token Authentication** on Alloy receiver to verify genuine requests
- ✅ **No authentication** on backends (Loki, Mimir, Tempo) for simplicity
- ✅ **Multiple Ingress Options**: HAProxy, AWS ALB, or Kubernetes Ingress
- ✅ **NodePort Access** for direct Kubernetes access
- ✅ **Kubernetes service discovery** for auto-scraping pods
- ✅ **OTLP receiver** (gRPC on 4317 + HTTP on 4318) for application telemetry
- ✅ **Dual Protocol Support**: Both gRPC and HTTP with bearer tokens
- ✅ **Batch processing** for efficient data export

## Components

| Component | Purpose | Authentication | Port |
|-----------|---------|-----------------|------|
| **Alloy Receiver** | Accepts logs, metrics, traces from apps | ✅ Bearer Token | 4317/4318 |
| **Alloy Exporters** | Sends data to backends | ❌ No auth | - |
| **Loki** | Log aggregation | ❌ No auth | 3100 |
| **Mimir** | Metrics storage | ❌ No auth | 8080 |
| **Tempo** | Distributed tracing | ❌ No auth | 4317 |
| **Grafana** | Visualization | ✅ UI only | 3000 |

## Request Routing

All requests are routed based on path matching:

| Request | Matches | Backend | Receives | Status |
|---------|---------|---------|----------|--------|
| `http://host/observability/v1/logs` | `/observability` | Alloy:4318 | `/v1/logs` | ✅ Works |
| `http://host/observability/v1/metrics` | `/observability` | Alloy:4318 | `/v1/metrics` | ✅ Works |
| `http://host/observability/v1/traces` | `/observability` | Alloy:4318 | `/v1/traces` | ✅ Works |
| `http://host/grafana` | `/` | Grafana:3000 | `/grafana` | ✅ Works |
| `http://host/` | `/` | Grafana:3000 | `/` | ✅ Works |

## Access Methods

### Option 1: Via NodePort (Kubernetes Internal)

| Service | Port | NodePort | Access |
|---------|------|----------|--------|
| **Alloy gRPC** | 4317 | 30317 | `grpc://node-ip:30317` |
| **Alloy HTTP** | 4318 | 30318 | `http://node-ip:30318` ✅ Recommended |
| **Grafana** | 3000 | 30300 | `http://node-ip:30300` |
| **Loki** | 3100 | 30100 | `http://node-ip:30100` |
| **Mimir** | 8080 | 30080 | `http://node-ip:30080` |
| **Tempo** | 4317 | 30317 | `http://node-ip:30317` |

### Option 2: Via HAProxy Ingress (Path-based Routing)

```
http://ingress-host/observability/v1/logs
http://ingress-host/observability/v1/metrics
http://ingress-host/observability/v1/traces
http://ingress-host/grafana
http://ingress-host/
```

### Option 3: Via AWS ALB (Recommended for AWS)

```
https://alb.example.com/observability/v1/logs
https://alb.example.com/grafana
https://alb.example.com/
```

## Prerequisites

- Kubernetes cluster (1.28+)
- kubectl installed
- **Choose ONE ingress controller**:
  - HAProxy Ingress Controller (for on-premise/k0s)
  - AWS ALB Controller (for AWS EKS)
  - Kubernetes Ingress (default)
- k0s or similar lightweight Kubernetes distribution (recommended)

## Installation

### 1. Create Monitoring Namespace

```bash
kubectl create namespace monitoring
```

### 2. Deploy Loki

```bash
kubectl apply -f - << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-config
  namespace: monitoring
data:
  local-config.yaml: |
    auth_enabled: false
    ingester:
      chunk_idle_period: 3m
      max_chunk_age: 1h
    limits_config:
      reject_old_samples: true
      reject_old_samples_max_age: 720h

---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: loki
  namespace: monitoring
spec:
  serviceName: loki
  replicas: 1
  selector:
    matchLabels:
      app: loki
  template:
    metadata:
      labels:
        app: loki
    spec:
      containers:
      - name: loki
        image: grafana/loki:latest
        ports:
        - containerPort: 3100
        volumeMounts:
        - name: config
          mountPath: /etc/loki
        - name: storage
          mountPath: /loki
      volumes:
      - name: config
        configMap:
          name: loki-config
      - name: storage
        emptyDir: {}

---
apiVersion: v1
kind: Service
metadata:
  name: loki-service
  namespace: monitoring
spec:
  selector:
    app: loki
  ports:
  - name: loki
    port: 3100
    targetPort: 3100
    nodePort: 30100
  type: NodePort
EOF
```

### 3. Deploy Mimir

```bash
kubectl apply -f - << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: mimir-config
  namespace: monitoring
data:
  mimir.yaml: |
    auth_enabled: false
    ingester:
      max_global_series_per_user: 10000
      max_global_exemplars_per_user: 10000

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mimir
  namespace: monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mimir
  template:
    metadata:
      labels:
        app: mimir
    spec:
      containers:
      - name: mimir
        image: grafana/mimir:latest
        args:
        - -config.file=/etc/mimir/mimir.yaml
        ports:
        - containerPort: 8080
        volumeMounts:
        - name: config
          mountPath: /etc/mimir
      volumes:
      - name: config
        configMap:
          name: mimir-config

---
apiVersion: v1
kind: Service
metadata:
  name: mimir-service
  namespace: monitoring
spec:
  selector:
    app: mimir
  ports:
  - name: mimir
    port: 8080
    targetPort: 8080
    nodePort: 30080
  type: NodePort
EOF
```

### 4. Deploy Tempo

```bash
kubectl apply -f - << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: tempo-config
  namespace: monitoring
data:
  tempo.yaml: |
    server:
      http_listen_port: 4317
    distributor:
      rate_limit_bytes: 10000000
    ingester:
      traces:
        max_trace_idle: 10s
    storage:
      trace:
        backend: local
        local:
          path: /var/tempo/traces

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tempo
  namespace: monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: tempo
  template:
    metadata:
      labels:
        app: tempo
    spec:
      containers:
      - name: tempo
        image: grafana/tempo:latest
        ports:
        - containerPort: 4317
        volumeMounts:
        - name: config
          mountPath: /etc/tempo
        - name: storage
          mountPath: /var/tempo
      volumes:
      - name: config
        configMap:
          name: tempo-config
      - name: storage
        emptyDir: {}

---
apiVersion: v1
kind: Service
metadata:
  name: tempo-service
  namespace: monitoring
spec:
  selector:
    app: tempo
  ports:
  - name: tempo
    port: 4317
    targetPort: 4317
    nodePort: 30317
  type: NodePort
EOF
```

### 5. Deploy Grafana Alloy with Bearer Token Auth

```bash
kubectl apply -f - << 'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: alloy-auth
  namespace: monitoring
type: Opaque
stringData:
  ALLOY_RECEIVER_TOKEN: "your-secret-token-12345"

---
apiVersion: v1
kind: ConfigMap
metadata:
  name: alloy-config
  namespace: monitoring
data:
  config.alloy: |
    logging {
      level  = "info"
      format = "logfmt"
    }

    discovery.kubernetes "pods" {
      role = "pod"
    }

    prometheus.scrape "default" {
      targets = discovery.kubernetes.pods.targets
      forward_to = [prometheus.remote_write.mimir.receiver]
    }

    prometheus.remote_write "mimir" {
      endpoint {
        url = "http://mimir-service.monitoring.svc.cluster.local:8080/api/v1/push"
      }
    }

    loki.source.kubernetes "pods" {
      targets = discovery.kubernetes.pods.targets
      forward_to = [loki.write.loki.receiver]
    }

    loki.write "loki" {
      endpoint {
        url = "http://loki-service.monitoring.svc.cluster.local:3100/loki/api/v1/push"
      }
    }

    otelcol.auth.bearer "receiver_token" {
      token = env("ALLOY_RECEIVER_TOKEN")
    }

    otelcol.receiver.otlp "default" {
      grpc {
        endpoint = "0.0.0.0:4317"
        auth = otelcol.auth.bearer.receiver_token.handler
      }
      http {
        endpoint = "0.0.0.0:4318"
        auth = otelcol.auth.bearer.receiver_token.handler
      }

      output {
        metrics = [otelcol.processor.batch.default.input]
        logs    = [otelcol.processor.batch.default.input]
        traces  = [otelcol.processor.batch.default.input]
      }
    }

    otelcol.processor.batch "default" {
      send_batch_size = 2000
      send_batch_max_size = 3000
      timeout = "10s"
      
      output {
        metrics = [otelcol.exporter.otlphttp.mimir.input]
        logs    = [otelcol.exporter.loki.default.input]
        traces  = [otelcol.exporter.otlp.tempo.input]
      }
    }

    otelcol.exporter.otlphttp "mimir" {
      client {
        endpoint = "http://mimir-service.monitoring.svc.cluster.local:8080"
      }
    }

    otelcol.exporter.loki "default" {
      forward_to = [loki.write.loki.receiver]
    }

    otelcol.exporter.otlp "tempo" {
      client {
        endpoint = "http://tempo-service.monitoring.svc.cluster.local:4317"
        tls {
          insecure = true
        }
      }
    }

---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: grafana-alloy
  namespace: monitoring

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: grafana-alloy
rules:
  - apiGroups: [""]
    resources: ["pods", "nodes", "namespaces", "endpoints", "services"]
    verbs: ["get", "list", "watch"]

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: grafana-alloy
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: grafana-alloy
subjects:
  - kind: ServiceAccount
    name: grafana-alloy
    namespace: monitoring

---
apiVersion: v1
kind: Service
metadata:
  name: alloy-service
  namespace: monitoring
spec:
  selector:
    app: alloy
  ports:
    - name: http
      port: 12345
      targetPort: 12345
      nodePort: 30345
    - name: otlp-grpc
      port: 4317
      targetPort: 4317
      nodePort: 30317
    - name: otlp-http
      port: 4318
      targetPort: 4318
      nodePort: 30318
  type: NodePort

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: alloy-deployment
  namespace: monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: alloy
  template:
    metadata:
      labels:
        app: alloy
    spec:
      serviceAccountName: grafana-alloy
      containers:
        - name: alloy
          image: grafana/alloy:v1.11.0
          args:
            - run
            - /etc/alloy/config.alloy
            - --server.http.listen-addr=0.0.0.0:12345
            - --storage.path=/var/lib/alloy/data
          ports:
            - name: http
              containerPort: 12345
            - name: otlp-grpc
              containerPort: 4317
            - name: otlp-http
              containerPort: 4318
          envFrom:
            - secretRef:
                name: alloy-auth
          volumeMounts:
            - name: config
              mountPath: /etc/alloy
            - name: alloy-data
              mountPath: /var/lib/alloy/data
          livenessProbe:
            httpGet:
              path: /-/healthy
              port: 12345
            initialDelaySeconds: 30
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /-/ready
              port: 12345
            initialDelaySeconds: 10
            periodSeconds: 5
      volumes:
        - name: config
          configMap:
            name: alloy-config
        - name: alloy-data
          emptyDir: {}
EOF
```

### 6. Deploy Grafana

```bash
kubectl apply -f - << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grafana
  namespace: monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: grafana
  template:
    metadata:
      labels:
        app: grafana
    spec:
      containers:
      - name: grafana
        image: grafana/grafana:latest
        ports:
        - containerPort: 3000
        env:
        - name: GF_SECURITY_ADMIN_PASSWORD
          value: "admin"
        - name: GF_SERVER_ROOT_URL
          value: "http://localhost/grafana"
        - name: GF_SERVER_SERVE_FROM_SUB_PATH
          value: "true"

---
apiVersion: v1
kind: Service
metadata:
  name: grafana-service
  namespace: monitoring
spec:
  selector:
    app: grafana
  ports:
  - name: grafana
    port: 3000
    targetPort: 3000
    nodePort: 30300
  type: NodePort
EOF
```

### 7A. Deploy HAProxy Ingress (Option for On-Premise)

```bash
kubectl apply -f - << 'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: monitoring-ingress
  namespace: monitoring
  annotations:
    kubernetes.io/ingress.class: haproxy
    haproxy.org/ssl-redirect: "false"
spec:
  ingressClassName: haproxy
  rules:
    - http:
        paths:
          - path: /observability
            pathType: Prefix
            backend:
              service:
                name: alloy-service
                port:
                  number: 4318

          - path: /grafana
            pathType: Prefix
            backend:
              service:
                name: grafana-service
                port:
                  number: 3000

          - path: /
            pathType: Prefix
            backend:
              service:
                name: grafana-service
                port:
                  number: 3000
EOF
```

### 7B. Deploy AWS ALB Ingress (Option for AWS EKS)

```bash
kubectl apply -f - << 'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: monitoring-ingress
  namespace: monitoring
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}]'
spec:
  rules:
    - http:
        paths:
          - path: /observability
            pathType: Prefix
            backend:
              service:
                name: alloy-service
                port:
                  number: 4318

          - path: /
            pathType: Prefix
            backend:
              service:
                name: grafana-service
                port:
                  number: 3000
EOF
```

## Usage

### Option 1: Send via NodePort (HTTP Recommended)

```bash
TOKEN="your-secret-token-12345"
NODE_IP="<your-node-ip>"

curl -H "Authorization: Bearer $TOKEN" \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{
    "resourceLogs": [
      {
        "resource": {
          "attributes": [
            {"key": "service.name", "value": {"stringValue": "django-app"}}
          ]
        },
        "scopeLogs": [
          {
            "logRecords": [
              {
                "timeUnixNano": "'$(date +%s)'000000000",
                "body": {"stringValue": "Application log message"}
              }
            ]
          }
        ]
      }
    ]
  }' \
  http://$NODE_IP:30318/v1/logs
```

### Option 2: Send via Ingress

```bash
TOKEN="your-secret-token-12345"
INGRESS_HOST="monitoring.example.com"

curl -H "Authorization: Bearer $TOKEN" \
  -X POST \
  -H "Content-Type: application/json" \
  -d '...' \
  http://$INGRESS_HOST/observability/v1/logs
```

### Django Application Integration

```python
import os
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter

# Configuration
ALLOY_ENDPOINT = os.getenv(
    "ALLOY_ENDPOINT",
    "http://node-ip:30318"
)

ALLOY_TOKEN = os.getenv(
    "ALLOY_RECEIVER_TOKEN",
    "your-secret-token-12345"
)

# Setup OTLP Exporter with Bearer Token
otlp_exporter = OTLPSpanExporter(
    endpoint=ALLOY_ENDPOINT,
    headers={"Authorization": f"Bearer {ALLOY_TOKEN}"},
    insecure=True
)
```

## Protocol Comparison

| Protocol | Use Case | Endpoint | Performance |
|----------|----------|----------|-------------|
| **HTTP** | ✅ Recommended for Django | `http://node-ip:30318` | Good, easier debugging |
| **gRPC** | High-throughput services | `grpc://node-ip:30317` | Better, binary protocol |

## Verification

### Check Alloy Health

```bash
kubectl exec -n monitoring deployment/alloy-deployment -- curl -s http://localhost:12345/-/ready
```

### Check Loki Health

```bash
kubectl exec -n monitoring statefulset/loki -- curl -s http://localhost:3100/ready
```

### Query Logs in Grafana

1. Port-forward to Grafana:
```bash
kubectl port-forward -n monitoring svc/grafana-service 3000:3000 &
```

2. Open http://localhost:3000 (username: admin, password: admin)

3. Add Loki data source:
   - URL: http://loki-service.monitoring.svc.cluster.local:3100

4. Go to Explore and query: `{service_name="django-app"}`

## Security Notes

- ✅ Bearer tokens verify genuine requests
- ✅ Tokens stored in Kubernetes Secrets
- ✅ HTTPS recommended for production (use cert-manager)
- ✅ Network policies recommended to restrict access
- ✅ RBAC limits Alloy to read-only pod access

## Troubleshooting

### 401 Unauthorized on Logs

Check token in request matches Secret:
```bash
kubectl get secret -n monitoring alloy-auth -o yaml
```

### Logs Not Appearing

Check Alloy logs:
```bash
kubectl logs -n monitoring deployment/alloy-deployment -f
```

### Ingress Not Routing

Verify ingress configuration:
```bash
kubectl describe ingress -n monitoring monitoring-ingress
```

## License

MIT

## Support

For issues or questions, refer to:
- [Grafana Alloy Documentation](https://grafana.com/docs/alloy/latest/)
- [LGTM Stack Guide](https://grafana.com/docs/grafana-cloud/send-data/otlp/)
- [Kubernetes Ingress Documentation](https://kubernetes.io/docs/concepts/services-networking/ingress/)
