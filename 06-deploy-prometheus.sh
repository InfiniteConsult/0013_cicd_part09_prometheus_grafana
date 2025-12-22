#!/usr/bin/env bash

#
# -----------------------------------------------------------
#           06-deploy-prometheus.sh
#
#  Deploys "The Brain".
#  - Network: cicd-net
#  - Identity: prometheus.cicd.local (Self-scraping)
#  - Security: TLS on port 9090 via web-config.yml
# -----------------------------------------------------------

set -e
echo "🚀 Deploying Prometheus (The Brain)..."

# --- 1. Load Paths ---
PROMETHEUS_BASE="$HOME/cicd_stack/prometheus"

# --- 2. Cleanup Old Container ---
if [ "$(docker ps -q -f name=prometheus)" ]; then
    docker rm -f prometheus
fi

# --- 3. Deploy ---
# Note: We run as UID 65534 ('nobody') which owns the mounted volumes.
docker run -d \
  --name prometheus \
  --restart always \
  --network cicd-net \
  --hostname prometheus.cicd.local \
  --publish 127.0.0.1:9090:9090 \
  --user 65534:65534 \
  --volume "$PROMETHEUS_BASE/config/prometheus.yml":/etc/prometheus/prometheus.yml:ro \
  --volume "$PROMETHEUS_BASE/config/web-config.yml":/etc/prometheus/web-config.yml:ro \
  --volume "$PROMETHEUS_BASE/config/certs":/etc/prometheus/certs:ro \
  --volume prometheus-data:/prometheus \
  prom/prometheus:latest \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/prometheus \
  --web.config.file=/etc/prometheus/web-config.yml \
  --web.external-url=https://prometheus.cicd.local:9090

echo "✅ Prometheus Deployed."
echo "   URL: https://prometheus.cicd.local:9090"
echo "   Note: Browser will warn about CA unless installed."