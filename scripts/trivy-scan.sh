#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# Trivy Scan — Public Images Only
#
# Discovers images from running pods, then launches a Trivy
# scan Job that accesses the container runtime via hostPath.
# Results are saved to a ConfigMap for the CVE exporter.
#
# Components: postgresql, prometheus, node-exporter,
#             grafana, message-wall, keycloak, trivy
# ═══════════════════════════════════════════════════════════════
set -uo pipefail

RESULTS_FILE="${RESULTS_FILE:-/tmp/cve-results.json}"
CONFIGMAP_NAME="cve-results"
JOB_NAME="trivy-scan"
TRIVY_IMAGE="${TRIVY_IMAGE:-aquasec/trivy:0.69.3}"

echo "═══════════════════════════════════════════════════"
echo "  Trivy Scan — Public Images"
echo "  Scanner: $TRIVY_IMAGE"
echo "  Components: postgresql, prometheus, "
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

# Public images (default namespace)
PUB_PG=$(get_pod_image default "app.kubernetes.io/name=postgresql" "postgresql")
PUB_PROM=$(get_pod_image default "app.kubernetes.io/instance=prometheus,app.kubernetes.io/component=server" "prometheus-server")
PUB_NODEEXP=$(get_pod_image default "app.kubernetes.io/instance=prometheus,app.kubernetes.io/name=prometheus-node-exporter" "node-exporter")
PUB_GRAF=$(get_pod_image default "app.kubernetes.io/instance=grafana" "grafana")
PUB_KC=$(get_pod_image default "app=keycloak,variant=public" "keycloak")
PUB_MW=$(get_tilt_image "message-wall")
PUB_TRIVY="${TRIVY_IMAGE}"

echo ""
echo "  Images to scan:"
echo "    postgresql:    ${PUB_PG:-unknown}"
echo "    prometheus:    ${PUB_PROM:-unknown}"
echo "    node-exporter: ${PUB_NODEEXP:-unknown}"
echo "    grafana:       ${PUB_GRAF:-unknown}"
echo "    keycloak:      ${PUB_KC:-unknown}"
echo "    message-wall:  ${PUB_MW:-unknown}"
echo "    trivy:         ${PUB_TRIVY}"

# ─── Build image scan list ───────────────────────────────────
# Format: project|application|name|image|base_image (one per line)
IMAGE_LIST="public-images|postgresql|postgresql|${PUB_PG}|
public-images|prometheus|prometheus|${PUB_PROM}|
public-images|prometheus|node-exporter|${PUB_NODEEXP}|
public-images|grafana|grafana|${PUB_GRAF}|
public-images|trivy|trivy|${PUB_TRIVY}|
public-images|keycloak|keycloak|${PUB_KC}|F
public-images|message-wall|message-wall|${PUB_MW}|node:24
"

# ─── Create scan script as ConfigMap ─────────────────────────
kubectl create configmap trivy-scan-script --dry-run=client -o yaml \
  --from-literal=scan.sh='#!/bin/sh
# NOTE: no "set -e" — we want to continue even if one scan fails

echo "=== Trivy scan starting ==="
echo "Tools present: $(command -v grep >/dev/null && echo grep) $(command -v wc >/dev/null && echo wc)"

echo "Downloading vulnerability databases..."
trivy image --download-db-only 2>&1 | tail -5
trivy image --download-java-db-only 2>&1 | tail -5
echo "DB ready."

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

    # Parse by counting severity occurrences in the JSON. No jq needed —
    # only grep/wc, present in every container base (busybox or coreutils).
    entry=""
    if [ -s "$SCAN_JSON" ]; then
        critical=$(grep -cE "\"Severity\"[[:space:]]*:[[:space:]]*\"CRITICAL\"" "$SCAN_JSON" 2>/dev/null || echo 0)
        high=$(grep -cE "\"Severity\"[[:space:]]*:[[:space:]]*\"HIGH\"" "$SCAN_JSON" 2>/dev/null || echo 0)
        medium=$(grep -cE "\"Severity\"[[:space:]]*:[[:space:]]*\"MEDIUM\"" "$SCAN_JSON" 2>/dev/null || echo 0)
        low=$(grep -cE "\"Severity\"[[:space:]]*:[[:space:]]*\"LOW\"" "$SCAN_JSON" 2>/dev/null || echo 0)
        total=$((critical + high + medium + low))
        base_os=$(grep -m1 -oE "\"Target\":[[:space:]]*\"[^\"]*\\([^)]*\\)\"" "$SCAN_JSON" 2>/dev/null \
                  | sed -n "s/.*(\\([^)]*\\)).*/\\1/p" || true)
        entry="{\"project\":\"$project\",\"application\":\"$application\",\"repository\":\"$name\",\"image\":\"$image\",\"base_image\":\"${base_image:-}\",\"base_os\":\"${base_os:-}\",\"Critical\":$critical,\"High\":$high,\"Medium\":$medium,\"Low\":$low,\"Total\":$total,\"status\":\"success\"}"
        echo "     Found $total CVEs (C:$critical H:$high M:$medium L:$low)"
    else
        entry="{\"project\":\"$project\",\"application\":\"$application\",\"repository\":\"$name\",\"image\":\"$image\",\"base_image\":\"${base_image:-}\",\"base_os\":\"\",\"Critical\":0,\"High\":0,\"Medium\":0,\"Low\":0,\"Total\":0,\"status\":\"error\"}"
        echo "     Using error fallback entry (empty scan output)"
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
cat "$RESULTS_FILE"
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
      restartPolicy: Never
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

LOGS=$(kubectl logs "job/${JOB_NAME}" 2>/dev/null)
JSON_BLOCK=$(echo "$LOGS" | sed -n '/=== SCAN_RESULTS_JSON_START ===/,/=== SCAN_RESULTS_JSON_END ===/p' | grep -v '=== SCAN_RESULTS')

if [ -z "$JSON_BLOCK" ]; then
    echo "⚠️  No JSON markers found, trying raw extraction..."
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

# ─── Quick summary (pure sed/grep/awk — no jq) ───────────────
echo ""
TOTAL=$(sed 's/},{/}\n{/g' "$RESULTS_FILE" \
    | grep '"status":"success"' \
    | grep -oE '"Total":[0-9]+' \
    | grep -oE '[0-9]+' \
    | awk '{s+=$1} END {print s+0}')
echo "  Total CVEs found: ${TOTAL:-0}"
echo ""
