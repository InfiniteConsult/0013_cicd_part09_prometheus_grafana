#!/usr/bin/env bash

#
# -----------------------------------------------------------
#           07-provision-dashboards.sh
#
#  Configures Grafana Dashboard Provisioning.
#  1. Temporarily takes ownership of config dir.
#  2. Downloads MODERN community JSON dashboards.
#  3. Restores ownership to Grafana (UID 472).
# -----------------------------------------------------------

set -e
echo "🎨 Provisioning Grafana Dashboards..."

# --- 1. Paths ---
GRAFANA_BASE="$HOME/cicd_stack/grafana"
DASH_CONF_DIR="$GRAFANA_BASE/provisioning/dashboards"
JSON_DIR="$DASH_CONF_DIR/json"

# --- 2. Prepare Permissions ---
# Create directory and give CURRENT USER ownership so we can write safely
echo "   🔓 Temporarily unlocking permissions..."
sudo mkdir -p "$JSON_DIR"
sudo chown -R "$USER":"$USER" "$GRAFANA_BASE/provisioning"

# --- 3. Create Provider Config (dashboards.yaml) ---
echo "   📝 Writing Provider Config..."
cat << EOF > "$DASH_CONF_DIR/dashboards.yaml"
apiVersion: 1

providers:
  - name: 'Default'
    orgId: 1
    folder: ''
    type: file
    disableDeletion: false
    updateIntervalSeconds: 10
    allowUiUpdates: true
    options:
      path: /etc/grafana/provisioning/dashboards/json
EOF

# --- 4. Download Community Dashboards ---
download_dash() {
    local ID=$1
    local NAME=$2
    local FILE="$JSON_DIR/${NAME}.json"

    echo "   ⬇️  Downloading $NAME (ID: $ID)..."
    # Download as current user
    curl -s "https://grafana.com/api/dashboards/$ID/revisions/latest/download" | \
    sed 's/${DS_PROMETHEUS}/Prometheus/g' > "$FILE"
}

# 1. Node Exporter Full (ID: 1860) - The Gold Standard
download_dash "1860" "node-exporter-full"

# 2. cAdvisor (ID: 14282) - Docker Container Stats
download_dash "14282" "cadvisor-containers"

# 3. Modern Prometheus 2.x (ID: 19105) - UPDATED (Replaces 3662)
download_dash "19105" "prometheus-modern"

# 4. Go Processes (ID: 6671) - For Artifactory/Mattermost internals
download_dash "6671" "go-processes"

# 5. Elasticsearch Exporter (ID: 2322)
download_dash "2322" "elasticsearch"

# --- 5. Restore Permissions ---
echo "   🔒 Restoring permissions for Grafana (UID 472)..."
sudo chown -R 472:472 "$GRAFANA_BASE/provisioning"

echo "✅ Dashboards Provisioned."