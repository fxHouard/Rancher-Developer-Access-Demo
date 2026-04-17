#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# RDA Demo Teardown
#
# Runs `tilt down` then cleans up what Tilt doesn't:
#   1. Force-deletes the `public` namespace (if stuck on finalizers)
#   2. Prunes public demo images from the Rancher Desktop image store
#
# AppCo images (dp.apps.rancher.io/*) are left intact — you'll want
# them for the next run.
#
# Usage (from the Rancher Developer Access/ directory):
#   bash scripts/teardown.sh
# ═══════════════════════════════════════════════════════════════
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# ─── Load pinned image tags ──────────────────────────────────
# versions.env lives in the parent dir (shared with the root demo).
VERSIONS_FILE="../versions.env"
if [ ! -f "$VERSIONS_FILE" ]; then
    echo "❌ versions.env not found at $VERSIONS_FILE"
    exit 1
fi
set -a; source "$VERSIONS_FILE"; set +a

echo "═══════════════════════════════════════════════════"
echo "  RDA Demo Teardown"
echo "═══════════════════════════════════════════════════"

# ─── 1. Tilt down ────────────────────────────────────────────
echo ""
echo "── [1/3] Running tilt down ──"
tilt down || echo "  (tilt down exited non-zero — continuing)"

# ─── 2. Force-delete the public namespace ────────────────────
# Tilt already requests deletion of the Namespace resource, but
# helm releases / PVCs sometimes leave finalizers blocking it.
echo ""
echo "── [2/3] Deleting public namespace ──"
if kubectl get ns public >/dev/null 2>&1; then
    kubectl delete namespace public --ignore-not-found --wait=false
    # Wait up to 60s for clean removal
    for i in $(seq 1 30); do
        kubectl get ns public >/dev/null 2>&1 || break
        sleep 2
    done
    # If still there, strip finalizers
    if kubectl get ns public >/dev/null 2>&1; then
        echo "  Namespace stuck — stripping finalizers"
        kubectl get ns public -o json \
            | jq '.spec.finalizers = []' \
            | kubectl replace --raw /api/v1/namespaces/public/finalize -f - >/dev/null
    fi
    echo "  ✅ Namespace public deleted"
else
    echo "  (namespace public already absent)"
fi

# ─── 3. Prune public demo images ─────────────────────────────
# List built from versions.env. AppCo (dp.apps.rancher.io/*) images
# are intentionally excluded — they're reused across runs.
echo ""
echo "── [3/3] Pruning public demo images from Rancher Desktop ──"

PUBLIC_IMAGES=(
    "postgres:${POSTGRES_TAG}"
    "prom/prometheus:${PROMETHEUS_TAG}"
    "prom/node-exporter"
    "grafana/grafana:${GRAFANA_TAG}"
    "quay.io/keycloak/keycloak:${KEYCLOAK_TAG}"
    "aquasec/trivy:${TRIVY_TAG}"
    "node:${NODE_TAG}"
    "message-wall-public"
    "message-wall"
    "cve-exporter"
)

removed=0
skipped=0
for img in "${PUBLIC_IMAGES[@]}"; do
    # Match by repo (with or without tag). Handles multiple tags per repo.
    matches=$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
        | grep -E "^${img%:*}(:|$)" || true)
    if [ -z "$matches" ]; then
        skipped=$((skipped + 1))
        continue
    fi
    while IFS= read -r m; do
        if docker image rm -f "$m" >/dev/null 2>&1; then
            echo "  ✅ removed $m"
            removed=$((removed + 1))
        fi
    done <<< "$matches"
done

# Final dangling image sweep
docker image prune -f >/dev/null 2>&1 || true

echo ""
echo "═══════════════════════════════════════════════════"
echo "  Done. Removed $removed image(s), skipped $skipped absent."
echo "═══════════════════════════════════════════════════"
