
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
         ┌───────────────────┐
         │   HAProxy Ingress  │
         │   /observability   │
         └─────────┬─────────┘
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
- ✅ **HAProxy Ingress** with path-based routing for multi-service access
- ✅ **Kubernetes service discovery** for auto-scraping pods
- ✅ **OTLP receiver** (gRPC + HTTP) for application telemetry
- ✅ **Batch processing** for efficient data export

## Components

| Component | Purpose | Authentication |
|-----------|---------|-----------------|
| **Alloy Receiver** | Accepts logs, metrics, traces from apps | ✅ Bearer Token |
| **Alloy Exporters** | Sends data to backends | ❌ No auth |
| **Loki** | Log aggregation | ❌ No auth |
| **Mimir** | Metrics storage | ❌ No auth |
| **Tempo** | Distributed tracing | ❌ No auth |
| **Grafana** | Visualization | ✅ UI only |

## Request Routing

All requests are routed through HAProxy Ingress based on path matching:

| Request | Matches | Backend | Receives | Status |
|---------|---------|---------|----------|--------|
| `http://host/observability/v1/logs` | `/observability` | Alloy:4318 | `/v1/logs` | ✅ Works |
| `http://host/observability/v1/metrics` | `/observability` | Alloy:4318 | `/v1/metrics` | ✅ Works |
| `http://host/observability/v1/traces` | `/observability` | Alloy:4318 | `/v1/traces` | ✅ Works |
| `http://host/grafana` | `/` | Grafana:3000 | `/grafana` | ✅ Works |
| `http://host/` | `/` | Grafana:3000 | `/` | ✅ Works |

## Prerequisites

- Kubernetes cluster (1.28+)
- kubectl installed
- HAProxy Ingress Controller deployed
- k0s or similar lightweight Kubernetes distribution (recommended)

## License

MIT

## Support

For issues or questions, refer to:
- [Grafana Alloy Documentation](https://grafana.com/docs/alloy/latest/)
- [LGTM Stack Guide](https://grafana.com/docs/grafana-cloud/send-data/otlp/)
