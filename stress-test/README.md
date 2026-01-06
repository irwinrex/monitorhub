# 🚀 FastAPI Stress Test Service

A lightweight FastAPI app to stress test **CPU** and **RAM** via HTTP endpoints.

---

## 📦 Features

- **`/stress/cpu`** — Burn CPU cores for a specific duration.
- **`/stress/ram`** — Allocate and hold RAM to simulate memory pressure.
- **Dockerized** — Easily deployable with Docker and Compose.
- **Asynchronous Execution** — Non-blocking stress routines via threads.

---

## 🔧 Endpoints

### 🔥 CPU Stress

GET /stress/cpu?cores=<num>&duration=<seconds>


- `cores` (required): Number of CPU cores to stress.
- `duration` (optional): Duration in seconds (default: 30).

**Example:**

http://localhost:8000/stress/cpu?cores=2&duration=60


---

### 🧠 RAM Stress

GET /stress/ram?gb=<num>&duration=<seconds>


- `gb` (required): GBs of RAM to allocate.
- `duration` (optional): Duration in seconds (default: 30).

**Example:**

http://localhost:8000/stress/ram?gb=4&duration=60


---

## 🐳 Docker Setup

### Build & Run

```bash
docker compose up --build
Ports
Exposes port 8000

📝 File Structure
.
├── main.py              # FastAPI app
├── requirements.txt     # Python dependencies
├── Dockerfile           # Container build file
├── docker-compose.yaml  # Multi-container orchestration
└── README.md            # Documentation
🚨 Notes
Ensure Docker memory/CPU limits are higher than the stress values requested.

App uses threads to avoid blocking FastAPI event loop.

Large memory allocations can crash the container if not limited via docker-compose.

📈 Optional Enhancements
🔍 Add Prometheus + Grafana for live container metrics.

🔬 Use Locust or k6 for endpoint load benchmarking.

🔐 Add authentication, rate-limiting, or IP allow-lists for shared environments.

📄 License
MIT License

Let me know if you want to add:
- Status badges (Docker, Python version, Build passing)
- `.env` support
- Kubernetes manifests or Helm chart
- Auto-deploy via GitHub Actions or GitLab CI
