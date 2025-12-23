#!/usr/bin/env bash

#
# -----------------------------------------------------------
#           08-deploy-grafana.sh
#
#  Deploys "The Face" (Grafana).
#  - Network: cicd-net
#  - Identity: grafana.cicd.local
#  - Security: HTTPS (Port 3000) + UID 472 (Grafana User)
#  - Data: Persisted in 'grafana-data' volume
# -----------------------------------------------------------

set -e
echo "🚀 Deploying Grafana (The Face)..."

# --- 1. Define Paths ---
GRAFANA_BASE="$HOME/cicd_stack/grafana"
GRAFANA_ENV="$GRAFANA_BASE/grafana.env"

# --- FIX: Unlock Env File ---
# Docker CLI needs to read this file to inject variables.
# We give ownership to the current user.
if [ -f "$GRAFANA_ENV" ]; then
    echo "   🔓 Unlocking env file permissions..."
    sudo chown "$USER":"$USER" "$GRAFANA_ENV"
    sudo chmod 640 "$GRAFANA_ENV"
fi

# --- 2. Cleanup Old Container ---
if [ "$(docker ps -q -f name=grafana)" ]; then
    echo "   ♻️  Removing existing container..."
    docker rm -f grafana
fi

# --- 3. Deploy ---
# Note: We run as UID 472 (Grafana) which owns the mounted volumes.
docker run -d \
  --name grafana \
  --restart always \
  --network cicd-net \
  --hostname grafana.cicd.local \
  --publish 127.0.0.1:3000:3000 \
  --user 472:472 \
  --env-file "$GRAFANA_ENV" \
  --volume "$GRAFANA_BASE/config/grafana.ini":/etc/grafana/grafana.ini:ro \
  --volume "$GRAFANA_BASE/config/certs":/etc/grafana/certs:ro \
  --volume "$GRAFANA_BASE/provisioning":/etc/grafana/provisioning:ro \
  --volume grafana-data:/var/lib/grafana \
  grafana/grafana:latest

echo "✅ Grafana Deployed."
echo "---------------------------------------------------"
echo "   URL:      https://grafana.cicd.local:3000"
echo "   User:     admin"
echo "   Password: (Run the command below to see it)"
echo "   grep GRAFANA_ADMIN_PASSWORD ~/cicd_stack/cicd.env"
echo "---------------------------------------------------"