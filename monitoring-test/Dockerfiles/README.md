# Monitoring Test Project

Django application with Docker container logging via Grafana Alloy to Loki.

## Prerequisites

- Docker
- Docker Compose
- Grafana with Loki datasource configured

## Quick Start

1. Copy `.env.sample` to `.env` and configure:

```bash
cp .env.sample .env
```

2. Update the following variables in `.env`:
   - `ALLOY_SERVICE_NAMES` - Your service name(s) for filtering logs (pipe-separated for multiple)
   - `ALLOY_ENVIRONMENT` - Environment (e.g., local, staging, prod)
   - `ALLOY_LOKI_URL` - Your Loki push endpoint
   - `ALLOY_AUTH_USERNAME` - Loki username
   - `ALLOY_AUTH_PASSWORD` - Loki password

3. Start the containers:

```bash
docker compose up -d
```

## Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `APP_PORT` | Application port | 8000 |
| `APP_NAME` | Container name | python-app |
| `ALLOY_SERVICE_NAMES` | Service name(s) for logs (pipe-separated) | app |
| `ALLOY_ENVIRONMENT` | Environment label | local |
| `ALLOY_LOKI_URL` | Loki push endpoint | - |
| `ALLOY_LOG_LEVEL` | Alloy log level | info |
| `LOG_LEVEL` | Application log level | INFO |

### Alloy Configuration

The Alloy config (`test/alloy/config.alloy`) automatically:
- Discovers Docker containers by compose service name
- Filters logs using `ALLOY_SERVICE_NAMES` (supports pipe-separated values, e.g., `app|db|worker`)
- Adds `service` and `environment` labels to all logs
- Ships logs to Loki
- **Both `ALLOY_SERVICE_NAMES` and `ALLOY_ENVIRONMENT` are required**

### Dashboard

Import `grafana-dashboards/dashboard-loki.json` into Grafana for:
- Total logs count
- 4XX error count
- 5XX error count
- 2XX success count
- Log volume over time
- Recent 4XX/5XX errors
- All logs view

## API Endpoints

- `GET /api/200/` - Returns 200 OK
- `GET /api/503/` - Returns 503 Service Unavailable
- `GET /api/db/` - Database write/read test
- `GET /api/traceback/` - Test error logging

## Stopping

```bash
docker compose down
```
