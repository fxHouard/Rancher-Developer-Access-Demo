#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# Trivy Scan — runs as a Kubernetes Job inside the cluster
#
# Discovers images from running pods, then launches a Trivy
# scan Job that accesses the container runtime via hostPath.
# Results are saved to a ConfigMap for the CVE exporter.
#
# Components: postgresql, prometheus, alertmanager, node-exporter,
#             grafana, message-wall, keycloak, trivy
# ═══════════════════════════════════════════════════════════════
set -uo pipefail

RESULTS_FILE="${RESULTS_FILE:-/tmp/cve-results.json}"
CONFIGMAP_NAME="cve-results"
JOB_NAME="trivy-scan"
TRIVY_IMAGE="${TRIVY_IMAGE:-aquasec/trivy:0.69.3}"

echo "═══════════════════════════════════════════════════"
echo "  Trivy Scan — K8s Job"
echo "  Scanner: $TRIVY_IMAGE"
echo "  Components: postgresql, prometheus, alertmanager,"
echo "    node-exporter, grafana, message-wall, keycloak, trivy"
echo "═══════════════════════════════════════════════════"

# ─── Helpers ─────────────────────────────────────────────────
get_pod_image() {
    local ns="$1" label="$2" container="$3"
    local img
    img=$(kubectl get pods -n "$ns" -l "$label" \
        -o jsonpath="{.items[0].spec.containers[?(@.name==\"$container\")].image}" 2>/dev/null || echo "")
    if [ -z "$img" ]; then
        img=$(kubectl get pods -n "$ns" -l "$label" \
            -o jsonpath="{.items[0].spec.containers[0].image}" 2>/dev/null || echo "")
    fi
    echo "$img"
}

get_tilt_image() {
    local name="$1"
    docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
        | grep "^${name}:" | head -1 || echo "${name}:latest"
}

# ─── Discover images ─────────────────────────────────────────
echo ""
echo "── Discovering images from running pods... ──"

# AppCo (default namespace)
APPCO_PG=$(get_pod_image default "app.kubernetes.io/name=postgresql" "postgresql")
APPCO_PROM=$(get_pod_image default "app.kubernetes.io/name=prometheus,app.kubernetes.io/component=server" "prometheus-server")
APPCO_ALERT=$(get_pod_image default "app.kubernetes.io/name=alertmanager" "alertmanager")
APPCO_NODEEXP=$(get_pod_image default "app.kubernetes.io/name=prometheus-node-exporter" "node-exporter")
APPCO_GRAF=$(get_pod_image default "app.kubernetes.io/name=grafana" "grafana")
APPCO_KC=$(get_pod_image default "app=keycloak,variant=appco" "keycloak")
APPCO_MW=$(get_tilt_image "message-wall-appco")

# Public (public namespace) — uses prometheus-community/prometheus chart
PUB_PG=$(get_pod_image public "app.kubernetes.io/name=postgresql" "postgresql")
PUB_PROM=$(get_pod_image public "app.kubernetes.io/name=prometheus,app.kubernetes.io/component=server" "prometheus-server")
PUB_ALERT=$(get_pod_image public "app.kubernetes.io/name=alertmanager" "alertmanager")
PUB_NODEEXP=$(get_pod_image public "app.kubernetes.io/name=prometheus-node-exporter" "node-exporter")
PUB_GRAF=$(get_pod_image public "app.kubernetes.io/name=grafana" "grafana")
PUB_KC=$(get_pod_image public "app=keycloak,variant=public" "keycloak")
PUB_MW=$(get_tilt_image "message-wall-public")

# Trivy itself — AppCo vs public (meta: scanning the scanner!)
# APPCO_TRIVY_TAG comes from versions.env (includes SUSE patch suffix)
# Public trivy = the same image used to run this scan
APPCO_TRIVY="dp.apps.rancher.io/containers/trivy:${APPCO_TRIVY_TAG:-${TRIVY_IMAGE#*:}}"
PUB_TRIVY="${TRIVY_IMAGE}"

echo ""
echo "  AppCo images:"
echo "    postgresql:    ${APPCO_PG:-unknown}"
echo "    prometheus:    ${APPCO_PROM:-unknown}"
echo "    alertmanager:  ${APPCO_ALERT:-unknown}"
echo "    node-exporter: ${APPCO_NODEEXP:-unknown}"
echo "    grafana:       ${APPCO_GRAF:-unknown}"
echo "    keycloak:      ${APPCO_KC:-unknown}"
echo "    message-wall:  ${APPCO_MW:-unknown}"
echo "    trivy:         ${APPCO_TRIVY}"
echo ""
echo "  Public images:"
echo "    postgresql:    ${PUB_PG:-unknown}"
echo "    prometheus:    ${PUB_PROM:-unknown}"
echo "    alertmanager:  ${PUB_ALERT:-unknown}"
echo "    node-exporter: ${PUB_NODEEXP:-unknown}"
echo "    grafana:       ${PUB_GRAF:-unknown}"
echo "    keycloak:      ${PUB_KC:-unknown}"
echo "    message-wall:  ${PUB_MW:-unknown}"
echo "    trivy:         ${PUB_TRIVY}"

