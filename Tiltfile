# Demo Tiltfile
load('ext://restart_process', 'docker_build_with_restart')

allow_k8s_contexts('rancher-desktop')

# ─── Helpers ────────────────────────────────────────────────────
def find_service(label_selector, required=False, name='Service'):
    # Discover a Kubernetes service by label selector.
    #
    # Helm charts installed via Rancher Desktop get random release
    # names (e.g. postgresql-1772033328). Searching by label is
    # robust regardless of the release name.
    svc = str(local(
        "kubectl get svc -l " + label_selector +
        " -o jsonpath='{.items[0].metadata.name}'",
        quiet=True,
    )).strip()
    if required and svc == '':
        fail(name + ' not found. Install it via Rancher Desktop ' +
             '(Application Collection).')
    return svc

# ─── Service discovery ──────────────────────────────────────────
pg_svc = find_service(
    'app.kubernetes.io/name=postgresql',
    required=True,
    name='PostgreSQL',
)
grafana_svc = find_service('app.kubernetes.io/name=grafana')
prometheus_svc = find_service(
    'app.kubernetes.io/name=prometheus,app.kubernetes.io/component=server',
)

# ─── Application ────────────────────────────────────────────────
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

# ─── Monitoring (optional) ──────────────────────────────────────
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
                 'grafana-datasource-prometheus:configmap'],
        new_name='grafana-config',
        labels=['monitoring'],
        links=['http://localhost:3001/d/message-wall/'],
    )