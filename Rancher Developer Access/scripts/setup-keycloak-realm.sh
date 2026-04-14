#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# Setup Keycloak realm via Admin REST API
#
# Creates the "message-wall" realm with a public OIDC client
# and a demo user (demo/demo). Idempotent — skips if exists.
# ═══════════════════════════════════════════════════════════════
set -uo pipefail

KC_URL="${1:-http://localhost:8080}"
REALM_FILE="${2:-k8s/shared/keycloak-realm.json}"
ADMIN_USER="${3:-admin}"
ADMIN_PASS="${4:-admin}"

echo "── Keycloak realm setup ──"
echo "   Server: $KC_URL"

# Wait for Keycloak to be ready
echo -n "   Waiting for Keycloak..."
for i in $(seq 1 60); do
    if curl -sf "${KC_URL}/realms/master" > /dev/null 2>&1; then
        echo " ready!"
        break
    fi
    echo -n "."
    sleep 2
done

# Check if realm already exists
if curl -sf "${KC_URL}/realms/message-wall" > /dev/null 2>&1; then
    echo "   ✅ Realm 'message-wall' already exists — skipping"
    exit 0
fi

# Get admin token
echo "   Getting admin token..."
TOKEN=$(curl -sf "${KC_URL}/realms/master/protocol/openid-connect/token" \
    -d "client_id=admin-cli" \
    -d "username=${ADMIN_USER}" \
    -d "password=${ADMIN_PASS}" \
    -d "grant_type=password" 2>/dev/null | jq -r '.access_token // empty')

if [ -z "$TOKEN" ]; then
    echo "   ❌ Failed to get admin token"
    exit 1
fi

# Create realm
echo "   Creating realm 'message-wall'..."
HTTP_CODE=$(curl -s -o /tmp/kc-response.txt -w "%{http_code}" \
    -X POST "${KC_URL}/admin/realms" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d @"$REALM_FILE")

if [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "204" ]; then
    echo "   ✅ Realm created successfully"
elif [ "$HTTP_CODE" = "409" ]; then
    echo "   ✅ Realm already exists"
else
    echo "   ❌ Failed to create realm (HTTP $HTTP_CODE)"
    cat /tmp/kc-response.txt 2>/dev/null
    exit 1
fi

# Verify
echo -n "   Verify: "
curl -sf "${KC_URL}/realms/message-wall" | jq -r '"realm=\(.realm), clients=OK"' 2>/dev/null || echo "verification failed"
