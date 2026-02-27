# 📮 Message Wall — Kubernetes Developer Demo

A small interactive message wall running on Kubernetes, designed to demonstrate a modern developer workflow with **Rancher Desktop**, **SUSE Application Collection**, **Tilt**, and **Grafana**.

Post messages, delete them, change the accent color — and watch everything update in seconds thanks to Tilt's live_update. Metrics are collected by Prometheus and displayed in a Grafana dashboard, auto-provisioned from code.

## What's in the box

| Component | Purpose |
|---|---|
| **Node.js app** | Message wall with REST API, inline HTML UI, and Prometheus metrics |
| **PostgreSQL** | Persistent storage (installed via Application Collection) |
| **Prometheus** | Metrics scraping (installed via Application Collection) |
| **Grafana** | 8-panel dashboard, auto-provisioned via sidecar + ConfigMap |
| **Tilt** | Inner loop orchestration — build, deploy, live_update, port-forward |
| **Dev Container** | Reproducible coding environment (VS Code) |

## Prerequisites

- [Rancher Desktop](https://rancherdesktop.io) — runtime set to **dockerd (moby)**, Kubernetes enabled
- [Tilt](https://tilt.dev) — installed on the host (`brew install tilt` on macOS)
- [VS Code](https://code.visualstudio.com) with the **Dev Containers** extension
- Access to `dp.apps.rancher.io` (configured automatically by the SUSE Application Collection extension in Rancher Desktop)

## Quick start

```bash
# 1. Clone
git clone https://github.com/fxHouard/Rancher-Developer-Access-Demo.git
cd Rancher-Developer-Access-Demo

# 2. Install infrastructure (one time only, via Rancher Desktop UI):
#
#    PostgreSQL  → Application Collection tab → search PostgreSQL → Install
#                  auth.username: demo / auth.password: demo / auth.database: demo
#
#    Or via CLI:
#    helm install demo-db oci://dp.apps.rancher.io/charts/postgresql \
#         -f charts/postgresql/values-dev.yaml
#
#    Prometheus  → Application Collection tab → search Prometheus → Install
#
#    Grafana     → Application Collection tab → search Grafana → Install
#                  adminPassword: admin
#                  sidecar.dashboards.enabled: true
#                  sidecar.datasources.enabled: true

# 3. Open in VS Code → "Reopen in Container" when prompted

# 4. In a separate host terminal:
tilt up
```

## URLs

| URL | What |
|---|---|
| [localhost:10350](http://localhost:10350) | Tilt dashboard |
| [localhost:3000](http://localhost:3000) | Message Wall app |
| [localhost:9090](http://localhost:9090) | Prometheus |
| [localhost:3001](http://localhost:3001) | Grafana (admin / admin) |
| [localhost:3001/d/message-wall/](http://localhost:3001/d/message-wall/) | Grafana dashboard (direct link) |

All URLs are also clickable directly from the Tilt dashboard.

## Try it

1. **Post messages** on [localhost:3000](http://localhost:3000) and watch the Grafana dashboard update in real time.
2. **Change the accent color** — edit `ACCENT_COLOR` in `src/server.js` (line 9), save. In ~2 seconds, the UI updates without losing messages. That's `live_update` + `restart_process` in action.
3. **Explore metrics** — visit [localhost:3000/metrics](http://localhost:3000/metrics) to see raw Prometheus metrics. All application metrics are prefixed `app_`.

## Project structure

```
.
├── .devcontainer/          Dev Container (Node.js + VS Code config)
│   ├── Dockerfile
│   └── devcontainer.json
├── src/
│   └── server.js           Application (API + UI + Prometheus metrics)
├── k8s/
│   ├── deployment.yaml     Pod spec with Prometheus annotations + resource limits
│   ├── service.yaml        ClusterIP service
│   └── grafana-dashboard.yaml   8-panel dashboard (auto-provisioned via sidecar)
├── charts/
│   └── postgresql/
│       └── values-dev.yaml Dev values for PostgreSQL Helm chart
├── Dockerfile              Container image (Application Collection base)
├── Tiltfile                Inner loop config (build, deploy, sync, monitoring)
└── package.json
```

## How it works

The **Tiltfile** orchestrates everything:

- Builds the app image locally (no push — Rancher Desktop shares the image store between dockerd and k3s)
- Auto-detects PostgreSQL, Prometheus, and Grafana services by Kubernetes labels
- Deploys the app with dynamic PostgreSQL service name injection
- Sets up port-forwards for all services
- Generates a Prometheus datasource ConfigMap (with the detected Prometheus URL)
- Applies the Grafana dashboard ConfigMap

The **Grafana sidecars** watch for ConfigMaps with specific labels (`grafana_dashboard: "1"`, `grafana_datasource: "1"`) and auto-provision datasources and dashboards — zero manual configuration.

## Documentation

For the full crash course covering the complete Kubernetes developer workflow (Dev Containers, Tilt, mirrord, Testcontainers, Helm, GitOps, security):

👉 **[Developing for Kubernetes with SUSE Rancher Developer Access](docs/developing-for-kubernetes.md)**