# ─── Build image scan list ───────────────────────────────────
# Format: project|application|name|image|base_image (one per line)
# application groups components (e.g. prometheus includes server, alertmanager, node-exporter)
# base_image is the FROM image for custom-built images (message-wall)
# 8 components × 2 variants = 16 images
IMAGE_LIST="appco-images|postgresql|postgresql|${APPCO_PG}|
appco-images|prometheus|prometheus|${APPCO_PROM}|
appco-images|prometheus|alertmanager|${APPCO_ALERT}|
appco-images|prometheus|node-exporter|${APPCO_NODEEXP}|
appco-images|grafana|grafana|${APPCO_GRAF}|
appco-images|trivy|trivy|${APPCO_TRIVY}|
appco-images|keycloak|keycloak|${APPCO_KC}|
appco-images|message-wall|message-wall|${APPCO_MW}|nodejs:24-dev (AppCo)
public-images|postgresql|postgresql|${PUB_PG}|
public-images|prometheus|prometheus|${PUB_PROM}|
public-images|prometheus|alertmanager|${PUB_ALERT}|
public-images|prometheus|node-exporter|${PUB_NODEEXP}|
public-images|grafana|grafana|${PUB_GRAF}|
public-images|trivy|trivy|${PUB_TRIVY}|
public-images|keycloak|keycloak|${PUB_KC}|
public-images|message-wall|message-wall|${PUB_MW}|node:24
"

# ─── Create scan script as ConfigMap ─────────────────────────
kubectl create configmap trivy-scan-script --dry-run=client -o yaml \
  --from-literal=scan.sh='#!/bin/sh
# NOTE: no "set -e" — we want to continue even if one scan fails

echo "=== Trivy scan starting ==="

# Install jq (Alpine-based image)
echo "Installing jq..."
apk add --no-cache jq >/dev/null 2>&1 || true

echo "Downloading vulnerability databases..."
trivy image --download-db-only 2>&1 | tail -5
trivy image --download-java-db-only 2>&1 | tail -5
echo "DB ready."

# Setup Docker config for AppCo registry (from mounted secret)
if [ -f /dockerconfig/.dockerconfigjson ]; then
    mkdir -p /root/.docker
    cp /dockerconfig/.dockerconfigjson /root/.docker/config.json
    echo "Docker registry credentials loaded."
fi

IMAGES_FILE="/config/images.txt"
RESULTS_FILE="/tmp/results.json"
echo "[" > "$RESULTS_FILE"
first=true

