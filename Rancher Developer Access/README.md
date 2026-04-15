# Rancher Developer Access — CVE Comparison (AppCo vs Public Images)

Extended demo that deploys the same application stack **twice** — once with SUSE Application Collection images, once with popular public upstream images — then scans everything with Trivy to compare CVE counts side by side in a Grafana dashboard.

## Architecture

```
┌────────────────────────┬──────────────────────────────────────────┐
│   AppCo Variant        │   Public Variant                         │
│   namespace: default   │   namespace: public                      │
│   (installed via UI)   │   (installed via Tilt/Helm)              │
│                        │                                          │
│ ┌─ PostgreSQL (AppCo)  │ ┌─ PostgreSQL (docker.io/postgres:18)   │
│ ┌─ Prometheus (AppCo)  │ ┌─ Prometheus (prom/prometheus:v3.10.0) │
│ ┌─ Grafana   (AppCo)  │ ┌─ Grafana   (grafana/grafana:12.4.0)  │
│ ┌─ Keycloak  (AppCo)  │ ┌─ Keycloak  (quay.io/keycloak:26.5.4) │
│ ┌─ Message-Wall       │ ┌─ Message-Wall                          │
│   (AppCo Node.js)     │   (docker.io/node:24)                    │
└────────────────────────┴──────────────────────────────────────────┘
        │                          │
        └──── Trivy Scan ──────────┘
             8 apps × 2 variants = 16 images
                    │
                    ▼
        ┌──────────────────────┐
        │   CVE Exporter       │
        │   → Prometheus       │
        │   → Grafana Dashboard│
        └──────────────────────┘
```

## Prerequisites

- **Rancher Desktop** with dockerd (moby) and Kubernetes enabled
- **SUSE Application Collection** extension installed
- **Tilt** installed (`brew install tilt`)

## Quick Start

### Option A — AppCo already deployed (recommended)

If you already ran `tilt up` from the parent directory:

```bash
cd "Rancher Developer Access"
tilt up
```

This Tiltfile detects the existing AppCo services and reuses them.

### Option B — Fresh start

If AppCo is not yet deployed, first install via the Application Collection UI.
**For each chart, paste the matching `values_yaml/*.yaml` into the UI's
"Values YAML" field** — these enable the Traefik ingress on
`*-appco.localhost` so you can browse without `kubectl port-forward`:

1. **PostgreSQL** with `values_yaml/postgresql.yaml`
2. **Prometheus** with `values_yaml/prometheus.yaml`  → exposes `http://prometheus-appco.localhost`
3. **Grafana** with `values_yaml/grafana.yaml`        → exposes `http://grafana-appco.localhost`

Then:

```bash
cd "Rancher Developer Access"
tilt up
```

## What happens

Tilt will automatically:

1. Detect existing AppCo services in the `default` namespace
2. Create the `public` namespace and install public equivalents via Helm
3. Build the message-wall app with two different base images
4. Deploy Keycloak (both AppCo and public variants)
5. Build and deploy the CVE exporter (Prometheus metrics from Trivy results)
6. Run Trivy scans on all 16 images (8 components × 2 variants)
7. Display the CVE comparison in the Grafana dashboard

## URLs

All UIs are exposed through Traefik ingress on `*.localhost`. No
`kubectl port-forward`, no `/etc/hosts`: Rancher Desktop's klipper-lb
auto-binds Traefik on `127.0.0.1:80`, and browsers short-circuit
`*.localhost → 127.0.0.1` per RFC 6761.

Distinct hostnames per variant ⇒ each Keycloak / Grafana owns its
own cookie jar, so logging into one doesn't kick you out of the other.

| Resource | URL | Description |
|---|---|---|
| Message Wall (AppCo) | http://message-wall-appco.localhost | AppCo variant |
| Message Wall (Public) | http://message-wall-public.localhost | Public variant |
| Keycloak (AppCo) | http://keycloak-appco.localhost | AppCo Keycloak |
| Keycloak (Public) | http://keycloak-public.localhost | Public Keycloak |
| Grafana (AppCo) | http://grafana-appco.localhost | CVE comparison dashboard |
| Grafana (Public) | http://grafana-public.localhost | Public monitoring |
| Prometheus (AppCo) | http://prometheus-appco.localhost | AppCo metrics |
| Prometheus (Public) | http://prometheus-public.localhost | Public metrics |
| Tilt Dashboard | http://localhost:10350 | Orchestration overview |

## CVE Pipeline

```
trivy-scan.sh → K8s Job → JSON results → ConfigMap → cve-exporter.py → Prometheus → Grafana
```

The Grafana CVE comparison dashboard shows:
- **Donut charts**: CVE count by severity (Critical / High / Medium / Low)
- **Bar charts**: Per-application comparison (AppCo vs Public)
- **Nested table**: Grouped by application with expandable rows
- **Flat table**: All components with full detail

## Components Scanned

| Component | AppCo (SUSE) | Public |
|---|---|---|
| PostgreSQL | `dp.apps.rancher.io/charts/postgresql` | `docker.io/library/postgres:18` |
| Prometheus | `dp.apps.rancher.io/charts/prometheus` | `prom/prometheus:v3.10.0` |
| Node-Exporter | AppCo (bundled with Prometheus) | upstream |
| Grafana | `dp.apps.rancher.io/charts/grafana` | `grafana/grafana:12.4.0` |
| Keycloak | `dp.apps.rancher.io/containers/keycloak` | `quay.io/keycloak/keycloak:26.5.4` |
| Message-Wall | AppCo Node.js base | `docker.io/library/node:24` |
| Trivy | `dp.apps.rancher.io/containers/trivy` | `docker.io/aquasec/trivy` |
