#!/usr/bin/env bash

#
# -----------------------------------------------------------
#           07-provision-dashboards.sh
#
#  Configures Grafana Dashboard Provisioning.
#  1. Temporarily takes ownership of config dir.
#  2. Downloads Standard Dashboards.
#  3. Injects LOCAL Custom Dashboards (SonarQube, etc).
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
download_dash "6671" "go-processes"

# --- 5. Inject Local Custom Dashboard ---
# The script checks for local files and copies them to the provisioning dir

if [ -f "sonarqube_dashboard.json" ]; then
    echo "   📥 Injecting local 'sonarqube_dashboard.json'..."
    cp "sonarqube_dashboard.json" "$JSON_DIR/sonarqube-native.json"
else
    echo "   ⚠️  WARNING: 'sonarqube_dashboard.json' not found."
fi

if [ -f "artifactory_dashboard.json" ]; then
    echo "   📥 Injecting local 'artifactory_dashboard.json'..."
    cp "artifactory_dashboard.json" "$JSON_DIR/artifactory.json"
else
    echo "   ⚠️  WARNING: 'artifactory_dashboard.json' not found."
fi

if [ -f "gitlab_dashboard.json" ]; then
    echo "   📥 Injecting local 'gitlab_dashboard.json'..."
    cp "gitlab_dashboard.json" "$JSON_DIR/gitlab.json"
else
    echo "   ⚠️  WARNING: 'gitlab_dashboard.json' not found."
fi

if [ -f "jenkins_dashboard.json" ]; then
    echo "   📥 Injecting local 'jenkins_dashboard.json'..."
    cp "jenkins_dashboard.json" "$JSON_DIR/jenkins.json"
else
    echo "   ⚠️  WARNING: 'jenkins_dashboard.json' not found."
fi

if [ -f "mattermost_dashboard.json" ]; then
    echo "   📥 Injecting local 'mattermost_dashboard.json'..."
    cp "mattermost_dashboard.json" "$JSON_DIR/mattermost.json"
else
    echo "   ⚠️  WARNING: 'mattermost_dashboard.json' not found."
fi

# --- 6. Restore Permissions ---
echo "   🔒 Restoring permissions for Grafana (UID 472)..."
sudo chown -R 472:472 "$GRAFANA_BASE/provisioning"

echo "✅ All Dashboards Provisioned."