while IFS="|" read -r project application name image base_image; do
    [ -z "$image" ] && continue
    echo ""
    echo "  ── Scanning: $project/$application/$name ──"
    echo "     Image: $image"
    [ -n "$base_image" ] && echo "     Base:  $base_image"

    # Run trivy — JSON to stdout file, stderr to log file
    raw=""
    SCAN_JSON="/tmp/scan_${project}_${name}.json"
    SCAN_LOG="/tmp/scan_${project}_${name}.log"
    if trivy image --format json --skip-db-update \
        --timeout 600s \
        --severity CRITICAL,HIGH,MEDIUM,LOW \
        "$image" > "$SCAN_JSON" 2>"$SCAN_LOG"; then
        raw=$(cat "$SCAN_JSON")
        echo "     Scan OK ($(wc -c < "$SCAN_JSON") bytes)"
    else
        echo "     Scan FAILED (exit $?)"
        cat "$SCAN_LOG" >&2
        raw=$(cat "$SCAN_JSON")
    fi

    # Try to parse with jq, fall back to error entry
    entry=""
    if [ -n "$raw" ]; then
        entry=$(echo "$raw" | jq -c --arg proj "$project" --arg app "$application" --arg repo "$name" --arg img "$image" --arg base "${base_image:-}" \
            '"'"'{
                project: $proj,
                application: $app,
                repository: $repo,
                image: $img,
                base_image: $base,
                base_os: (([.Results[]? | select(.Class == "os-pkgs") | .Target | capture("\\((?<os>[^)]+)\\)$").os // .] | first) // ""),
                Critical: ([.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL")] | length),
                High:     ([.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH")] | length),
                Medium:   ([.Results[]?.Vulnerabilities[]? | select(.Severity=="MEDIUM")] | length),
                Low:      ([.Results[]?.Vulnerabilities[]? | select(.Severity=="LOW")] | length),
                Total:    ([.Results[]?.Vulnerabilities[]?] | length),
                status: "success"
            }'"'"' 2>/dev/null)
    fi

    # Fallback if jq parsing failed
    if [ -z "$entry" ] || [ "$entry" = "null" ]; then
        entry="{\"project\":\"$project\",\"application\":\"$application\",\"repository\":\"$name\",\"image\":\"$image\",\"base_image\":\"${base_image:-}\",\"base_os\":\"\",\"Critical\":0,\"High\":0,\"Medium\":0,\"Low\":0,\"Total\":0,\"status\":\"error\"}"
        echo "     Using error fallback entry"
    else
        total=$(echo "$entry" | jq -r .Total 2>/dev/null || echo "?")
        echo "     Found $total CVEs"
    fi

    if [ "$first" = true ]; then
        first=false
    else
        printf "," >> "$RESULTS_FILE"
    fi
    printf "%s" "$entry" >> "$RESULTS_FILE"

done < "$IMAGES_FILE"

echo "]" >> "$RESULTS_FILE"

echo ""
echo "=== SCAN_RESULTS_JSON_START ==="
cat "$RESULTS_FILE" | jq . 2>/dev/null || cat "$RESULTS_FILE"
echo "=== SCAN_RESULTS_JSON_END ==="
echo "=== Trivy scan complete ==="
' \
  --from-literal=images.txt="$IMAGE_LIST" \
  | kubectl apply -f -

# ─── Clean up old job ────────────────────────────────────────
kubectl delete job "$JOB_NAME" --ignore-not-found 2>/dev/null
sleep 2

# ─── Launch scan Job ─────────────────────────────────────────
echo ""
echo "── Launching Trivy scan Job in K8s... ──"

cat <<JOBEOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
spec:
  ttlSecondsAfterFinished: 300
  backoffLimit: 0
  template:
    spec:
      containers:
      - name: trivy
        image: ${TRIVY_IMAGE}
        command: ["/bin/sh", "/config/scan.sh"]
        volumeMounts:
        - name: scan-config
          mountPath: /config
        - name: docker-sock
          mountPath: /var/run/docker.sock
        - name: trivy-cache
          mountPath: /root/.cache
        - name: docker-config
          mountPath: /dockerconfig
          readOnly: true
        resources:
          requests:
            memory: 1Gi
            cpu: 500m
          limits:
            memory: 6Gi
      volumes:
      - name: scan-config
        configMap:
          name: trivy-scan-script
          defaultMode: 0755
      - name: docker-sock
        hostPath:
          path: /var/run/docker.sock
          type: Socket
      - name: trivy-cache
        emptyDir:
          sizeLimit: 3Gi
      - name: docker-config
        secret:
          secretName: application-collection
          optional: true
      restartPolicy: Never
      imagePullSecrets:
      - name: application-collection
JOBEOF

# ─── Wait for completion ─────────────────────────────────────
echo "  Waiting for scan to complete (this may take several minutes on first run)..."
echo "  Follow progress: kubectl logs -f job/${JOB_NAME}"

if ! kubectl wait --for=condition=complete "job/${JOB_NAME}" --timeout=900s 2>/dev/null; then
    echo "❌ Scan job failed or timed out. Check logs:"
    echo "   kubectl logs job/${JOB_NAME}"
    kubectl logs "job/${JOB_NAME}" --tail=20 2>/dev/null || true
    exit 1
fi

# ─── Extract results ─────────────────────────────────────────
echo "  Extracting results..."

# Get logs — extract JSON between our markers
LOGS=$(kubectl logs "job/${JOB_NAME}" 2>/dev/null)

# Extract between markers
JSON_BLOCK=$(echo "$LOGS" | sed -n '/=== SCAN_RESULTS_JSON_START ===/,/=== SCAN_RESULTS_JSON_END ===/p' | grep -v '=== SCAN_RESULTS')

if [ -z "$JSON_BLOCK" ]; then
    echo "⚠️  No JSON markers found, trying raw extraction..."
    # Fallback: find the JSON array in the logs
    JSON_BLOCK=$(echo "$LOGS" | grep -A 9999 '^\[' | head -n -1)
fi

if [ -z "$JSON_BLOCK" ]; then
    echo "❌ Could not extract results from job logs."
    echo "   Full logs:"
    echo "$LOGS"
    exit 1
fi

echo "$JSON_BLOCK" > "$RESULTS_FILE"

echo "✅ Scan complete → $RESULTS_FILE"

# ─── Create/update ConfigMap ─────────────────────────────────
kubectl create configmap "$CONFIGMAP_NAME" \
    --from-file=cve-results.json="$RESULTS_FILE" \
    --dry-run=client -o yaml | kubectl apply -f -

echo "✅ ConfigMap '$CONFIGMAP_NAME' updated"

# ─── Quick summary (using jq, no python3 needed) ─────────────
echo ""
APPCO_TOTAL=$(cat "$RESULTS_FILE" | jq '[.[] | select(.project=="appco-images" and .status=="success") | .Total] | add // 0' 2>/dev/null)
PUB_TOTAL=$(cat "$RESULTS_FILE" | jq '[.[] | select(.project=="public-images" and .status=="success") | .Total] | add // 0' 2>/dev/null)
echo "  AppCo total:  ${APPCO_TOTAL:-?} CVEs"
echo "  Public total: ${PUB_TOTAL:-?} CVEs"
if [ "${PUB_TOTAL:-0}" -gt "${APPCO_TOTAL:-0}" ] 2>/dev/null; then
    DIFF=$((PUB_TOTAL - APPCO_TOTAL))
    echo "  >>> AppCo has $DIFF fewer CVEs <<<"
fi
echo ""
