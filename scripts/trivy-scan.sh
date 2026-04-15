#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# Trivy Scan — Public Images Only — host-side orchestration
#
# Runs trivy via `docker run` on the workstation. No K8s Job, no
# ConfigMap-injected script. All parsing/aggregation happens here
# on the host where jq is available.
#
# DB cache lives in $HOME/.cache/trivy on the host → first run
# downloads, subsequent runs reuse (trivy auto-refreshes every 24h).
#
# Components: postgresql, prometheus, node-exporter,
#             grafana, message-wall, keycloak, trivy
# ═══════════════════════════════════════════════════════════════
set -uo pipefail

RESULTS_FILE="${RESULTS_FILE:-/tmp/cve-results.json}"
SCAN_DIR="${SCAN_DIR:-/tmp/trivy-scans}"
CONFIGMAP_NAME="cve-results"
TRIVY_IMAGE="${TRIVY_IMAGE:-aquasec/trivy:0.69.3}"
SCANNER_IMAGE="${SCANNER_IMAGE:-$TRIVY_IMAGE}"
TRIVY_CACHE="${TRIVY_CACHE:-$HOME/.cache/trivy}"

echo "═══════════════════════════════════════════════════"
echo "  Trivy Scan — Public Images (host-side)"
echo "  Scanner: $SCANNER_IMAGE"
echo "  DB cache: $TRIVY_CACHE"
echo "  Components: postgresql, prometheus, node-exporter,"
echo "    grafana, message-wall, keycloak, trivy"
echo "═══════════════════════════════════════════════════"

# Sanity checks
command -v docker  >/dev/null || { echo "❌ docker not found"; exit 1; }
command -v kubectl >/dev/null || { echo "❌ kubectl not found"; exit 1; }
command -v jq      >/dev/null || { echo "❌ jq not found (brew install jq)"; exit 1; }

mkdir -p "$TRIVY_CACHE" "$SCAN_DIR"

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

run_trivy() {
    # Public-only variant scans only public images, so no AppCo creds
    # needed. We still avoid mounting ~/.docker/config.json because on
    # macOS it points at osxkeychain (no helper inside container).
    docker run --rm \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v "$TRIVY_CACHE:/root/.cache/trivy" \
        "$SCANNER_IMAGE" "$@"
}

# ─── Discover images ─────────────────────────────────────────
echo ""
echo "── Discovering images from running pods... ──"

PUB_PG=$(get_pod_image default "app.kubernetes.io/name=postgresql" "postgresql")
PUB_PROM=$(get_pod_image default "app.kubernetes.io/instance=prometheus,app.kubernetes.io/component=server" "prometheus-server")
PUB_NODEEXP=$(get_pod_image default "app.kubernetes.io/instance=prometheus,app.kubernetes.io/name=prometheus-node-exporter" "node-exporter")
PUB_GRAF=$(get_pod_image default "app.kubernetes.io/instance=grafana" "grafana")
PUB_KC=$(get_pod_image default "app=keycloak,variant=public" "keycloak")
PUB_MW=$(get_tilt_image "message-wall")
PUB_TRIVY="${TRIVY_IMAGE}"

echo ""
echo "  Images to scan:"
printf "    %-13s %s\n" postgresql: "${PUB_PG:-unknown}"
printf "    %-13s %s\n" prometheus: "${PUB_PROM:-unknown}"
printf "    %-13s %s\n" node-exporter: "${PUB_NODEEXP:-unknown}"
printf "    %-13s %s\n" grafana: "${PUB_GRAF:-unknown}"
printf "    %-13s %s\n" keycloak: "${PUB_KC:-unknown}"
printf "    %-13s %s\n" message-wall: "${PUB_MW:-unknown}"
printf "    %-13s %s\n" trivy: "${PUB_TRIVY}"

# ─── Build image list ────────────────────────────────────────
# Format: project|application|name|image|base_image
IMAGE_LIST="public-images|postgresql|postgresql|${PUB_PG}|
public-images|prometheus|prometheus|${PUB_PROM}|
public-images|prometheus|node-exporter|${PUB_NODEEXP}|
public-images|grafana|grafana|${PUB_GRAF}|
public-images|trivy|trivy|${PUB_TRIVY}|
public-images|keycloak|keycloak|${PUB_KC}|
public-images|message-wall|message-wall|${PUB_MW}|node:24
"

