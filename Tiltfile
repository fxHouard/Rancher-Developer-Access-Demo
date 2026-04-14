# ═══════════════════════════════════════════════════════════════════
# Message Wall — Public Images Demo Tiltfile
#
# Deploys a message-wall application using public upstream images:
#   • PostgreSQL   — docker.io/library/postgres
#   • Prometheus   — prom/prometheus (Helm)
#   • Grafana      — grafana/grafana (Helm)
#   • Keycloak     — quay.io/keycloak/keycloak
#   • Message-Wall — Built on docker.io/library/node base
#
# CVE scanning with Trivy is included — results are displayed
# in a Grafana dashboard.
#
# For the full AppCo vs Public comparison demo, see:
#   Rancher Developer Access/README.md
# ═══════════════════════════════════════════════════════════════════

load('ext://restart_process', 'docker_build_with_restart')

allow_k8s_contexts('rancher-desktop')

# ─── Helpers ───────────────────────────────────────────────────
def load_versions(path):
    """Parse a KEY=VALUE env file (ignores comments and blank lines)."""
    versions = {}
    for line in str(read_file(path)).splitlines():
        line = line.strip()
        if line == '' or line.startswith('#'):
            continue
        if '=' in line:
            k, v = line.split('=', 1)
            versions[k.strip()] = v.strip()
    return versions

# ═══════════════════════════════════════════════════════════════
# Load pinned image versions from versions.env
# ═══════════════════════════════════════════════════════════════
V = load_versions('versions.env')
POSTGRES_TAG   = V.get('POSTGRES_TAG',   '18')
PROMETHEUS_TAG = V.get('PROMETHEUS_TAG',  'v3.11.1')
GRAFANA_TAG    = V.get('GRAFANA_TAG',    '12.4.2')
KEYCLOAK_TAG   = V.get('KEYCLOAK_TAG',   '26.5.7')
NODE_TAG       = V.get('NODE_TAG',       '24')
TRIVY_TAG      = V.get('TRIVY_TAG',      '0.69.3')

print('──────────────────────────────────────────────')
print('  Image versions (from versions.env):')
print('    postgres:    ' + POSTGRES_TAG)
print('    prometheus:  ' + PROMETHEUS_TAG)
print('    grafana:     ' + GRAFANA_TAG)
print('    keycloak:    ' + KEYCLOAK_TAG)
print('    node:        ' + NODE_TAG)
print('    trivy:       ' + TRIVY_TAG)
print('──────────────────────────────────────────────')

# ═══════════════════════════════════════════════════════════════
# PHASE 1 — Infrastructure (PostgreSQL, Prometheus, Grafana)
# ═══════════════════════════════════════════════════════════════

# PostgreSQL (official Docker Hub image)
pg_yaml = str(read_file('k8s/postgresql.yaml')).replace(
    'PLACEHOLDER_POSTGRES_TAG', POSTGRES_TAG)
k8s_yaml(blob(pg_yaml))

k8s_resource(
    'demo-postgresql',
    labels=['infra'],
)

# Ensure keycloak DB in PostgreSQL (wait for pod to be ready)
local_resource(
    'pg-keycloak-db',
    cmd="kubectl wait --for=condition=ready pod/demo-postgresql-0 --timeout=120s && (kubectl exec demo-postgresql-0 -- env PGPASSWORD=demo psql -U demo -tc \"SELECT 1 FROM pg_database WHERE datname='keycloak'\" | grep -q 1 || kubectl exec demo-postgresql-0 -- env PGPASSWORD=demo psql -U demo -c 'CREATE DATABASE keycloak')",
    labels=['infra'],
    resource_deps=['demo-postgresql'],
)

# Prometheus (via Helm)
local('helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true', quiet=True)
local('helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true', quiet=True)
local('helm repo update', quiet=True)

local_resource(
    'prometheus',
    cmd='helm upgrade --install prometheus prometheus-community/prometheus -f values_yaml/prometheus.yaml --set server.image.tag=' + PROMETHEUS_TAG + ' --wait --cleanup-on-fail --timeout 5m',
    labels=['infra'],
    resource_deps=['demo-postgresql'],
)

# Grafana (via Helm)
local_resource(
    'grafana',
    cmd='helm upgrade --install grafana grafana/grafana -f values_yaml/grafana.yaml --set image.tag=' + GRAFANA_TAG + ' --wait --cleanup-on-fail --timeout 5m',
    labels=['infra'],
    resource_deps=['demo-postgresql'],
)

# ═══════════════════════════════════════════════════════════════
# PHASE 2 — Message Wall app
# ═══════════════════════════════════════════════════════════════

