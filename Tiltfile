# ═══════════════════════════════════════════════════════════════════
# SUSE Application Collection — Demo Tiltfile
#
# Deploys a message-wall application using SUSE AppCo images:
#   • PostgreSQL   — AppCo (installed via UI)
#   • Prometheus   — AppCo (installed via UI)
#   • Grafana      — AppCo (installed via UI)
#   • Keycloak     — AppCo container image (deployed by Tilt)
#   • Message-Wall — Built on AppCo base image
#
# Prerequisites:
#   Install PostgreSQL, Prometheus, and Grafana via the Application
#   Collection UI with the values files in values_yaml/.
#
# For the CVE comparison demo (shadow mode), see shadow/README.md.
# ═══════════════════════════════════════════════════════════════════

load('ext://restart_process', 'docker_build_with_restart')

allow_k8s_contexts('rancher-desktop')

# ─── Helpers ───────────────────────────────────────────────────
def find_service(label_selector, ns='default', required=False, name='Service'):
    """Discover a Kubernetes service by label selector in a namespace."""
    svc = str(local(
        "kubectl get svc -n " + ns + " -l " + label_selector +
        " -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo ''",
        quiet=True,
    )).strip()
    if required and svc == '':
        fail(name + ' not found in namespace ' + ns +
             '. Install it via the Application Collection UI first.')
    return svc

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

# Keycloak tag from shadow/versions.env (single source of truth)
V = load_versions('shadow/versions.env')
KEYCLOAK_TAG = V.get('KEYCLOAK_TAG', '26.5.7')

# ═══════════════════════════════════════════════════════════════
# PHASE 1 — Discover AppCo services (installed manually via UI)
# ═══════════════════════════════════════════════════════════════
#
# Before running `tilt up`, install via the Application Collection:
#   • PostgreSQL   (with values_yaml/postgresql.yaml)
#   • Prometheus   (with values_yaml/prometheus.yaml)
#   • Grafana      (with values_yaml/grafana.yaml)
# ───────────────────────────────────────────────────────────────

# PostgreSQL (AppCo — shared by message-wall + keycloak)
pg_appco_svc = find_service(
    'app.kubernetes.io/name=postgresql',
    ns='default',
    required=True,
    name='PostgreSQL (AppCo)',
)

# Ensure keycloak DB exists in AppCo PostgreSQL
pg_pod = str(local(
    "kubectl get pods -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}'",
    quiet=True,
)).strip()

local(
    "kubectl exec " + pg_pod +
    " -- env PGPASSWORD=demo psql -U demo -tc \"SELECT 1 FROM pg_database WHERE datname='keycloak'\"" +
    " | grep -q 1 || kubectl exec " + pg_pod +
    " -- env PGPASSWORD=demo psql -U demo -c 'CREATE DATABASE keycloak'",
    quiet=True,
)

# Prometheus & Grafana (AppCo — optional but recommended)
prometheus_appco_svc = find_service(
    'app.kubernetes.io/name=prometheus,app.kubernetes.io/component=server',
    ns='default',
)
grafana_appco_svc = find_service(
    'app.kubernetes.io/name=grafana',
    ns='default',
)

print('──────────────────────────────────────────────')
print('  AppCo services discovered:')
print('    PostgreSQL: ' + pg_appco_svc)
print('    Prometheus: ' + (prometheus_appco_svc or '(not found)'))
print('    Grafana:    ' + (grafana_appco_svc or '(not found)'))
print('──────────────────────────────────────────────')

# ═══════════════════════════════════════════════════════════════
# PHASE 2 — Message Wall app (AppCo variant)
# ═══════════════════════════════════════════════════════════════

docker_build_with_restart(
    'message-wall-appco',
    '.',
    dockerfile='Dockerfile.appco',
    entrypoint=['node', 'src/server.js'],
    only=['src/', 'package.json'],
    live_update=[
        sync('./src', '/app/src'),
        run('cd /app && npm install --no-package-lock',
            trigger=['package.json']),
    ],
)

# Deploy AppCo message-wall (default namespace)
deployment_appco = str(read_file('k8s/appco/deployment.yaml')).replace(
    'PLACEHOLDER_PG_SVC', pg_appco_svc)
deployment_appco = deployment_appco.replace('namespace: appco\n', '')

service_appco = str(read_file('k8s/appco/service.yaml')).replace(
    'namespace: appco\n', '')

k8s_yaml([blob(deployment_appco), blob(service_appco)])

k8s_resource(
    'message-wall-appco',
    port_forwards='3000:3000',
    labels=['appco'],
)

# ═══════════════════════════════════════════════════════════════
# PHASE 3 — Keycloak (Identity & Access Management)
#
# AppCo Keycloak: container image only (no Helm chart on AppCo),
#   so Tilt deploys it directly using the AppCo container image.
# ═══════════════════════════════════════════════════════════════

# Keycloak realm ConfigMap (auto-import realm with demo user + message-wall client)
local('kubectl create configmap keycloak-realm --from-file=message-wall.json=k8s/shared/keycloak-realm.json --dry-run=client -o yaml | kubectl apply -f -', quiet=True)

# Keycloak AppCo — deployed by Tilt (no Helm chart available on AppCo)
# Tag from shadow/versions.env (single source of truth for keycloak version)
keycloak_appco_yaml = str(read_file('k8s/appco/keycloak.yaml')).replace(
    'PLACEHOLDER_PG_SVC', pg_appco_svc).replace(
    'PLACEHOLDER_KEYCLOAK_TAG', KEYCLOAK_TAG)
k8s_yaml(blob(keycloak_appco_yaml))

k8s_resource(
    'keycloak-appco',
    port_forwards='8080:8080',
    labels=['appco'],
)

# Keycloak realm setup via Admin REST API (idempotent)
local_resource(
    'keycloak-realm-setup',
    cmd='bash scripts/setup-keycloak-realm.sh http://localhost:8080 k8s/shared/keycloak-realm.json',
    labels=['appco'],
    resource_deps=['keycloak-appco'],
)

# ═══════════════════════════════════════════════════════════════
# PHASE 4 — Grafana Dashboard & Port Forwards
# ═══════════════════════════════════════════════════════════════

# Grafana dashboard for message-wall metrics
k8s_yaml('k8s/shared/grafana-dashboard.yaml')

if grafana_appco_svc:
    local_resource(
        'grafana-appco-ui',
        serve_cmd='kubectl port-forward svc/' + grafana_appco_svc + ' 3200:80',
        labels=['appco'],
        allow_parallel=True,
        links=['http://localhost:3200'],
    )

if prometheus_appco_svc:
    local_resource(
        'prometheus-appco-ui',
        serve_cmd='kubectl port-forward svc/' + prometheus_appco_svc + ' 9190:80',
        labels=['appco'],
        allow_parallel=True,
        links=['http://localhost:9190'],
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
""".format(svc=prometheus_appco_svc)
    k8s_yaml(blob(datasource_cm))

    k8s_resource(
        objects=['message-wall-dashboard:configmap',
                 'grafana-datasource-prometheus:configmap'],
        new_name='grafana-config',
        labels=['appco'],
        links=[
            'http://localhost:3200/d/message-wall/',
        ],
    )
