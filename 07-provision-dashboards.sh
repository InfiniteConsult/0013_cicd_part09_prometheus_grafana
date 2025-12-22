#!/usr/bin/env bash

#
# -----------------------------------------------------------
#           07-provision-dashboards.sh
#
#  Configures Grafana Dashboard Provisioning.
#  1. Temporarily takes ownership of config dir.
#  2. Downloads Infrastructure & Application dashboards.
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

# --- 4. Download Dashboards ---
download_dash() {
    local ID=$1
    local NAME=$2
    local FILE="$JSON_DIR/${NAME}.json"

    echo "   ⬇️  Downloading $NAME (ID: $ID)..."
    # Download and attempt to auto-fix Datasource variables
    # We replace common template variables with our fixed 'Prometheus' name
    curl -s "https://grafana.com/api/dashboards/$ID/revisions/latest/download" | \
    sed 's/${DS_PROMETHEUS}/Prometheus/g' | \
    sed 's/"datasource": "\${DS_PROMETHEUS}"/"datasource": "Prometheus"/g' > "$FILE"
}

echo "--- Infrastructure Layer ---"
# 1. Node Exporter Full (Host Hardware)
download_dash "1860" "node-exporter-full"

# 2. cAdvisor (Docker Containers)
download_dash "14282" "cadvisor-containers"

# 3. Elasticsearch Exporter
download_dash "2322" "elasticsearch"

# 4. Prometheus Modern (The Brain itself)
download_dash "19105" "prometheus-modern"

echo "--- Application Layer ---"
# 5. GitLab Omnibus (Matches gitlab.cicd.local:10300)
download_dash "5774" "gitlab-omnibus"

# 6. Jenkins (Matches /prometheus/ endpoint)
download_dash "9964" "jenkins"

# 7. SonarQube (Matches /api/monitoring/metrics)
download_dash "14152" "sonarqube-system"

# 8. Artifactory (Matches /artifactory/api/v1/metrics)
download_dash "12113" "artifactory"

# 9. Mattermost V2 (Matches standard Go metrics)
download_dash "15582" "mattermost-perf-v2"

# --- 5. Restore Permissions ---
echo "   🔒 Restoring permissions for Grafana (UID 472)..."
sudo chown -R 472:472 "$GRAFANA_BASE/provisioning"

echo "✅ All Dashboards Provisioned."