docker_build_with_restart(
    'message-wall',
    '.',
    dockerfile='Dockerfile',
    entrypoint=['node', 'src/server.js'],
    only=['src/', 'package.json'],
    build_args={'NODE_TAG': NODE_TAG},
    live_update=[
        sync('./src', '/app/src'),
        run('cd /app && npm install --no-package-lock',
            trigger=['package.json']),
    ],
)

deployment_yaml = str(read_file('k8s/deployment.yaml')).replace(
    'PLACEHOLDER_PG_SVC', 'demo-postgresql')
k8s_yaml([blob(deployment_yaml), 'k8s/service.yaml'])

k8s_resource(
    'message-wall',
    port_forwards='3000:3000',
    labels=['app'],
    resource_deps=['demo-postgresql'],
)

# ═══════════════════════════════════════════════════════════════
# PHASE 3 — Keycloak (Identity & Access Management)
# ═══════════════════════════════════════════════════════════════

# Keycloak realm ConfigMap
local('kubectl create configmap keycloak-realm --from-file=message-wall.json=k8s/shared/keycloak-realm.json --dry-run=client -o yaml | kubectl apply -f -', quiet=True)

# Keycloak (upstream Quay.io image)
keycloak_yaml = str(read_file('k8s/keycloak.yaml')).replace(
    'PLACEHOLDER_KEYCLOAK_TAG', KEYCLOAK_TAG)
k8s_yaml(blob(keycloak_yaml))

k8s_resource(
    'keycloak',
    port_forwards='8080:8080',
    labels=['app'],
    resource_deps=['pg-keycloak-db'],
)

# Keycloak realm setup via Admin REST API (idempotent)
local_resource(
    'keycloak-realm-setup',
    cmd='bash scripts/setup-keycloak-realm.sh http://localhost:8080 k8s/shared/keycloak-realm.json',
    labels=['app'],
    resource_deps=['keycloak'],
)

# ═══════════════════════════════════════════════════════════════
# PHASE 4 — CVE Scanning + Exporter
# ═══════════════════════════════════════════════════════════════

# Build the CVE exporter
docker_build(
    'cve-exporter',
    '.',
    dockerfile='Dockerfile.cve-exporter',
    only=['scripts/cve-exporter.py'],
)

# Deploy exporter
k8s_yaml('k8s/shared/cve-exporter.yaml')

k8s_resource(
    'cve-exporter',
    labels=['cve-scan'],
)

# Trivy scan (public images only)
local_resource(
    'trivy-scan',
    cmd='TRIVY_IMAGE=aquasec/trivy:' + TRIVY_TAG + ' bash scripts/trivy-scan.sh',
    labels=['cve-scan'],
    resource_deps=['message-wall', 'keycloak',
                   'demo-postgresql', 'prometheus', 'grafana'],
)

# Restart cve-exporter after each scan
local_resource(
    'cve-exporter-reload',
    cmd='kubectl rollout restart deployment/cve-exporter && kubectl rollout status deployment/cve-exporter --timeout=60s',
    labels=['cve-scan'],
    resource_deps=['trivy-scan', 'cve-exporter'],
)

# ═══════════════════════════════════════════════════════════════
# PHASE 5 — Grafana Dashboard & Port Forwards
# ═══════════════════════════════════════════════════════════════

# Grafana dashboards (message-wall metrics + CVE scan results)
k8s_yaml('k8s/shared/grafana-dashboard.yaml')
k8s_yaml('k8s/shared/grafana-cve-dashboard.yaml')

# Discover Grafana and Prometheus services
def find_service(label_selector, ns='default'):
    svc = str(local(
        "kubectl get svc -n " + ns + " -l " + label_selector +
        " -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo ''",
        quiet=True,
    )).strip()
    return svc

prometheus_svc = find_service(
    'app.kubernetes.io/instance=prometheus,app.kubernetes.io/component=server',
)
grafana_svc = find_service(
    'app.kubernetes.io/instance=grafana',
)

if grafana_svc:
    local_resource(
        'grafana-ui',
        serve_cmd='kubectl port-forward svc/' + grafana_svc + ' 3001:80',
        labels=['monitoring'],
        allow_parallel=True,
        links=['http://localhost:3001'],
    )

if prometheus_svc:
    local_resource(
        'prometheus-ui',
        serve_cmd='kubectl port-forward svc/' + prometheus_svc + ' 9090:80',
        labels=['monitoring'],
        allow_parallel=True,
        links=['http://localhost:9090'],
    )

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

    k8s_resource(
        objects=['message-wall-dashboard:configmap',
                 'cve-dashboard:configmap',
                 'grafana-datasource-prometheus:configmap'],
        new_name='grafana-config',
        labels=['monitoring'],
        links=[
            'http://localhost:3001/d/message-wall/',
            'http://localhost:3001/d/cve-scan/',
        ],
    )
