# Message Wall — Kubernetes Developer Demo

A small interactive message wall running on Kubernetes, designed to demonstrate a modern developer inner loop with **Rancher Desktop** and **Tilt**.

Post messages, delete them, change the accent color — and watch everything update in seconds. Metrics are collected by Prometheus and displayed in a Grafana dashboard, auto-provisioned from code. Authentication is handled by Keycloak. CVE scanning with Trivy runs automatically and results are displayed in a dedicated Grafana dashboard.

![Inner Loop and Outer Loop architecture](docs/images/inner-outer-loop.png)

## 1. Install Rancher Desktop

Download and install from [rancherdesktop.io](https://rancherdesktop.io).

Once installed, open Rancher Desktop and configure:

- **Container Engine:** select **dockerd (moby)** (not containerd)
- **Kubernetes:** enabled (default)

Wait for the cluster to be ready (green indicator in the status bar).

## 2. Install Tilt

**macOS:**

```bash
brew install tilt
```

**Linux (SUSE and others):**

```bash
curl -fsSL https://raw.githubusercontent.com/tilt-dev/tilt/master/scripts/install.sh | bash
```

**Windows (PowerShell):**

```powershell
iex ((new-object net.webclient).DownloadString('https://raw.githubusercontent.com/tilt-dev/tilt/master/scripts/install.ps1'))
```

Verify: `tilt version`

## 3. Clone and run

```bash
git clone https://github.com/fxHouard/Rancher-Developer-Access-Demo.git
cd Rancher-Developer-Access-Demo
tilt up
```

Press **Space** to open the Tilt dashboard in your browser.

Tilt will automatically install PostgreSQL, Prometheus, Grafana, Keycloak, and the Message Wall app using public upstream images from Docker Hub and Quay.io. It will then run a Trivy CVE scan and display results in Grafana.

## 4. Explore

From the Tilt dashboard ([localhost:10350](http://localhost:10350)), you have clickable links to:

| Resource | URL | What |
|---|---|---|
| **message-wall** | [localhost:3000](http://localhost:3000) | The Message Wall app |
| **keycloak** | [localhost:8080](http://localhost:8080) | Keycloak (login: admin / admin) |
| **grafana** | [localhost:3001](http://localhost:3001) | Grafana (login: admin / demo) |
| **grafana — Message Wall** | [localhost:3001/d/message-wall/](http://localhost:3001/d/message-wall/) | Message Wall metrics dashboard |
| **grafana — CVE Scan** | [localhost:3001/d/cve-scan/](http://localhost:3001/d/cve-scan/) | CVE scan results dashboard |
| **prometheus** | [localhost:9090](http://localhost:9090) | Prometheus |

**Try it:**

1. Open the **Message Wall** ([localhost:3000](http://localhost:3000)) and post a few messages.
2. Open the **Grafana dashboard** — metrics update in real time (requests/sec, messages count, response time, memory).
3. In `src/server.js`, change the `ACCENT_COLOR` value (line 9), save. In ~2 seconds, the wall color changes without losing messages — that's Tilt's live update in action.
4. Check the **CVE Scan** dashboard to see vulnerabilities found in the public images.

## How it works

The **Tiltfile** orchestrates the developer inner loop:

- Installs PostgreSQL as a StatefulSet (official Docker Hub image)
- Installs Prometheus and Grafana via their official Helm charts
- Builds the app image locally (no push — Rancher Desktop shares the image store between dockerd and k3s)
- Deploys Keycloak from its upstream Quay.io image and configures the realm automatically
- Runs Trivy CVE scans on all deployed images
- Generates Grafana dashboards (8-panel app metrics + CVE scan results)
- Sets up port-forwards and clickable links for all services

## Project structure

```
.
├── src/
│   └── server.js              Application (API + UI + Prometheus metrics)
├── k8s/
│   ├── deployment.yaml        Pod spec with Prometheus annotations
│   ├── service.yaml           ClusterIP service
│   ├── keycloak.yaml          Keycloak Deployment + Service (Quay.io image)
│   ├── postgresql.yaml        PostgreSQL StatefulSet (Docker Hub image)
│   └── shared/
│       ├── grafana-dashboard.yaml       8-panel dashboard (auto-provisioned)
│       ├── grafana-cve-dashboard.yaml   CVE scan results dashboard
│       ├── cve-exporter.yaml            CVE exporter Deployment + Service
│       └── keycloak-realm.json          Realm config (demo user + OAuth client)
├── scripts/
│   ├── setup-keycloak-realm.sh      Keycloak realm import script
│   ├── trivy-scan.sh                Trivy CVE scan (public images)
│   └── cve-exporter.py              CVE results → Prometheus metrics
├── values_yaml/
│   ├── prometheus.yaml        Helm values for Prometheus
│   └── grafana.yaml           Helm values for Grafana
├── Dockerfile                 Container image (public Node.js base)
├── Dockerfile.cve-exporter    CVE exporter image
├── Tiltfile                   Inner loop config (build, deploy, scan, monitor)
├── versions.env               Pinned image versions
├── package.json
└── Rancher Developer Access/  Full comparison demo (see below)
```

## Documentation

For the full crash course covering the complete Kubernetes developer workflow (Dev Containers, Tilt, mirrord, Testcontainers, Helm, GitOps, security):

**[Developing for Kubernetes with SUSE Rancher Developer Access](docs/developing-for-kubernetes.md)**

---

## Rancher Developer Access — CVE Comparison Demo

The `Rancher Developer Access/` subdirectory contains an extended variant of this demo that deploys the entire stack **twice** — once with **SUSE Application Collection** images, once with public upstream images — then scans both variants with Trivy and compares CVE counts side-by-side in a dedicated Grafana dashboard.

This demonstrates the value of **Rancher Developer Access**: fewer CVEs, trusted supply chain, same developer experience.

See **[Rancher Developer Access/README.md](Rancher%20Developer%20Access/README.md)** for details.
