# Demo Tiltfile
load('ext://restart_process', 'docker_build_with_restart')

allow_k8s_contexts('rancher-desktop')

# ─── PostgreSQL (installed via SUSE Rancher Developer Access) ───────────
pg_svc = str(local(
    "kubectl get svc -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}'",
    quiet=True,
)).strip()
if pg_svc == '':
    fail('PostgreSQL not found. Install it using SUSE Rancher Developer Access.')

# ─── Our application ───────────────────────────────────────────
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

deployment = str(read_file('k8s/deployment.yaml')).replace('demo-db-postgresql', pg_svc)
k8s_yaml([blob(deployment), 'k8s/service.yaml', 'k8s/grafana-dashboard.yaml'])

k8s_resource(
    'message-wall',
    port_forwards='3000:3000',
    labels=['app'],
)
k8s_resource(
    objects=['message-wall-dashboard:configmap'],
    new_name='grafana-dashboard',
    labels=['monitoring'],
    links=['http://localhost:3001/d/message-wall/']
)
# ─── Monitoring (installed via SUSE Rancher Developer Access, tilt handles port forwards) ─
grafana_svc = str(local(
    "kubectl get svc -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}'",
    quiet=True,
)).strip()

prometheus_svc = str(local(
    "kubectl get svc -l app.kubernetes.io/name=prometheus,app.kubernetes.io/component=server -o jsonpath='{.items[0].metadata.name}'",
    quiet=True,
)).strip()

if grafana_svc:
    local_resource(
        'grafana',
        serve_cmd='kubectl port-forward svc/' + grafana_svc + ' 3001:80',
        labels=['monitoring'],
        allow_parallel=True,
        links=['http://localhost:3001', 'http://localhost:3001/d/message-wall/'],

        
    )

if prometheus_svc:
    local_resource(
        'prometheus',
        serve_cmd='kubectl port-forward svc/' + prometheus_svc + ' 9090:80',
        labels=['monitoring'],
        allow_parallel=True,
        links=['http://localhost:9090'],

    )
