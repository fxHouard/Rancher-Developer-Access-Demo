# ═══════════════════════════════════════════════════════════════════
# Message Wall — Public Images Demo Tiltfile
#
# Deploys a message-wall application using public upstream images
# INTO THE `public` NAMESPACE, so it can coexist with the AppCo
# comparison demo (which uses `default` for AppCo workloads).
#
# Components:
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

NS = 'public'

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

def in_ns(yaml_str):
    """Inject `namespace: public` right after each top-level `metadata:` block.
    Matches the pattern `metadata:\n  name: ` (2-space indent → top-level
    metadata only, never container names which use 6+ space indent)."""
    return yaml_str.replace(
        'metadata:\n  name: ',
        'metadata:\n  namespace: ' + NS + '\n  name: ')

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
print('  Namespace: ' + NS)
print('  Image versions (from versions.env):')
print('    postgres:    ' + POSTGRES_TAG)
print('    prometheus:  ' + PROMETHEUS_TAG)
print('    grafana:     ' + GRAFANA_TAG)
print('    keycloak:    ' + KEYCLOAK_TAG)
print('    node:        ' + NODE_TAG)
print('    trivy:       ' + TRIVY_TAG)
print('──────────────────────────────────────────────')

# ═══════════════════════════════════════════════════════════════
# PHASE 0 — Ensure the `public` namespace exists
# ═══════════════════════════════════════════════════════════════
local('kubectl get ns ' + NS + ' >/dev/null 2>&1 || kubectl create ns ' + NS, quiet=True)

# ═══════════════════════════════════════════════════════════════
# PHASE 1 — Infrastructure (PostgreSQL, Prometheus, Grafana)
# ═══════════════════════════════════════════════════════════════

# PostgreSQL (official Docker Hub image)
pg_yaml = in_ns(str(read_file('k8s/postgresql.yaml')).replace(
    'PLACEHOLDER_POSTGRES_TAG', POSTGRES_TAG))
k8s_yaml(blob(pg_yaml))

k8s_resource(
    'demo-postgresql',
    labels=['public'],
)

# Ensure keycloak DB in PostgreSQL (wait for pod to be ready)
local_resource(
    'pg-keycloak-db',
    cmd="kubectl -n " + NS + " wait --for=condition=ready pod/demo-postgresql-0 --timeout=120s && (kubectl -n " + NS + " exec demo-postgresql-0 -- env PGPASSWORD=demo psql -U demo -tc \"SELECT 1 FROM pg_database WHERE datname='keycloak'\" | grep -q 1 || kubectl -n " + NS + " exec demo-postgresql-0 -- env PGPASSWORD=demo psql -U demo -c 'CREATE DATABASE keycloak')",
    labels=['public'],
    resource_deps=['demo-postgresql'],
)

# Prometheus (via Helm)
local('helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true', quiet=True)
local('helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true', quiet=True)
local('helm repo update', quiet=True)

local_resource(
    'prometheus',
    cmd='helm upgrade --install prometheus prometheus-community/prometheus --namespace ' + NS + ' -f values_yaml/prometheus.yaml --set server.image.tag=' + PROMETHEUS_TAG + ' --set server.ingress.hosts[0]=prometheus.localhost --wait --cleanup-on-fail --timeout 5m',
    labels=['public'],
    links=['http://prometheus.localhost'],
    resource_deps=['demo-postgresql'],
)