# ─── Refresh DB once up front ────────────────────────────────
DB_PRESENT=0
[ -f "$TRIVY_CACHE/db/trivy.db" ] && DB_PRESENT=1

echo ""
echo "── Refreshing trivy DB (cache: $TRIVY_CACHE, present: $DB_PRESENT) ──"
if ! run_trivy image --download-db-only 2>&1 | tail -5; then
    if [ "$DB_PRESENT" -eq 0 ]; then
        echo "❌ DB download failed AND no cached DB present — cannot scan."
        exit 1
    fi
    echo "  (DB update failed, continuing with stale cached DB)"
fi
run_trivy image --download-java-db-only 2>&1 | tail -3 || true

# ─── Scan loop ───────────────────────────────────────────────
echo ""
echo "── Scanning images ──"

rm -f "$SCAN_DIR"/*.json "$SCAN_DIR"/*.log 2>/dev/null || true

scan_count=0
ok_count=0
err_count=0

while IFS="|" read -r project application name image base_image; do
    [ -z "$image" ] && continue
    scan_count=$((scan_count + 1))
    safe="${project}_${name}"
    out="$SCAN_DIR/${safe}.json"
    log="$SCAN_DIR/${safe}.log"

    echo ""
    echo "  ── [$scan_count] $project/$application/$name ──"
    echo "     Image: $image"
    [ -n "$base_image" ] && echo "     Base:  $base_image"

    if run_trivy image \
        --format json --skip-db-update \
        --severity CRITICAL,HIGH,MEDIUM,LOW \
        --timeout 600s \
        "$image" > "$out" 2>"$log"; then
        bytes=$(wc -c < "$out" | tr -d ' ')
        echo "     Scan OK ($bytes bytes)"
        ok_count=$((ok_count + 1))
    else
        rc=$?
        echo "     Scan FAILED (exit $rc)"
        tail -10 "$log" | sed 's/^/       /'
        err_count=$((err_count + 1))
    fi
done <<< "$IMAGE_LIST"

echo ""
echo "── Scan summary: $ok_count ok, $err_count errors out of $scan_count ──"

# ─── Aggregate results into cve-results.json ─────────────────
echo ""
echo "── Aggregating results with jq ──"

: > "$RESULTS_FILE"
echo "[" > "$RESULTS_FILE"
first=true

while IFS="|" read -r project application name image base_image; do
    [ -z "$image" ] && continue
    safe="${project}_${name}"
    out="$SCAN_DIR/${safe}.json"

    if [ -s "$out" ] && jq -e . "$out" >/dev/null 2>&1; then
        entry=$(jq -c \
            --arg proj "$project" --arg app "$application" \
            --arg repo "$name" --arg img "$image" --arg base "${base_image:-}" \
            '{
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
            }' "$out" 2>/dev/null)
    else
        entry=""
    fi

    if [ -z "$entry" ]; then
        entry=$(jq -nc \
            --arg proj "$project" --arg app "$application" \
            --arg repo "$name" --arg img "$image" --arg base "${base_image:-}" \
            '{project: $proj, application: $app, repository: $repo, image: $img, base_image: $base, base_os: "", Critical: 0, High: 0, Medium: 0, Low: 0, Total: 0, status: "error"}')
    fi

    if [ "$first" = true ]; then first=false; else printf "," >> "$RESULTS_FILE"; fi
    printf "%s\n" "$entry" >> "$RESULTS_FILE"
done <<< "$IMAGE_LIST"

echo "]" >> "$RESULTS_FILE"

echo "✅ Scan complete → $RESULTS_FILE"

# ─── Push to ConfigMap ───────────────────────────────────────
kubectl create configmap "$CONFIGMAP_NAME" \
    --from-file=cve-results.json="$RESULTS_FILE" \
    --dry-run=client -o yaml | kubectl apply -f -
echo "✅ ConfigMap '$CONFIGMAP_NAME' updated"

# ─── Quick summary ───────────────────────────────────────────
echo ""
TOTAL=$(jq '[.[] | select(.status=="success") | .Total] | add // 0' "$RESULTS_FILE")
echo "  Total CVEs found: ${TOTAL:-0}"
echo ""
