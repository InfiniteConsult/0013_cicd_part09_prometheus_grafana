#!/usr/bin/env bash

#
# -----------------------------------------------------------
#           08-deploy-grafana.sh
#
#  Deploys "The Face" (Grafana).
#  - Network: cicd-net
#  - Identity: grafana.cicd.local
#  - Security: HTTPS (Port 3000) + UID 472 (Grafana User)
#  - Backend: Connects to postgres.cicd.local (Stateless Container)
# -----------------------------------------------------------

set -e

# --- 1. Load Secrets ---
ENV_FILE="$HOME/cicd_stack/cicd.env"
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
else
    echo "❌ ERROR: cicd.env not found."
    exit 1
fi

echo "🚀 Deploying Grafana (The Face)..."

# --- 2. Define Paths ---
GRAFANA_BASE="$HOME/cicd_stack/grafana"
GRAFANA_ENV="$GRAFANA_BASE/grafana.env"

# --- 3. Permission Fix (Environment File) ---
# The Docker CLI needs to read this file to inject variables.
if [ -f "$GRAFANA_ENV" ]; then
    echo "   🔓 Unlocking env file permissions..."
    sudo chown "$USER":"$USER" "$GRAFANA_ENV"
    sudo chmod 640 "$GRAFANA_ENV"
fi

# --- 4. Cleanup Old Container ---
if [ "$(docker ps -q -f name=grafana)" ]; then
    echo "   ♻️  Removing existing container..."
    docker rm -f grafana
fi

# --- 5. Deploy ---
# We inject the Postgres config via GF_DATABASE_* variables.
# We explicitly set SSL_MODE=require because our Postgres acts as a strict CA authority.
docker run -d \
  --name grafana \
  --restart always \
  --network cicd-net \
  --hostname grafana.cicd.local \
  --publish 127.0.0.1:3000:3000 \
  --user 472:472 \
  --env-file "$GRAFANA_ENV" \
  -e GF_DATABASE_TYPE=postgres \
  -e GF_DATABASE_HOST=postgres.cicd.local:5432 \
  -e GF_DATABASE_NAME=grafana \
  -e GF_DATABASE_USER=grafana \
  -e GF_DATABASE_PASSWORD="$GRAFANA_DB_PASSWORD" \
  -e GF_DATABASE_SSL_MODE=require \
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