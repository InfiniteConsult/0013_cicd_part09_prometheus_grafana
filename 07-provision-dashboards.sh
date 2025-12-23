#!/usr/bin/env bash

#
# -----------------------------------------------------------
#           07-provision-dashboards.sh
#
#  Configures Grafana Dashboard Provisioning.
#  1. Temporarily takes ownership of config dir.
#  2. Downloads Standard Dashboards.
#  3. Injects LOCAL Custom Dashboards (SonarQube).
#  4. Restores ownership to Grafana (UID 472).
# -----------------------------------------------------------

set -e
echo "🎨 Provisioning Grafana Dashboards..."

# --- 1. Paths ---
GRAFANA_BASE="$HOME/cicd_stack/grafana"
DASH_CONF_DIR="$GRAFANA_BASE/provisioning/dashboards"
JSON_DIR="$DASH_CONF_DIR/json"

# --- 2. Prepare Permissions ---
echo "   🔓 Temporarily unlocking permissions..."
sudo mkdir -p "$JSON_DIR"
sudo chown -R "$USER":"$USER" "$GRAFANA_BASE/provisioning"

# --- 3. Create Provider Config ---
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

# --- 4. Download Standard Dashboards ---
download_dash() {
    local ID=$1
    local NAME=$2
    local FILE="$JSON_DIR/${NAME}.json"

    echo "   ⬇️  Downloading $NAME (ID: $ID)..."
    curl -s "https://grafana.com/api/dashboards/$ID/revisions/latest/download" | \
    sed -E 's/\$\{DS_PROMETHEUS[^}]*\}/Prometheus/g' | \
    sed 's/"datasource":.*"\${.*}"/"datasource": "Prometheus"/g' > "$FILE"
}

echo "--- Infrastructure Layer ---"
download_dash "1860" "node-exporter-full"
download_dash "14282" "cadvisor-containers"
download_dash "2322" "elasticsearch"
download_dash "19105" "prometheus-modern"

echo "--- Application Layer ---"
download_dash "5774" "gitlab-omnibus"
download_dash "9964" "jenkins"
download_dash "15582" "mattermost-perf-v2"
download_dash "6671" "go-processes"

# --- 5. Inject Local Custom Dashboard ---
if [ -f "sonarqube_dashboard.json" ]; then
    echo "   📥 Injecting local 'sonarqube_dashboard.json'..."
    cp "sonarqube_dashboard.json" "$JSON_DIR/sonarqube-native.json"
else
    echo "   ⚠️  WARNING: 'sonarqube_dashboard.json' not found in current directory."
    echo "       (You can add it later and re-run this script)"
fi


if [ -f "artifactory_dashboard.json" ]; then
    echo "   📥 Injecting local 'artifactory_dashboard.json'..."
    cp "artifactory_dashboard.json" "$JSON_DIR/artifactory.json"
else
    echo "   ⚠️  WARNING: 'artifactory_dashboard.json' not found in current directory."
    echo "       (You can add it later and re-run this script)"
fi

# --- 6. Restore Permissions ---
echo "   🔒 Restoring permissions for Grafana (UID 472)..."
sudo chown -R 472:472 "$GRAFANA_BASE/provisioning"

echo "✅ All Dashboards Provisioned."