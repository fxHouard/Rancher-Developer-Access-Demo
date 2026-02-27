# Developing for Kubernetes with SUSE Rancher Developer Access
**Rancher Desktop · SUSE Application Collection · VS Code**

*From development environment to deployment — Inner Loop · Dev Containers · Tilt · mirrord · Testcontainers · GitOps*

---

## 1. Overview: why this guide?

This crash course covers the **complete value chain** of Kubernetes development, from initial environment setup to continuous deployment. The goal: enable a developer to be productive quickly using popular tools, a local cluster (Rancher Desktop), and trusted images (SUSE Application Collection).

It is structured **from the developer's perspective**: we start with what makes you productive on day 1 (inner loop), and cover ops topics (GitOps, security, CD) toward the end.

### 1.1 The two loops of cloud-native development

|  | **Inner Loop** | **Outer Loop** |
|---|---|---|
| **What** | The developer's fast daily cycle: write code, build, deploy locally, test, debug, iterate | The automated post-commit cycle: CI/CD, integration tests, security scans, staging/prod deployment |
| **Goal** | Feedback in **seconds** | Quality and reproducibility |
| **Tools** | Tilt, mirrord | Argo CD, GitHub Actions, Tekton |
| **Scope** | Developer workstation + local cluster | CI/CD pipeline + remote cluster |

> 💡 **Key principle** — The inner loop must be as fast as possible. Every second saved in the `code → build → deploy → test` cycle multiplies by the number of daily changes. A good inner loop means going from 5–10 minutes to 5–10 seconds per iteration.

---

## 2. Overall architecture

### 2.1 Diagram

```mermaid
graph TB
    subgraph "Developer workstation"
        IDE["VS Code"]
        DC["Dev Container<br/>(coding environment)"]
        IDE -->|"opens project in"| DC
        
        TILT["Tilt<br/>(on host)"]
        
        subgraph "Rancher Desktop (VM)"
            MOBY["dockerd / moby<br/><i>container runtime</i>"]
            K3S["k3s<br/><i>Kubernetes cluster</i>"]
            MOBY -.->|"shared images<br/>(same store)"| K3S
            
            subgraph "Inside k3s cluster"
                APP["Your app pods"]
                PG["PostgreSQL<br/>(via Helm)"]
                PROM["Prometheus<br/>(via Helm)"]
                GRAF["Grafana<br/>(via Helm)"]
                REDIS["Redis, Kafka...<br/>(via Helm)"]
                APP -->|"connects to"| PG
                APP -->|"connects to"| REDIS
                PROM -->|"scrapes /metrics"| APP
                GRAF -->|"queries"| PROM
            end
        end
        
        TILT -->|"watch files<br/>+ live_update"| APP
        TILT -->|"kubectl apply"| K3S
        TILT -->|"docker build"| MOBY
        TILT -->|"port-forward"| APP
    end

    subgraph "SUSE Application Collection"
        BCI["Base Images<br/>BCI Base / Micro"]
        LANG["Languages<br/>Go, Node.js, Rust..."]
        CHARTS["Helm Charts<br/>PostgreSQL, Redis...<br/>Prometheus, Grafana..."]
        TOOLS["Tools<br/>Trivy, Cosign, Helm..."]
    end

    subgraph "Outer Loop (CI/CD + Production)"
        GIT["Git Repository"]
        CI["CI Pipeline<br/>(build, test, scan, push)"]
        ARGO["Argo CD<br/>(GitOps sync)"]
        PROD["Production Cluster"]
        GIT -->|"push triggers"| CI
        CI -->|"image → registry"| PROD
        ARGO -->|"reconciles"| PROD
        GIT -->|"watches"| ARGO
    end

    K3S -->|"pull images"| BCI
    K3S -->|"helm install"| CHARTS
    DC -->|"FROM dp.apps.rancher.io/..."| LANG
    PROD -->|"pull images"| BCI
    PROD -->|"helm install"| CHARTS

    style IDE fill:#0C322C,color:#fff
    style DC fill:#2B6CB0,color:#fff
    style K3S fill:#30845A,color:#fff
    style MOBY fill:#1F2937,color:#fff
    style TILT fill:#E65100,color:#fff
    style APP fill:#30845A,color:#fff
    style PG fill:#336791,color:#fff
    style PROM fill:#E6522C,color:#fff
    style GRAF fill:#F2CC0C,color:#000
    style REDIS fill:#DC382D,color:#fff
    style BCI fill:#30845A,color:#fff
    style LANG fill:#30845A,color:#fff
    style CHARTS fill:#30845A,color:#fff
    style TOOLS fill:#30845A,color:#fff
    style GIT fill:#F05032,color:#fff
    style CI fill:#1F2937,color:#fff
    style ARGO fill:#EF7B4D,color:#fff
    style PROD fill:#30845A,color:#fff
```

### 2.2 Stack layers

| **Layer** | **Tool** | **Role** |
|---|---|---|
| IDE | VS Code + extensions | Editor, debug, integrated terminals |
| Dev env | Dev Containers | Reproducible environment in a container |
| Local cluster | Rancher Desktop (k3s) | Local Kubernetes + container runtime |
| Images | SUSE Application Collection | Base images, languages, middleware, tools |
| Inner loop | Tilt | Auto-build, auto-deploy, hot reload |
| Observability | Prometheus + Grafana | Application metrics, real-time dashboards |
| Tests | Testcontainers | Disposable dependencies for integration tests |
| Packaging | Helm / Kustomize | K8s manifest templating |
| Security | Trivy / Cosign | Vulnerability scanning, image signing |
| GitOps | Argo CD | Declarative deployment from Git |

---

## 3. Step 1 – Setting up Rancher Desktop

### 3.1 What is Rancher Desktop?

Rancher Desktop is an open-source desktop application that provides a **local Kubernetes cluster** (k3s) and a **container runtime** (dockerd or containerd), all within an automatically managed VM. No need to install Docker Desktop.

### 3.2 Installation and configuration

