#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# Trivy Scan — host-side orchestration
#
# Runs trivy via `docker run` on the workstation. No K8s Job, no
# ConfigMap-injected script. The trivy AppCo container is used as
# a one-shot binary; all parsing/aggregation happens here on the
# host where jq is available.
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
# Scanner = AppCo trivy (cluster-purity story holds even though we
# now run scans from the host: the only image we *use* as a tool is
# the AppCo one). TRIVY_IMAGE is kept as the *scanned* public ref.
SCANNER_IMAGE="${SCANNER_IMAGE:-dp.apps.rancher.io/containers/trivy:${APPCO_TRIVY_TAG:-0.69.3-9.1}}"
TRIVY_CACHE="${TRIVY_CACHE:-$HOME/.cache/trivy}"
DOCKER_CONFIG_FILE="${DOCKER_CONFIG_FILE:-$HOME/.docker/config.json}"
# Registries we need creds for (extracted from osxkeychain at runtime).
AUTH_REGISTRIES="${AUTH_REGISTRIES:-dp.apps.rancher.io}"

echo "═══════════════════════════════════════════════════"
echo "  Trivy Scan — host-side"
echo "  Scanner: $SCANNER_IMAGE"
echo "  (Public trivy scanned: $TRIVY_IMAGE)"
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

# Build a sanitized docker config.json with inline `auths`, extracted from
# the macOS keychain. Why: the host's ~/.docker/config.json on Rancher
# Desktop / Docker Desktop typically contains `"credsStore": "osxkeychain"`
# and no inline auths. Mounting it as-is into the trivy container fails
# with `docker-credential-osxkeychain: executable file not found`. So we
# extract creds on the host (where the helper exists) and write a flat
# config the container can use directly.
SANITIZED_CONFIG_DIR=""
build_sanitized_docker_config() {
    SANITIZED_CONFIG_DIR=$(mktemp -d)
    local cfg="$SANITIZED_CONFIG_DIR/config.json"
    echo '{"auths":{}}' > "$cfg"
    if ! command -v docker-credential-osxkeychain >/dev/null 2>&1; then
        echo "  (docker-credential-osxkeychain not found — AppCo scans may fail auth)"
        return
    fi
    for reg in $AUTH_REGISTRIES; do
        local creds user pass auth
        creds=$(echo "$reg" | docker-credential-osxkeychain get 2>/dev/null) || {
            echo "  (no keychain entry for $reg — login first: docker login $reg)"
            continue
        }
        user=$(echo "$creds" | jq -r '.Username // empty')
        pass=$(echo "$creds" | jq -r '.Secret // empty')
        [ -z "$user" ] || [ -z "$pass" ] && continue
        auth=$(printf '%s:%s' "$user" "$pass" | base64 | tr -d '\n')
        jq --arg reg "$reg" --arg auth "$auth" \
            '.auths[$reg] = {auth: $auth}' "$cfg" > "$cfg.new" && mv "$cfg.new" "$cfg"
        echo "  Auth ready for $reg (user: $user)"
    done
}
trap '[ -n "$SANITIZED_CONFIG_DIR" ] && rm -rf "$SANITIZED_CONFIG_DIR"' EXIT

run_trivy() {
    # Wraps `docker run` for trivy. Mounts:
    #   - docker.sock so trivy can scan images from the host daemon
    #     (needed for Tilt-built images that aren't in any registry)
    #   - the host trivy cache so the DB persists across runs
    #   - sanitized docker config.json for AppCo registry credentials
    local extra_mount=""
    [ -f "$SANITIZED_CONFIG_DIR/config.json" ] && \
        extra_mount="-v $SANITIZED_CONFIG_DIR/config.json:/root/.docker/config.json:ro"
    docker run --rm \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v "$TRIVY_CACHE:/root/.cache/trivy" \
        $extra_mount \
        "$SCANNER_IMAGE" "$@"
}

# ─── Discover images ─────────────────────────────────────────
echo ""
echo "── Discovering images from running pods... ──"

# AppCo (default namespace)
APPCO_PG=$(get_pod_image default "app.kubernetes.io/name=postgresql" "postgresql")
APPCO_PROM=$(get_pod_image default "app.kubernetes.io/name=prometheus,app.kubernetes.io/component=server" "prometheus-server")
APPCO_NODEEXP=$(get_pod_image default "app.kubernetes.io/name=prometheus-node-exporter" "node-exporter")
APPCO_GRAF=$(get_pod_image default "app.kubernetes.io/name=grafana" "grafana")
APPCO_KC=$(get_pod_image default "app=keycloak,variant=appco" "keycloak")
APPCO_MW=$(get_tilt_image "message-wall-appco")

