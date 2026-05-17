# FastAPI Stress Test Service

A lightweight FastAPI app to stress test **CPU**, **RAM**, and **I/O** via HTTP endpoints.

---

## Endpoints

### Health Check

```
GET /stress/healthcheck
```

Returns service status.

**Example:** `http://localhost:8000/stress/healthcheck`

**Response:**
```json
{"status": "ok"}
```

---

### CPU Stress

```
GET /stress/cpu/{cores}
GET /stress/cpu/{cores}/{t}/{duration}
```

- `cores` (required): Number of CPU cores to stress. Use `2` for 2 cores, or `500m` for 0.5 cores.
- `duration` (optional): Duration in seconds (default: 30).

**Examples:**

```
http://localhost:8000/stress/cpu/2
http://localhost:8000/stress/cpu/4?duration=60
http://localhost:8000/stress/cpu/500m/1/30
```

**Response:**
```json
{"message": "Started CPU stress on 2 core(s) for 30s"}
```

---

### RAM Stress

```
GET /stress/ram/{gb}
GET /stress/ram/{gb}/{t}/{duration}
```

- `gb` (required): Amount of RAM to allocate. Examples: `1`, `2gb`, `512mb`, `1tb`.
- `duration` (optional): Duration in seconds (default: 30).

**Examples:**

```
http://localhost:8000/stress/ram/2
http://localhost:8000/stress/ram/1gb?duration=60
http://localhost:8000/stress/ram/512mb/1/30
```

**Response:**
```json
{"message": "Started RAM stress for 2048MB for 30s"}
```

---

### I/O Stress

```
GET /stress/io/{size}
GET /stress/io/{size}/{t}/{duration}
```

- `size` (required): Size of I/O operations. Examples: `100mb`, `1gb`, `10gb`.
- `duration` (optional): Duration in seconds (default: 30).

**Examples:**

```
http://localhost:8000/stress/io/100mb
http://localhost:8000/stress/io/1gb?duration=60
http://localhost:8000/stress/io/500mb/1/30
```

**Response:**
```json
{"message": "Started I/O stress for 100mb for 30s"}
```

---

### mTLS Test

```
GET /stress/mtls/test
```

Tests mutual TLS authentication. Returns client certificate info if provided.

**Example:** `http://localhost:8000/stress/mtls/test`

**Response (with client cert):**
```json
{
  "status": "ok",
  "mtls_verified": true,
  "client_common_name": "CN=client"
}
```

**Response (without client cert):**
```json
{
  "status": "ok",
  "mtls_verified": false,
  "client_common_name": null
}
```

---

### Secrets Check

```
GET /stress/secrets/check
```

Checks if `/app/secrets.json` exists in the container.

**Example:** `http://localhost:8000/stress/secrets/check`

**Response (file exists):**
```json
{"exists": true}
```

**Response (file not found):**
```json
{"exists": false}
```

---

## Docker Setup

### Build & Run

```bash
cd stress-test/fastapi
docker compose up --build
```

### Ports

- Exposes port `8000`

---

## File Structure

```
stress-test/fastapi/
├── main.py              # FastAPI app
├── requirements.txt    # Python dependencies
├── Dockerfile           # Container build file
├── docker-compose.yml   # Container orchestration
└── README.md           # Documentation
```

---

## Notes

- Ensure Docker memory/CPU limits are higher than the stress values requested.
- App uses threads to avoid blocking FastAPI event loop.
- Large memory allocations can crash the container if not limited via docker-compose.

---

## License

MIT