1. **Download** from [rancherdesktop.io](https://rancherdesktop.io).
2. **Choose the runtime:** select **dockerd (moby)** (not containerd). This is essential for what follows.
3. **Enable Kubernetes** (enabled by default).
4. **Verify:**
   ```bash
   docker info          # → "Server Version: ..."
   kubectl get nodes    # → "Ready"
   ```
5. **PATH** — on macOS, verify that `~/.rd/bin/` is in your `$PATH` (added automatically by the installer):
   ```bash
   which docker kubectl helm   # should point to ~/.rd/bin/
   ```

> ⚠️ **Rancher Desktop ≠ Docker Desktop.** You don't need Docker Desktop. Rancher Desktop provides its own Docker daemon (`moby`/`dockerd`). Having both installed can create socket conflicts. Disable Docker Desktop if you have it.

### 3.3 Why dockerd (moby) when production runs containerd?

In production, Kubernetes uses **containerd** (or CRI-O) as runtime. But for local development, **dockerd (moby)** has a decisive advantage:

```
With dockerd (moby) — what we use:
┌─────────────────────────────────────────────┐
│ Rancher Desktop VM                          │
│                                             │
│   dockerd (moby)                            │
│   └── local image store ◄──────────────┐    │
│                                        │    │
│   k3s (containerd)                     │    │
│   └── uses the same image store ───────┘    │
│                                             │
│   docker build → local image → k3s sees it  │
│   NO PUSH NEEDED!                           │
└─────────────────────────────────────────────┘

With containerd alone — the classic workflow:
┌─────────────────────────────────────────────┐
│   nerdctl build → image in containerd       │
│   nerdctl push → registry                   │
│   k3s pull ← registry                       │
│                                             │
│   3 steps instead of 1 = slower             │
└─────────────────────────────────────────────┘
```

Images built by Docker are **immediately visible** to k3s. No registry, no push, no pull. This is what makes the inner loop so fast. This is also why the demo K8s Deployments use `imagePullPolicy: IfNotPresent` (or `Never`): we tell k3s "use the local image, don't look in a registry".

---

## 4. Step 2 – SUSE Application Collection

### 4.1 What is SUSE Application Collection?

**SUSE Application Collection** is a collection of applications in the form of container images and Helm charts, built, packaged, hardened, and maintained by SUSE — with SLSA L3 grade builds and all the metadata needed to keep Operations serene. It's the trusted source for building applications on Kubernetes.

The registry is `dp.apps.rancher.io`. You'll find:

- **Base images (BCI)** — SUSE Linux Enterprise Base Container Images: minimal, secure foundations.
- **Language images** — Node.js, Go, Python, Rust, Java, Ruby, PHP, .NET… with complete toolchains.
- **Middleware** — PostgreSQL, Redis, RabbitMQ, Kafka, MongoDB, MariaDB, NGINX, Apache…
- **Tools** — Helm, Trivy, Cosign, kubectl, ArgoCD, Prometheus, Grafana…
- **Helm Charts** — Ready-to-deploy packages for the entire stack above.

The **SUSE Application Collection extension** in Rancher Desktop adds a dedicated tab in the UI. You browse the catalog, configure values, and install with one click — the Helm complexity is hidden.

### 4.2 Why Application Collection over Docker Hub?

| | **Docker Hub** | **SUSE Application Collection** |
|---|---|---|
| **Maintenance** | Community, variable | SUSE, enterprise SLA |
| **Base OS** | Alpine, Debian, Ubuntu… | SLE BCI (SUSE Linux Enterprise) |
| **Security patches** | When the maintainer wants | Continuous CVE tracking by SUSE |
| **Signing** | Optional (Docker Content Trust) | Cosign built-in |
| **Supply chain** | Variable | SBOM, provenance, attestations, SLSA L3 |

### 4.3 Authentication

Authentication to the Application Collection registry is configured automatically by the SUSE Application Collection extension in Rancher Desktop.

**Verify it works:**

```bash
docker pull dp.apps.rancher.io/containers/bci-base:latest
```

**If auth is not configured**, add it manually:

```bash
# Log in to the registry (SUSE Customer Center credentials)
docker login dp.apps.rancher.io

# Verify
docker pull dp.apps.rancher.io/containers/bci-base:latest
```

**For Kubernetes (helm install, pods)** — a pull secret is needed if images aren't already pulled. Rancher Desktop handles this automatically via the extension. If there's an issue:

```bash
kubectl create secret docker-registry application-collection \
  --docker-server=dp.apps.rancher.io \
  --docker-username=<USERNAME> \
  --docker-password=<PASSWORD>
```

Then add `imagePullSecrets: [{name: application-collection}]` in your manifests or Helm values.

### 4.4 Practical usage

**Finding an image:**

```bash
# Browse the catalog (or use the Rancher Desktop UI)
# Naming convention:
#   dp.apps.rancher.io/containers/<image>:<tag>     (images)
#   dp.apps.rancher.io/charts/<chart>                (Helm charts)
```

**In a Dockerfile:**

```dockerfile
# Base image for building
FROM dp.apps.rancher.io/containers/nodejs:24-dev AS builder
WORKDIR /app
COPY package.json ./
RUN npm install --no-package-lock
COPY . .

# Minimal final image
FROM dp.apps.rancher.io/containers/nodejs:24
WORKDIR /app
COPY --from=builder /app .
EXPOSE 3000
CMD ["node", "src/server.js"]
```

**Installing a chart via Helm:**

```bash
# Install PostgreSQL from Application Collection
helm install my-db oci://dp.apps.rancher.io/charts/postgresql \
  --set auth.username=demo \
  --set auth.password=demo \
  --set auth.database=demo
```

> 💡 **Tip:** the Rancher Desktop extension exposes these same charts in the Application Collection tab, with a form to configure values. One-click installation generates the `helm install` command behind the scenes.

---

## 5. Step 3 – VS Code and Dev Containers

### 5.1 Essential extensions

| **Extension** | **Role** |
|---|---|
| **Dev Containers** | Open project in a dev container |
| **Kubernetes** | Explore cluster resources, view logs |
| **Docker** | View containers, images, volumes |
| **YAML** (Red Hat) | K8s manifest autocompletion + validation |
| **Helm Intellisense** | Autocompletion in Helm charts |
| **Bridge to Kubernetes** | _(optional)_ Local debug connected to cluster |

### 5.2 Dev Containers: the reproducible environment

The principle: your development environment is defined **in code** (`.devcontainer/`). Every developer who opens the project gets exactly the same environment, with the same tools, same versions, same VS Code extensions.

### 5.3 How the Dev Container interacts with Rancher Desktop

The Dev Container is a development container — it serves **only for coding**. It's a reproducible environment with the project's tools (Node.js, Python, Go…). It doesn't need Docker, kubectl, or Helm.

```
┌─ VS Code ──────────────────────────────────────────────┐
│  Opens the Dev Container via the Dev Containers ext.    │
│  → Uses the Docker daemon from Rancher Desktop          │
└─────────────────────────────────────────────────────────┘
         │
         ▼
┌─ Rancher Desktop VM ───────────────────────────────────┐
│                                                         │
│  dockerd (moby)                                        │
│  ├── Dev Container (Node.js, git, coding tools)        │
│  │   └── Bind mount: ~/my-project ↔ /workspace          │
│  │                                                      │
│  └── k3s cluster                                        │
│      └── App pods (deployed by Tilt)                    │
│                                                         │
│  Tilt (on host) orchestrates build/deploy/sync           │
│  between dockerd and k3s                                 │
└─────────────────────────────────────────────────────────┘
```

**The Dev Container doesn't touch the cluster.** It provides the editor and coding tools. Tilt, running on the host, handles image building, deployment, and synchronization.

### 5.4 devcontainer.json example

**`.devcontainer/Dockerfile`:**

```dockerfile
FROM dp.apps.rancher.io/containers/nodejs:24-dev

# System tools (available in the SLE_BCI repo)
# gawk: required by VS Code Server (check-requirements.sh)
RUN zypper --non-interactive install -y git openssh make gawk \
    && zypper clean -a
```

**`.devcontainer/devcontainer.json`:**

```jsonc
{
  "name": "Message Wall - Node.js",
  "build": {
    "dockerfile": "Dockerfile"
  },
  "customizations": {
    "vscode": {
      "extensions": [
        "redhat.vscode-yaml"
      ]
    }
  },
  "postCreateCommand": "if [ -f package.json ]; then npm install --no-package-lock; fi"
}
```

> 💡 **Notice** — no `docker`, `kubectl`, `helm`, or `tilt` in the dev container. Tilt runs on the host. See [§6.2](#62-tilt--rancher-desktop-configuration). The Red Hat YAML extension provides validation and autocompletion for Kubernetes manifests. The conditional `postCreateCommand` installs npm dependencies automatically if a `package.json` exists.

---

## 6. Step 4 – The Inner Loop with Tilt

The inner loop is the heart of Kubernetes developer productivity. The traditional cycle (`code → docker build → docker push → kubectl apply → wait for pod → check logs → repeat`) typically takes 5 to 10 minutes. Tilt reduces this cycle to a few seconds.

### 6.1 Tilt in a nutshell

**Tilt** is an open-source tool that automates every step from code change to redeployment. It watches your files, rebuilds images, updates the cluster, and displays everything in a real-time dashboard.

- **live_update:** syncs modified files directly into the running container, without rebuilding the image.
- **Web Dashboard:** unified view of all your microservices, logs of build and runtime, status of each resource.
- **Tiltfile (Starlark):** a Python-like DSL to configure the workflow.
- **Multi-service:** manages N microservices simultaneously with their dependencies.

### 6.2 Tilt + Rancher Desktop: configuration

Tilt runs **on the host** (not inside the Dev Container) and directly uses the CLIs installed by Rancher Desktop: `docker`, `kubectl`, `helm`. It automatically detects Rancher Desktop (since Tilt v0.25.1+) when the runtime is dockerd. It then knows that locally built images are directly available in the cluster, and **skips the push**.

**Host prerequisites:** `brew install tilt` (macOS) or see [tilt.dev](https://tilt.dev) for other OSes.

If Tilt doesn't automatically detect your cluster, add this line at the top of the Tiltfile:

```python
allow_k8s_contexts('rancher-desktop')
```

This is the only Rancher Desktop-specific configuration. Everything else is standard.

### 6.3 Anatomy of a Tiltfile – in detail

```python
# =============================================================
# Tiltfile — Inner loop configuration
# =============================================================

# --- 1. Cluster detection ------------------------------------
allow_k8s_contexts('rancher-desktop')


# --- 2. restart_process extension ----------------------------
# For interpreted languages (Node.js, Python), a live_update
# that syncs files isn't enough: the process runs in memory
# with the old code. It needs to be restarted.
#
# The restart_process extension replaces docker_build with
# docker_build_with_restart, which automatically restarts the
# process after each live_update.

load('ext://restart_process', 'docker_build_with_restart')


# --- 3. Image build with automatic restart -------------------
docker_build_with_restart(
    'message-wall',
    '.',
    entrypoint=['node', 'src/server.js'],
    only=['src/', 'package.json'],
    live_update=[
        sync('./src', '/app/src'),
        run('cd /app && npm install --no-package-lock',
            trigger=['package.json']),
    ]
)


# --- 4. PostgreSQL (managed outside Tilt) --------------------
pg_svc = str(local(
    "kubectl get svc -l app.kubernetes.io/name=postgresql "
    "-o jsonpath='{.items[0].metadata.name}'",
    quiet=True,
)).strip()
if pg_svc == '':
    fail('PostgreSQL not found. Install it via Rancher Desktop.')


# --- 5. Deploy the application --------------------------------
deployment = str(read_file('k8s/deployment.yaml')).replace(
    'demo-db-postgresql', pg_svc)
k8s_yaml([blob(deployment), 'k8s/service.yaml'])

k8s_resource(
    'message-wall',
    port_forwards='3000:3000',
    labels=['app'],
)


# --- 6. Monitoring (optional) --------------------------------
# Port-forwards to Prometheus and Grafana if installed.
# ConfigMaps for datasource and dashboard are also managed here.
# See §9.11 for the complete Tiltfile.
```

> 💡 **`docker_build` vs `docker_build_with_restart`** — For compiled languages (Go, Rust, Java), `docker_build` with a simple `sync()` often suffices (the binary is replaced and relaunched). For interpreted languages (Node.js, Python, Ruby), code is loaded into memory at startup — `docker_build_with_restart` is needed to restart the process after each sync.

### 6.4 What Tilt does when you run `tilt up`

```mermaid
sequenceDiagram
    participant Dev as Developer
    participant Tilt as Tilt
    participant Docker as dockerd (moby)
    participant K3s as k3s (Kubernetes)
    
    Dev->>Tilt: tilt up
    Tilt->>Docker: docker build message-wall
    Docker-->>Tilt: image ready (local)
    Note over Docker,K3s: Image in shared store<br/>No push!
    Tilt->>K3s: kubectl apply (deployment + service)
    K3s-->>Tilt: pods started
    Tilt->>K3s: kubectl port-forward 3000:3000
    Tilt-->>Dev: Web dashboard on localhost:10350
    
    Note over Dev: Dev modifies src/server.js in VS Code (Dev Container)
    
    Dev->>Tilt: (file watcher on host detects change)
    Tilt->>K3s: kubectl cp src/ → container (live_update)
    Note over K3s: restart_process relaunches node
    K3s-->>Tilt: files synced + process restarted
    Tilt-->>Dev: ✅ Updated in ~2 seconds
```

### 6.5 Port forwarding explained

Tilt manages port forwarding automatically via `port_forwards` in `k8s_resource()`. It's the equivalent of `kubectl port-forward`, but integrated into Tilt's lifecycle (automatically restarted if the pod is recreated).

**Complete port forwarding chain:**

```
Browser (localhost:3000)
  → Tilt port-forward
    → K8s Service (ClusterIP)
      → Your app pod (:3000)
        → Connects to PostgreSQL Service (:5432)
          → PostgreSQL pod
```

Your app in the pod uses Kubernetes internal DNS to reach PostgreSQL:
```
postgresql://user:pass@demo-db-postgresql.default.svc.cluster.local:5432/mydb
```

From your local machine (for a SQL client for example): `kubectl port-forward svc/demo-db-postgresql 5432:5432`.

---

## 7. What about mirrord? Do I need it?

### 7.1 The legitimate question

With Tilt and Rancher Desktop, you already have a complete local workflow. **mirrord** comes into play in a different scenario.

### 7.2 What mirrord does

mirrord lets you run a local process (on your machine or in your IDE) while connecting it **to the network and filesystem of a pod in a remote Kubernetes cluster**. The code runs locally, but "sees" the cluster environment.

### 7.3 When mirrord becomes essential

**No need for mirrord if:**
- You have a local cluster (Rancher Desktop) with all dependencies.
- Your app has 1 to 5 microservices that you can all run locally.

**mirrord becomes interesting when:**
- The app has **20+ microservices** — impossible to run everything locally.
- You need to test against a **managed service** (cloud database, external API) not available locally.
- The staging cluster has realistic data needed for debugging.
- You want the comfort of **local debugging** (breakpoints in VS Code) with the context of a real cluster.

> 💡 **The winning combination** — Tilt for daily inner loop (local cluster), mirrord for occasional debugging on staging. The two tools are complementary, not competitors.

---

## 8. Step 5 – Testcontainers: integration tests

### 8.1 The concept

Testcontainers is a library that spins up ephemeral Docker containers in your integration tests. Need a PostgreSQL to test your SQL queries? Testcontainers launches one, runs your tests, and destroys it when done.

### 8.2 Why it matters

- **Reproducibility:** each test starts a fresh database — no pollution between tests.
- **No mocks:** you test against the real database, not a mock that can diverge.
- **CI-friendly:** works in GitHub Actions, GitLab CI, etc. (just needs Docker).

> 💡 Testcontainers uses the host's Docker daemon. With Rancher Desktop (dockerd), it works directly — no special configuration needed.

### 8.3 Testcontainers + Rancher Desktop configuration

Testcontainers needs to know where the Docker daemon is. With Rancher Desktop:

```bash
# macOS / Linux — already configured if ~/.rd/bin is in PATH
export DOCKER_HOST=unix://$HOME/.rd/run/docker.sock

# Verify
docker info   # should display "Server Version: ..."
```

**With Application Collection images:** by default, Testcontainers pulls from Docker Hub. To use Application Collection images instead:

```javascript
// Node.js: use the Application Collection PostgreSQL image
const { GenericContainer } = require('testcontainers');

const container = await new GenericContainer(
  'dp.apps.rancher.io/containers/postgresql:17'
)
  .withExposedPorts(5432)
  .withEnvironment({
    POSTGRES_USER: 'test',
    POSTGRES_PASSWORD: 'test',
    POSTGRES_DB: 'testdb',
  })
  .start();
```

### 8.4 Example (Node.js)

```javascript
const { GenericContainer } = require('testcontainers');
const { Client } = require('pg');

describe('Database integration', () => {
  let container, client;
  
  beforeAll(async () => {
    container = await new GenericContainer('dp.apps.rancher.io/containers/postgresql:17')
      .withExposedPorts(5432)
      .withEnvironment({ POSTGRES_USER: 'test', POSTGRES_PASSWORD: 'test', POSTGRES_DB: 'test' })
      .start();
    
    client = new Client({
      host: container.getHost(),
      port: container.getMappedPort(5432),
      user: 'test', password: 'test', database: 'test',
    });
    await client.connect();
  });

  afterAll(async () => {
    await client.end();
    await container.stop();
  });

  test('should insert and retrieve data', async () => {
    await client.query('CREATE TABLE test (id SERIAL, name TEXT)');
    await client.query("INSERT INTO test (name) VALUES ('hello')");
    const result = await client.query('SELECT * FROM test');
    expect(result.rows).toHaveLength(1);
  });
});
```

### 8.5 Testcontainers vs Tilt+Helm for dependencies

| | **Testcontainers** | **Tilt + Helm (Application Collection)** |
|---|---|---|
| **Lifecycle** | Ephemeral (1 test run) | Persistent (dev session duration) |
| **Data** | Fresh each run | Persistent (unless purged) |
| **Usage** | Integration tests in CI | Daily local development |
| **Config** | In test code | In Tiltfile / Helm values |

---

## 9. Step-by-step demo: Message Wall with observability

This demo shows the complete workflow: a Dev Container for coding, Tilt for the inner loop, and a "message wall" application connected to PostgreSQL, instrumented with Prometheus, and visualized in Grafana. Everything is installed from SUSE Application Collection.

The complete source code is available on GitHub: [fxHouard/Rancher-Developer-Access-Demo](https://github.com/fxHouard/Rancher-Developer-Access-Demo).

### 9.1 Prerequisites

- Rancher Desktop installed, runtime = **dockerd (moby)**, Kubernetes enabled.
- VS Code with the **Dev Containers** extension.
- **Tilt** installed on the host (`brew install tilt` on macOS).
- Access to `dp.apps.rancher.io` (images and charts — configured automatically by the SUSE Application Collection extension in Rancher Desktop).

### 9.2 Project structure

```
Rancher-Developer-Access-Demo/
├── .devcontainer/
│   ├── Dockerfile
│   └── devcontainer.json
├── src/
│   └── server.js
├── k8s/
│   ├── deployment.yaml
│   ├── service.yaml
│   └── grafana-dashboard.yaml
├── charts/
│   └── postgresql/
│       └── values-dev.yaml
├── Dockerfile
├── Tiltfile
└── package.json
```

### 9.3 The Dev Container

**`.devcontainer/Dockerfile`:**

```dockerfile
FROM dp.apps.rancher.io/containers/nodejs:24-dev

# System tools (available in the SLE_BCI repo)
# gawk: required by VS Code Server (check-requirements.sh)
RUN zypper --non-interactive install -y git openssh make gawk \
    && zypper clean -a
```

**`.devcontainer/devcontainer.json`:**

```jsonc
{
  "name": "Message Wall - Node.js",
  "build": {
    "dockerfile": "Dockerfile"
  },
  "customizations": {
    "vscode": {
      "extensions": [
        "redhat.vscode-yaml"
      ]
    }
  },
  "postCreateCommand": "if [ -f package.json ]; then npm install --no-package-lock; fi"
}
```

> 💡 No `docker`, `kubectl`, `helm`, or `tilt` in the dev container. Tilt runs on the host. See [§6.2](#62-tilt--rancher-desktop-configuration). The Red Hat YAML extension provides validation and autocompletion for Kubernetes manifests. The conditional `postCreateCommand` installs npm dependencies automatically if a `package.json` exists.

### 9.4 The package.json

```json
{
  "name": "message-wall",
  "version": "1.0.0",
  "description": "SUSE Rancher Developer Access + Tilt: Demo",
  "main": "src/server.js",
  "scripts": {
    "start": "node src/server.js"
  },
  "dependencies": {
    "pg": "^8.13.0",
    "prom-client": "^15.1.0"
  }
}
```

Two dependencies only: `pg` for PostgreSQL and `prom-client` to expose Prometheus metrics.

### 9.5 The application (src/server.js)

The application is an interactive message wall with a built-in web UI. It exposes Prometheus metrics for observability. Here are the key parts — the complete file is in the repo.

**Configuration and Prometheus metrics:**

```javascript
const http = require('http');
const { Client } = require('pg');
const promClient = require('prom-client');

const PORT = 3000;

// 🎨 Change this color, save, watch the live_update!
const ACCENT_COLOR = '#747dcd';

// ─── Prometheus metrics ──────────────────────────
// collectDefaultMetrics() automatically exposes Node.js
// metrics: CPU, heap memory, event loop lag, GC…
promClient.collectDefaultMetrics();

// Custom metrics — prefixed "app_" for easy discovery
const httpDuration = new promClient.Histogram({
  name: 'app_http_request_duration_seconds',
  help: 'Duration of HTTP requests in seconds',
  labelNames: ['method', 'path', 'status'],
  buckets: [0.005, 0.01, 0.05, 0.1, 0.5, 1],
});

const messagesPosted = new promClient.Counter({
  name: 'app_messages_posted_total',
  help: 'Total number of messages posted',
});

const messagesDeleted = new promClient.Counter({
  name: 'app_messages_deleted_total',
  help: 'Total number of bulk deletes',
});

const messagesCurrent = new promClient.Gauge({
  name: 'app_messages_count',
  help: 'Current number of messages in the database',
});
```

> 💡 **Why the `app_` prefix?** — Prometheus collects hundreds of metrics (Node.js, k8s, system…). The `app_` prefix lets you instantly find your application metrics: type `app_` in Grafana and autocomplete does the rest.

**Prometheus metric types:**

| **Type** | **Usage** | **Demo example** |
|---|---|---|
| **Counter** | Value that only goes up | `app_messages_posted_total` — total messages posted |
| **Gauge** | Value that goes up and down | `app_messages_count` — current messages in database |
| **Histogram** | Distribution of values (latency) | `app_http_request_duration_seconds` — response time per route |

**API routes:**

```javascript
// Simplified routing:
// GET  /              → HTML page (the message wall)
// GET  /api/messages  → list 50 most recent messages + metadata
// POST /api/messages  → create a message (280 char limit, PG-validated)
// DELETE /api/messages → delete all messages
// GET  /health        → K8s probe (liveness + readiness)
// GET  /metrics       → Prometheus metrics (text format)
```

**The `/metrics` endpoint:**

```javascript
if (req.method === 'GET' && req.url === '/metrics') {
  const metrics = await promClient.register.metrics();
  res.writeHead(200, { 'Content-Type': promClient.register.contentType });
  res.end(metrics);
  // Don't record /metrics in the histogram (noise)
  return;
}
```

This is the endpoint that Prometheus scrapes periodically. It returns all metrics in OpenMetrics text format. Note that `/metrics` itself is not measured by the histogram — that would be noise.

**The measurement middleware:**

Every HTTP request is automatically timed:

```javascript
const end = httpDuration.startTimer();
// ... request processing ...
end({ method: req.method, path: routePath, status: statusCode });
```

The histogram records the duration, method, path, and return code. Grafana can then compute percentiles (p50, p95, p99) per route.

**The HTML page:**

The application serves an interactive message wall directly from Node.js (inline HTML in `server.js`). The UI includes an input field, an info bar showing the pod name and uptime, and automatic polling every 3 seconds with smart diffing (only timestamps are updated if messages haven't changed, no flickering).

> 💡 **live_update demo** — Change the `ACCENT_COLOR` constant on line 9, save. In ~2 seconds, the wall color changes without losing messages. That's Tilt's live_update in action.

### 9.6 The Dockerfile

```dockerfile
FROM dp.apps.rancher.io/containers/nodejs:24-dev
WORKDIR /app
COPY package.json ./
RUN npm install --no-package-lock
COPY . .
EXPOSE 3000
CMD ["node", "src/server.js"]
```

> 💡 **In production**, you'd use a multi-stage build to separate the `npm install` step (dev image with npm) from the final image (minimal `nodejs:24` image, without npm or build tools). Here we keep a simple Dockerfile for the demo.

### 9.7 The Kubernetes manifests

**k8s/deployment.yaml:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: message-wall
spec:
  replicas: 1
  selector:
    matchLabels:
      app: message-wall
  template:
    metadata:
      labels:
        app: message-wall
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "3000"
        prometheus.io/path: "/metrics"
    spec:
      containers:
        - name: message-wall
          image: message-wall           # Tilt replaces with local image
          ports:
            - containerPort: 3000
          resources:
            requests:
              cpu: 100m           # 0.1 vCPU — scheduler reserves this
              memory: 128Mi       # 128 MB — guaranteed minimum
            limits:
              cpu: 500m           # 0.5 vCPU — ceiling, throttled beyond
              memory: 256Mi       # 256 MB — OOMKill beyond
          env:
            - name: DB_HOST
              value: "demo-db-postgresql"
            - name: DB_PORT
              value: "5432"
            - name: DB_USER
              value: "demo"
            - name: DB_PASSWORD
              value: "demo"
            - name: DB_NAME
              value: "demo"
          livenessProbe:
            httpGet:
              path: /health
              port: 3000
            initialDelaySeconds: 5
          readinessProbe:
            httpGet:
              path: /health
              port: 3000
            initialDelaySeconds: 5
```

> 💡 **Prometheus annotations** — The three annotations under `template.metadata.annotations` tell Prometheus: "scrape this pod, on port 3000, at path `/metrics`". The Prometheus server, configured by default for Kubernetes auto-discovery, automatically detects annotated pods. No additional Prometheus configuration needed.

> ⚠️ **Watch the indentation** — Annotations must be under `template.metadata` (the pod template), not under the Deployment's `metadata` or at the `spec` level. This is a common mistake: if annotations are at the wrong level, Prometheus won't find your pods.

> 💡 **Why `resources`?** — Without `requests` or `limits`, a pod can consume all node resources and impact other workloads — the **"noisy neighbor"** problem. `requests` are for the scheduler (intelligent placement), `limits` protect the node (CPU throttling, OOMKill if memory exceeds).

**k8s/service.yaml:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: message-wall
spec:
  selector:
    app: message-wall
  ports:
    - port: 3000
      targetPort: 3000
```

### 9.8 Installing PostgreSQL from Application Collection

PostgreSQL is an infrastructure service — install it once via Rancher Desktop, not on every `tilt up`.

**Via the Rancher Desktop UI:**

1. **Application Collection** tab in Rancher Desktop
2. Search for **PostgreSQL** → **Install**
3. Configure auth values:
   - `auth.username`: `demo`
   - `auth.password`: `demo`
   - `auth.database`: `demo`

**Or via CLI with the values file provided in the repo:**

The repo includes a `charts/postgresql/values-dev.yaml` with a ready-to-use configuration:

```yaml
# charts/postgresql/values-dev.yaml
global:
  imagePullSecrets:
    - application-collection

auth:
  username: demo
  password: demo
  database: demo
  
primary:
  persistence:
    size: 1Gi
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
```

```bash
helm install demo-db oci://dp.apps.rancher.io/charts/postgresql \
  -f charts/postgresql/values-dev.yaml
```

> 💡 **`imagePullSecrets`** — The values file references the `application-collection` secret so PostgreSQL pods can pull images from `dp.apps.rancher.io`. This secret is created automatically by the Rancher Desktop extension, or manually with `kubectl create secret docker-registry application-collection --docker-server=dp.apps.rancher.io ...`.

> The Helm chart automatically creates the user, database, and a service named `<release-name>-postgresql`. The Tiltfile auto-detects this service via the `app.kubernetes.io/name=postgresql` label — no need to remember the release name.

### 9.9 Installing Prometheus and Grafana from Application Collection

Like PostgreSQL, Prometheus and Grafana are installed via Rancher Desktop and persist between development sessions.

**Prometheus:**

1. **Application Collection** tab → search **Prometheus** → **Install**
2. Default values are fine. Prometheus is configured by default for auto-discovery of pods annotated with `prometheus.io/scrape: "true"`.

**Grafana:**

1. **Application Collection** tab → search **Grafana** → **Install**
2. Configure:
   - `adminPassword`: `admin` (or whatever you prefer)
   - `sidecar.dashboards.enabled`: **`true`**
   - `sidecar.datasources.enabled`: **`true`**

> 💡 **Grafana sidecars** — These are small containers running alongside Grafana in the same pod. They watch for Kubernetes ConfigMaps with certain labels and automatically load their contents into Grafana. No need to manually configure datasources or import dashboards.

| **Sidecar** | **Watched label** | **Effect** |
|---|---|---|
| `grafana-sc-dashboard` | `grafana_dashboard: "1"` | Automatically loads dashboard JSON files |
| `grafana-sc-datasources` | `grafana_datasource: "1"` | Automatically configures datasources |

**Verify the sidecars are active:**

```bash
kubectl get pods -l app.kubernetes.io/name=grafana \
  -o jsonpath='{.items[0].spec.containers[*].name}'
# Expected: grafana grafana-sc-dashboard grafana-sc-datasources
```

If you only see `grafana`, go back to the Rancher Desktop UI and enable both `sidecar.dashboards.enabled` and `sidecar.datasources.enabled` values, then **Upgrade** the chart.

### 9.10 The Grafana dashboard (auto-provisioned ConfigMap)

The Grafana dashboard is defined in a Kubernetes ConfigMap. Thanks to the sidecar enabled in the previous step, it loads automatically — zero manual import.

**k8s/grafana-dashboard.yaml:**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: message-wall-dashboard
  labels:
    grafana_dashboard: "1"      # ← the sidecar detects this label
data:
  message-wall.json: |
    {
      "uid": "message-wall",
      "title": "Message Wall",
      "tags": ["app", "demo"],
      "timezone": "browser",
      "refresh": "5s",
      "time": { "from": "now-15m", "to": "now" },
      "schemaVersion": 39,
      "panels": [
        {
          "title": "Messages in database",
          "type": "stat",
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "targets": [{
            "expr": "app_messages_count",
            "legendFormat": "messages"
          }],
          ...
        },
        ...
      ]
    }
```

> ⚠️ **`uid: "prometheus"`** — Each panel references the datasource by `"uid": "prometheus"`. This uid must **exactly match** the one declared in the datasource ConfigMap (see §9.11). If the JSON uses `${DS_PROMETHEUS}` (Grafana UI import syntax), the sidecar will **not** resolve that variable — you must replace it with the hardcoded uid.

The complete file is in the repo (`k8s/grafana-dashboard.yaml`). The dashboard contains 8 panels:

| **Panel** | **Type** | **Metric** | **What it shows** |
|---|---|---|---|
| Messages in database | Stat | `app_messages_count` | Gauge with thresholds green < 50 < yellow < 100 < red |
| Messages posted | Stat | `app_messages_posted_total` | Total messages posted counter |
| Bulk deletes | Stat | `app_messages_deleted_total` | Total bulk deletes counter |
| Requests / sec | Timeseries | `rate(app_http_..._count[1m])` | Throughput per HTTP route |
| Posts / min | Timeseries | `rate(app_messages_posted_total[1m]) * 60` | Publication rate |
| Response time (p95) | Timeseries | `histogram_quantile(0.95, ...)` | 95th percentile latency per route |
| Memory usage | Timeseries | `process_resident_memory_bytes` | RSS + Node.js heap |
| Event loop lag (p99) | Timeseries | `nodejs_eventloop_lag_p99_seconds` | Event loop health |

> 💡 **Declarative provisioning** — The dashboard is in Git, versioned with the code. If you modify it in Grafana (adding panels, changing queries), export it and update the ConfigMap so changes aren't lost on the next redeployment. This is the **Infrastructure as Code** approach applied to observability.

### 9.11 The complete Tiltfile

```python
# Demo Tiltfile
load('ext://restart_process', 'docker_build_with_restart')

allow_k8s_contexts('rancher-desktop')

# ─── PostgreSQL (installed via Rancher Desktop) ──────────────────
pg_svc = str(local(
    "kubectl get svc -l app.kubernetes.io/name=postgresql "
    "-o jsonpath='{.items[0].metadata.name}'",
    quiet=True,
)).strip()
if pg_svc == '':
    fail('PostgreSQL not found. Install it via Rancher Desktop '
         '(Application Collection).')

# ─── Our application ─────────────────────────────────────────────
docker_build_with_restart(
    'message-wall',
    '.',
    entrypoint=['node', 'src/server.js'],
    only=['src/', 'package.json'],
    live_update=[
        sync('./src', '/app/src'),
        run('cd /app && npm install --no-package-lock',
            trigger=['package.json']),
    ],
)

deployment = str(read_file('k8s/deployment.yaml')).replace(
    'demo-db-postgresql', pg_svc)
k8s_yaml([blob(deployment), 'k8s/service.yaml', 'k8s/grafana-dashboard.yaml'])

k8s_resource(
    'message-wall',
    port_forwards='3000:3000',
    labels=['app'],
)

# ─── Monitoring (installed via Rancher Desktop) ──────────────────
# Auto-detection of services by Kubernetes label.
# Service names vary by release name (random if installed via the
# Rancher Desktop UI), so we search by label.

grafana_svc = str(local(
    "kubectl get svc -l app.kubernetes.io/name=grafana "
    "-o jsonpath='{.items[0].metadata.name}'",
    quiet=True,
)).strip()

prometheus_svc = str(local(
    "kubectl get svc "
    "-l app.kubernetes.io/name=prometheus,"
    "app.kubernetes.io/component=server "
    "-o jsonpath='{.items[0].metadata.name}'",
    quiet=True,
)).strip()

if grafana_svc:
    local_resource(
        'grafana',
        serve_cmd='kubectl port-forward svc/' + grafana_svc + ' 3001:80',
        labels=['monitoring'],
        allow_parallel=True,
        links=['http://localhost:3001',
               'http://localhost:3001/d/message-wall/'],
    )

if prometheus_svc:
    local_resource(
        'prometheus',
        serve_cmd='kubectl port-forward svc/' + prometheus_svc
                  + ' 9090:80',
        labels=['monitoring'],
        allow_parallel=True,
        links=['http://localhost:9090'],
    )

    # ─── Prometheus datasource (auto-provisioned ConfigMap) ──────
    # The grafana-sc-datasources sidecar detects this ConfigMap
    # and configures Prometheus as a datasource in Grafana.
    # The URL uses the actual service name detected dynamically.
    datasource_cm = """apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasource-prometheus
  labels:
    grafana_datasource: "1"
data:
  prometheus.yaml: |
    apiVersion: 1
    datasources:
      - name: Prometheus
        type: prometheus
        uid: prometheus
        url: http://{svc}:80
        access: proxy
        isDefault: true
        editable: false
""".format(svc=prometheus_svc)

    k8s_yaml(blob(datasource_cm))

# ─── Group monitoring ConfigMaps in Tilt ─────────────────────────
# Without this, ConfigMaps appear in "uncategorized".
# objects groups non-workload K8s resources under a single name.
k8s_resource(
    objects=['message-wall-dashboard:configmap',
             'grafana-datasource-prometheus:configmap'],
    new_name='grafana-config',
    labels=['monitoring'],
    links=['http://localhost:3001/d/message-wall/'],
)
```

**Key points of the Tiltfile:**

**`docker_build_with_restart`** — The `restart_process` extension solves a problem specific to interpreted languages. When `live_update` syncs a file into the container, Node.js doesn't see it — the code is already loaded into memory. `docker_build_with_restart` wraps the entrypoint to automatically restart the process after each sync.

**Label-based auto-detection** — Services installed via the Rancher Desktop UI have random release names (e.g., `grafana-1772033328`). Instead of hardcoding these names, the Tiltfile discovers them via Kubernetes labels set by the Helm charts. This is a robust pattern: the Tiltfile works regardless of the release name.

**Prometheus datasource as ConfigMap** — Rather than configuring Prometheus in the Grafana UI (manual configuration lost on redeployment), the Tiltfile generates a ConfigMap with the `grafana_datasource: "1"` label. The Grafana sidecar detects it and automatically provisions the connection. The Prometheus URL is injected dynamically: `http://{detected-service-name}:80`.

**`links`** — Each `local_resource` and `k8s_resource` can declare clickable links in the Tilt dashboard. You see the URLs for Grafana, Prometheus, and the specific dashboard directly in the Tilt UI.

**`objects` + `new_name`** — ConfigMaps are not workloads (Deployment, StatefulSet…), so Tilt files them under "uncategorized" by default. The `objects` directive groups them under an explicit name (`grafana-config`) with the `monitoring` label.

**Conditionality** — The monitoring block is conditional (`if grafana_svc` / `if prometheus_svc`). If Prometheus and Grafana aren't installed, the Tiltfile still works — only the app and PostgreSQL are required. Observability is an opt-in bonus.

### 9.12 Running the demo

```bash
# 1. Clone the repo
git clone https://github.com/fxHouard/Rancher-Developer-Access-Demo.git
cd Rancher-Developer-Access-Demo

# 2. Open in VS Code
code .

# 3. VS Code detects devcontainer.json
#    → "Reopen in Container" (or Cmd+Shift+P → Dev Containers: Reopen)

# 4. Install services via Rancher Desktop (one time only):
#
#    PostgreSQL:
#      → Application Collection tab: search PostgreSQL, configure auth, Install
#      → Or CLI: helm install demo-db oci://dp.apps.rancher.io/charts/postgresql \
#                -f charts/postgresql/values-dev.yaml
#
#    Prometheus:
#      → Application Collection tab: search Prometheus, Install (default values)
#
#    Grafana:
#      → Application Collection tab: search Grafana, Install
#      → adminPassword: admin
#      → sidecar.dashboards.enabled: true
#      → sidecar.datasources.enabled: true

# 5. In an EXTERNAL terminal (Terminal.app, iTerm2, Warp…):
cd Rancher-Developer-Access-Demo
tilt up                    # Start the inner loop

# 6. Open the URLs (also clickable from the Tilt dashboard):
#    → http://localhost:10350  — Tilt dashboard
#    → http://localhost:3000   — The Message Wall app
#    → http://localhost:9090   — Prometheus (check targets)
#    → http://localhost:3001   — Grafana (admin / admin)

# 7. In Grafana: go to Dashboards → "Message Wall" is already there
#    (or click the direct link in Tilt)

# 8. Post messages on localhost:3000 and watch the metrics
#    update in real time in Grafana

# 9. Change ACCENT_COLOR in src/server.js (line 9) in VS Code
#    → save → ~2 sec → the color changes
```

> 💡 **Why an external terminal?** — When VS Code is connected to a Dev Container, all its integrated terminals open **inside the container**. But Tilt must run on the host (where docker, kubectl, and helm are). Use a separate terminal (Terminal.app, iTerm2, Warp…) or a second VS Code window opened on the same folder **without** "Reopen in Container".

### 9.13 What happens under the hood

```
1. VS Code launches the Dev Container via Rancher Desktop's dockerd (moby)
   └── The container provides Node.js + node_modules (coding environment)

2. `tilt up` on the host (separate terminal):
   ├── Auto-detects PostgreSQL (label app.kubernetes.io/name=postgresql)
   ├── Auto-detects Prometheus and Grafana (labels app.kubernetes.io/name=...)
   ├── docker build message-wall → image in dockerd's local store
   │   └── k3s sees the image because same store → imagePullPolicy: IfNotPresent
   ├── kubectl apply deployment + service → k3s creates the app pod
   │   ├── Pod connects to detected PG service (K8s internal DNS)
   │   └── Prometheus scrapes the pod (prometheus.io/* annotations)
   ├── kubectl apply ConfigMaps (datasource + dashboard)
   │   └── Grafana sidecars detect and load them
   ├── Port-forward 3000 → localhost:3000 (app)
   ├── Port-forward 3001 → Grafana
   └── Port-forward 9090 → Prometheus

3. Dev modifies src/server.js in VS Code (Dev Container):
   ├── File is on the host filesystem (bind mount)
   ├── Tilt (on host) detects the change (file watcher)
   ├── live_update syncs ./src → /app/src in the pod (kubectl cp)
   ├── restart_process relaunches `node src/server.js` in the container
   └── ~2 seconds later: change visible on localhost:3000

4. Observability loop (continuous):
   ├── Prometheus scrapes localhost:3000/metrics every 15s
   ├── Grafana queries Prometheus to display dashboards
   └── Dev sees the impact of their changes in real time
```

---

## 10. Packaging: Helm and Kustomize

### 10.1 Helm: the Kubernetes package manager

Helm lets you template your Kubernetes manifests and distribute them as "charts". It's the equivalent of a package manager (npm, zypper…) for Kubernetes.

- **values.yaml:** a configuration file to customize deployments per environment (dev, staging, prod).
- **Releases:** Helm tracks deployed versions and enables rollback.
- **Dependencies:** a chart can depend on other charts (e.g., your app + PostgreSQL + Redis).

### 10.2 Kustomize: customization without templates

Kustomize works by **overlaying patches** on base YAML manifests. No template language: you apply declarative transformations.

- Ideal for teams that prefer pure YAML.
- Natively integrated into kubectl (`kubectl apply -k`).

> 💡 **Helm or Kustomize?** — The two are not mutually exclusive. A common approach: use Helm for external charts (databases, monitoring) and Kustomize to customize your own manifests per environment.

---

## 11. Security: scan and sign

### 11.1 Trivy: vulnerability scanner

Trivy (available in Application Collection) scans your container images, Kubernetes files, dependencies, and IaC code to detect known vulnerabilities (CVEs), misconfigurations, and exposed secrets.

```bash
trivy image dp.apps.rancher.io/containers/nodejs:24
trivy k8s --report summary cluster
```

### 11.2 Cosign: image signing

Cosign (available in Application Collection) lets you cryptographically sign your container images. It's a pillar of **supply chain security**.

```bash
cosign sign --key cosign.key myregistry/myapp:v1.0
cosign verify --key cosign.pub myregistry/myapp:v1.0
```

---

## 12. GitOps and Outer Loop

### 12.1 The GitOps paradigm

GitOps is the principle that **Git is the single source of truth** for the desired state of your infrastructure and applications. A deployment tool watches the Git repository and automatically reconciles the cluster state with the state declared in Git.

### 12.2 Argo CD: the GitOps standard for Kubernetes

Argo CD (available in Application Collection) is a declarative continuous deployment tool for Kubernetes.

- **Declarative:** desired state is in Git, not in a CI pipeline.
- **Auto-sync:** automatic drift detection between Git and cluster.
- **Multi-cluster:** manages multiple clusters from a single instance.
- **Web UI:** dashboard to visualize sync status, diffs, history.

### 12.3 Argo Rollouts: advanced deployments

Argo Rollouts (also in Application Collection) adds **blue-green** and **canary** deployment strategies to Kubernetes, with automatic metric analysis to decide whether to promote or rollback a deployment.

---

## 13. The complete workflow

| **#** | **Step** | **Tools** | **Details** |
|---|---|---|---|
| 1 | Open project | VS Code + Dev Containers | Env ready in 30 sec, pre-installed tools |
| 2 | Write code | VS Code + extensions | Editor, autocomplete, lint, Git |
| 3 | Iterate (inner loop) | Tilt | Auto-build + live sync + dashboard |
| 4 | Observe | Prometheus + Grafana | Real-time metrics, auto-provisioned dashboards |
| 5 | Integration tests | Testcontainers | Disposable dependencies (DB, broker) |
| 6 | Security scan | Trivy + Cosign | Vulnerabilities + image signing |
| 7 | Package | Helm / Kustomize | Charts + overlays per environment |
| 8 | Commit + Push | Git | Source of truth for GitOps |
| 9 | Deploy (outer loop) | Argo CD | Automatic sync Git → cluster |
| 10 | Progressive rollout | Argo Rollouts | Canary / Blue-green with analysis |
| _(optional)_ | Debug staging | mirrord | Local process connected to remote cluster |

---

## 14. Principles and best practices

### 14.1 The "12 Factor App" for Kubernetes

- **Configuration via environment:** use ConfigMaps and Secrets, never hardcode config in the image.
- **Stateless processes:** each instance of your app must be identical and replaceable.
- **Port binding:** your app exposes a port, Kubernetes handles routing via Services.
- **Logs to stdout:** never write to log files. Let Kubernetes / Fluent Bit collect stdout.
- **Health checks:** always implement liveness and readiness probes.
- **Metrics:** expose a `/metrics` Prometheus endpoint. Observability is not a luxury, it's a standard.

### 14.2 Minimal images

- **BCI Micro:** for static binaries (Go, Rust). No package manager, minimal attack surface.
- **BCI BusyBox:** for cases requiring a minimal shell.
- **BCI Base:** for cases requiring zypper/RPM.
- Multi-stage builds: build with the dev image, copy the result into BCI Micro.

### 14.3 Infrastructure as Code

- Everything is in Git: Dockerfiles, Helm charts, Kustomize overlays, Tiltfiles, devcontainer.json, **Grafana dashboards**.
- No manual `kubectl apply` in staging/prod. Everything goes through GitOps (Argo CD).
- Ephemeral environments (preview environments) are created automatically on each PR.

---

## 15. Glossary

| **Term** | **Definition** |
|---|---|
| **Inner Loop** | Fast local development cycle: code → build → deploy → test |
| **Outer Loop** | Automated post-commit cycle: CI/CD, tests, deployment |
| **Dev Containers** | Open specification for defining a dev env in a container |
| **DooD** | Docker-outside-of-Docker: pattern where a container uses the host's Docker daemon via mounted socket |
| **Tilt** | Inner loop tool with live_update and web dashboard |
| **Tiltfile** | Tilt config file in Starlark (Python-like DSL) |
| **live_update** | Tilt feature: file sync into a container without rebuild |
| **restart_process** | Tilt extension: restarts the application process after a live_update |
| **mirrord** | Connects a local process to a remote K8s cluster's context |
| **Testcontainers** | Library for containerized dependencies in tests |
| **Helm** | Package manager for Kubernetes (charts) |
| **Kustomize** | K8s manifest customization via patches/overlays |
| **Trivy** | Vulnerability scanner for images, code, IaC |
| **Cosign** | Container image signing/verification tool |
| **Argo CD** | GitOps continuous deployment tool for Kubernetes |
| **Argo Rollouts** | Canary and blue-green deployments for Kubernetes |
| **GitOps** | Paradigm: Git = source of truth for cluster state |
| **Prometheus** | Monitoring system that collects metrics via HTTP scraping |
| **Grafana** | Metrics visualization platform (dashboards) |
| **prom-client** | Node.js library for exposing Prometheus metrics |
| **Sidecar** | Auxiliary container in a pod, running a complementary task |
| **ConfigMap** | K8s resource for storing configuration (here: dashboards, datasources) |
| **k3s** | Lightweight Kubernetes distribution used by Rancher Desktop |
| **BCI** | Base Container Images from SUSE, foundation of Application Collection images |
| **OCI** | Open Container Initiative: standard for container images |
| **imagePullPolicy** | K8s policy: `IfNotPresent` = use local image if available |

---

## 16. Further reading

- **Rancher Desktop:** [rancherdesktop.io](https://rancherdesktop.io)
- **SUSE Application Collection:** [apps.suse.com](https://apps.suse.com)
- **Demo source code:** [github.com/fxHouard/Rancher-Developer-Access-Demo](https://github.com/fxHouard/Rancher-Developer-Access-Demo)
- **Tilt:** [tilt.dev](https://tilt.dev) — and the blog post [Tilt + Rancher Desktop](https://blog.tilt.dev/2021/09/07/rancher-desktop.html)
- **mirrord:** [mirrord.dev](https://mirrord.dev)
- **Testcontainers:** [testcontainers.com](https://testcontainers.com)
- **Dev Containers Spec:** [containers.dev](https://containers.dev)
- **Argo CD:** [argoproj.github.io/cd](https://argoproj.github.io/cd)
- **Helm:** [helm.sh](https://helm.sh)
- **Trivy:** [aquasecurity.github.io/trivy](https://aquasecurity.github.io/trivy)
- **Cosign:** [docs.sigstore.dev/cosign](https://docs.sigstore.dev/cosign)
- **Prometheus:** [prometheus.io](https://prometheus.io)
- **Grafana:** [grafana.com](https://grafana.com)
- **prom-client (Node.js):** [github.com/siimon/prom-client](https://github.com/siimon/prom-client)

---

*Happy Kubernetes development!*