# Public (public namespace)
PUB_PG=$(get_pod_image public "app.kubernetes.io/name=postgresql" "postgresql")
PUB_PROM=$(get_pod_image public "app.kubernetes.io/instance=prometheus-public,app.kubernetes.io/component=server" "prometheus-server")
PUB_NODEEXP=$(get_pod_image public "app.kubernetes.io/instance=prometheus-public,app.kubernetes.io/name=prometheus-node-exporter" "node-exporter")
PUB_GRAF=$(get_pod_image public "app.kubernetes.io/instance=grafana-public" "grafana")
PUB_KC=$(get_pod_image public "app=keycloak,variant=public" "keycloak")
PUB_MW=$(get_tilt_image "message-wall-public")

# Trivy itself — meta: scan the scanner
APPCO_TRIVY="${SCANNER_IMAGE}"
PUB_TRIVY="${TRIVY_IMAGE}"

echo ""
echo "  AppCo images:"
printf "    %-13s %s\n" postgresql: "${APPCO_PG:-unknown}"
printf "    %-13s %s\n" prometheus: "${APPCO_PROM:-unknown}"
printf "    %-13s %s\n" node-exporter: "${APPCO_NODEEXP:-unknown}"
printf "    %-13s %s\n" grafana: "${APPCO_GRAF:-unknown}"
printf "    %-13s %s\n" keycloak: "${APPCO_KC:-unknown}"
printf "    %-13s %s\n" message-wall: "${APPCO_MW:-unknown}"
printf "    %-13s %s\n" trivy: "${APPCO_TRIVY}"
echo ""
echo "  Public images:"
printf "    %-13s %s\n" postgresql: "${PUB_PG:-unknown}"
printf "    %-13s %s\n" prometheus: "${PUB_PROM:-unknown}"
printf "    %-13s %s\n" node-exporter: "${PUB_NODEEXP:-unknown}"
printf "    %-13s %s\n" grafana: "${PUB_GRAF:-unknown}"
printf "    %-13s %s\n" keycloak: "${PUB_KC:-unknown}"
printf "    %-13s %s\n" message-wall: "${PUB_MW:-unknown}"
printf "    %-13s %s\n" trivy: "${PUB_TRIVY}"

# ─── Build image list ────────────────────────────────────────
# Format: project|application|name|image|base_image
IMAGE_LIST="appco-images|postgresql|postgresql|${APPCO_PG}|
appco-images|prometheus|prometheus|${APPCO_PROM}|
appco-images|prometheus|node-exporter|${APPCO_NODEEXP}|
appco-images|grafana|grafana|${APPCO_GRAF}|
appco-images|trivy|trivy|${APPCO_TRIVY}|
appco-images|keycloak|keycloak|${APPCO_KC}|
appco-images|message-wall|message-wall|${APPCO_MW}|nodejs:24-dev (AppCo)
public-images|postgresql|postgresql|${PUB_PG}|
public-images|prometheus|prometheus|${PUB_PROM}|
public-images|prometheus|node-exporter|${PUB_NODEEXP}|
public-images|grafana|grafana|${PUB_GRAF}|
public-images|trivy|trivy|${PUB_TRIVY}|
public-images|keycloak|keycloak|${PUB_KC}|
public-images|message-wall|message-wall|${PUB_MW}|node:24
"

# ─── Build sanitized docker config from osxkeychain ──────────
echo ""
echo "── Extracting registry credentials from keychain ──"
build_sanitized_docker_config

# ─── Refresh DB once up front ────────────────────────────────
# Detect first run: trivy DB lives at $TRIVY_CACHE/db/trivy.db. If absent,
# the scan loop's --skip-db-update would fatal with "first run cannot skip".
DB_PRESENT=0
[ -f "$TRIVY_CACHE/db/trivy.db" ] && DB_PRESENT=1

echo ""
echo "── Refreshing trivy DB (cache: $TRIVY_CACHE, present: $DB_PRESENT) ──"
if ! run_trivy image --download-db-only 2>&1 | tail -5; then
    if [ "$DB_PRESENT" -eq 0 ]; then
        echo "❌ DB download failed AND no cached DB present — cannot scan."
        echo "   Check network / ghcr.io reachability."
        exit 1
    fi
    echo "  (DB update failed, continuing with stale cached DB)"
fi
run_trivy image --download-java-db-only 2>&1 | tail -3 || true

# ─── Scan loop ───────────────────────────────────────────────
echo ""
echo "── Scanning images ──"

# Reset scan dir
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

# ─── Quick summary (jq on host — no constraints) ─────────────
echo ""
APPCO_TOTAL=$(jq '[.[] | select(.project=="appco-images" and .status=="success") | .Total] | add // 0' "$RESULTS_FILE")
PUB_TOTAL=$(jq   '[.[] | select(.project=="public-images" and .status=="success") | .Total] | add // 0' "$RESULTS_FILE")
echo "  AppCo total:  ${APPCO_TOTAL:-0} CVEs"
echo "  Public total: ${PUB_TOTAL:-0} CVEs"
if [ "${PUB_TOTAL:-0}" -gt "${APPCO_TOTAL:-0}" ] 2>/dev/null; then
    DIFF=$((PUB_TOTAL - APPCO_TOTAL))
    echo "  >>> AppCo has $DIFF fewer CVEs <<<"
fi
echo ""