# Grafana (via Helm)
local_resource(
    'grafana',
    cmd='helm upgrade --install grafana grafana/grafana --namespace ' + NS + ' -f values_yaml/grafana.yaml --set image.tag=' + GRAFANA_TAG + ' --set ingress.hosts[0]=grafana.localhost --wait --cleanup-on-fail --timeout 5m',
    labels=['public'],
    links=[
        'http://grafana.localhost',
        'http://grafana.localhost/d/message-wall/',
        'http://grafana.localhost/d/cve-scan/',
    ],
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

deployment_yaml = in_ns(str(read_file('k8s/deployment.yaml')).replace(
    'PLACEHOLDER_PG_SVC', 'demo-postgresql'))
service_yaml = in_ns(str(read_file('k8s/service.yaml')))
k8s_yaml([blob(deployment_yaml), blob(service_yaml)])

k8s_resource(
    'message-wall',
    objects=['message-wall:ingress'],
    labels=['public'],
    links=['http://message-wall.localhost'],
    resource_deps=['demo-postgresql'],
)

# ═══════════════════════════════════════════════════════════════
# PHASE 3 — Keycloak (Identity & Access Management)
# ═══════════════════════════════════════════════════════════════

# Keycloak realm ConfigMap
local('kubectl create configmap keycloak-realm --namespace ' + NS + ' --from-file=message-wall.json=k8s/shared/keycloak-realm.json --dry-run=client -o yaml | kubectl apply -f -', quiet=True)

# Keycloak (upstream Quay.io image)
keycloak_yaml = in_ns(str(read_file('k8s/keycloak.yaml')).replace(
    'PLACEHOLDER_KEYCLOAK_TAG', KEYCLOAK_TAG))
k8s_yaml(blob(keycloak_yaml))

k8s_resource(
    'keycloak',
    objects=['keycloak:ingress'],
    labels=['public'],
    links=['http://keycloak.localhost'],
    resource_deps=['pg-keycloak-db'],
)

# Keycloak realm setup via Admin REST API (idempotent).
# Hits the ingress on http://keycloak.localhost — Traefik routes by Host
# header, no port-forward needed. Works in any browser/curl that honors
# RFC 6761 *.localhost short-circuit (macOS, Linux+systemd, all browsers).
local_resource(
    'keycloak-realm-setup',
    cmd='bash scripts/setup-keycloak-realm.sh http://keycloak.localhost k8s/shared/keycloak-realm.json',
    labels=['public'],
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

# Deploy exporter (yaml is ns-agnostic → inject namespace)
cve_exporter_yaml = in_ns(str(read_file('k8s/shared/cve-exporter.yaml')))
k8s_yaml(blob(cve_exporter_yaml))

k8s_resource(
    'cve-exporter',
    labels=['cve-scan'],
)

# Trivy scan (public images only — discovery runs in NS)
local_resource(
    'trivy-scan',
    cmd='TRIVY_IMAGE=aquasec/trivy:' + TRIVY_TAG + ' NS=' + NS + ' bash scripts/trivy-scan.sh',
    labels=['cve-scan'],
    resource_deps=['message-wall', 'keycloak',
                   'demo-postgresql', 'prometheus', 'grafana'],
)

# Restart cve-exporter after each scan
local_resource(
    'cve-exporter-reload',
    cmd='kubectl -n ' + NS + ' rollout restart deployment/cve-exporter && kubectl -n ' + NS + ' rollout status deployment/cve-exporter --timeout=60s',
    labels=['cve-scan'],
    resource_deps=['trivy-scan', 'cve-exporter'],
)

# ═══════════════════════════════════════════════════════════════
# PHASE 5 — Grafana Dashboard & Port Forwards
# ═══════════════════════════════════════════════════════════════

# Grafana dashboards (message-wall metrics + CVE scan results)
dash_mw  = in_ns(str(read_file('k8s/shared/grafana-dashboard.yaml')))
dash_cve = in_ns(str(read_file('k8s/shared/grafana-cve-dashboard.yaml')))
k8s_yaml([blob(dash_mw), blob(dash_cve)])

# Label the dashboard ConfigMaps so they don't show up as "uncategorized"
# in the Tilt UI even when prometheus_svc discovery fails below.
k8s_resource(
    objects=['message-wall-dashboard:configmap',
             'cve-dashboard:configmap'],
    new_name='grafana-dashboards',
    labels=['public'],
)

# Grafana / Prometheus are exposed via Traefik ingress (see
# values_yaml/*.yaml + helm --set ingress.hosts[0]=… in the
# `prometheus` / `grafana` resources above). Browser access goes
# through http://{grafana,prometheus}.localhost — no port-forward.
#
# Datasource still uses the in-cluster Service DNS (Helm release name
# is deterministic).
PROMETHEUS_SVC = 'prometheus-server'

datasource_cm = """apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasource-prometheus
  namespace: {ns}
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
""".format(ns=NS, svc=PROMETHEUS_SVC)
k8s_yaml(blob(datasource_cm))

k8s_resource(
    objects=['grafana-datasource-prometheus:configmap'],
    new_name='grafana-datasource',
    labels=['public'],
)
