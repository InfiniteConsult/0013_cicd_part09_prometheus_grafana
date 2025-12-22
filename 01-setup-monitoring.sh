#!/usr/bin/env bash

#
# -----------------------------------------------------------
#           01-setup-monitoring.sh
#
#  The "Architect" script for Prometheus & Grafana.
#
#  1. Secrets: Generates GRAFANA_ADMIN_PASSWORD & SONAR_WEB_SYSTEMPASSCODE.
#  2. Certs: Stages existing certs into config dirs.
#  3. Configs: Generates prometheus.yml, grafana.ini, datasources.yaml.
#  4. Permissions: Sets surgical ownership for UID 65534 & 472.
# -----------------------------------------------------------

set -e

# --- 1. Define Paths ---
HOST_CICD_ROOT="$HOME/cicd_stack"
PROMETHEUS_BASE="$HOST_CICD_ROOT/prometheus"
GRAFANA_BASE="$HOST_CICD_ROOT/grafana"
MASTER_ENV_FILE="$HOST_CICD_ROOT/cicd.env"

# Source CA Paths
CA_DIR="$HOST_CICD_ROOT/ca"
SRC_CA_CRT="$CA_DIR/pki/certs/ca.pem"
SRC_PROM_CRT="$CA_DIR/pki/services/prometheus.cicd.local/prometheus.cicd.local.crt.pem"
SRC_PROM_KEY="$CA_DIR/pki/services/prometheus.cicd.local/prometheus.cicd.local.key.pem"
SRC_GRAF_CRT="$CA_DIR/pki/services/grafana.cicd.local/grafana.cicd.local.crt.pem"
SRC_GRAF_KEY="$CA_DIR/pki/services/grafana.cicd.local/grafana.cicd.local.key.pem"

echo "🚀 Starting Monitoring 'Architect' Setup..."

# --- 2. Secrets Management ---
echo "--- Phase 1: Secrets Management ---"

if [ ! -f "$MASTER_ENV_FILE" ]; then
    echo "ERROR: Master env file not found at $MASTER_ENV_FILE"
    exit 1
fi

# Load existing secrets
set -a
source "$MASTER_ENV_FILE"
set +a

# Helper to append new secrets
append_secret() {
    local key=$1
    local val=$2
    if ! grep -q "^$key=" "$MASTER_ENV_FILE"; then
        echo "$key=\"$val\"" >> "$MASTER_ENV_FILE"
        echo "   Generated $key"
        export $key="$val"
    else
        echo "   Found existing $key"
    fi
}

generate_password() { openssl rand -hex 16; }
generate_passcode() { openssl rand -hex 32; }

# Generate missing monitoring secrets
append_secret "GRAFANA_ADMIN_PASSWORD" "$(generate_password)"
append_secret "SONAR_WEB_SYSTEMPASSCODE" "$(generate_passcode)"

# Validate dependencies
if [ -z "$ARTIFACTORY_ADMIN_TOKEN" ] || [ -z "$ELASTIC_PASSWORD" ]; then
    echo "❌ ERROR: Missing dependency secrets (ARTIFACTORY_ADMIN_TOKEN or ELASTIC_PASSWORD)."
    exit 1
fi

# --- 3. Directory & Permission Prep ---
echo "--- Phase 2: Directory Preparation ---"

# Take ownership to current user to allow writing configs without sudo
sudo chown -R "$USER":"$USER" "$PROMETHEUS_BASE"
sudo chown -R "$USER":"$USER" "$GRAFANA_BASE"

# Create config structures
mkdir -p "$PROMETHEUS_BASE/config/certs"
mkdir -p "$GRAFANA_BASE/config/certs"
mkdir -p "$GRAFANA_BASE/provisioning/datasources"
mkdir -p "$GRAFANA_BASE/provisioning/dashboards"

# --- 4. Certificate Staging ---
echo "--- Phase 3: Staging Certificates ---"

# Prometheus
cp "$SRC_CA_CRT" "$PROMETHEUS_BASE/config/certs/ca.pem"
cp "$SRC_PROM_CRT" "$PROMETHEUS_BASE/config/certs/prometheus.crt"
cp "$SRC_PROM_KEY" "$PROMETHEUS_BASE/config/certs/prometheus.key"

# Grafana
cp "$SRC_CA_CRT" "$GRAFANA_BASE/config/certs/ca.pem"
cp "$SRC_GRAF_CRT" "$GRAFANA_BASE/config/certs/grafana.crt"
cp "$SRC_GRAF_KEY" "$GRAFANA_BASE/config/certs/grafana.key"

echo "   Certificates staged."

# --- 5. Configuration Generation ---
echo "--- Phase 4: Generating Configurations ---"

# A. Prometheus Config (The Map)
cat << EOF > "$PROMETHEUS_BASE/config/prometheus.yml"
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  # 1. Prometheus (Self)
  - job_name: 'prometheus'
    scheme: https
    tls_config:
      ca_file: /etc/prometheus/certs/ca.pem
    static_configs:
      - targets: ['prometheus.cicd.local:9090']

  # 2. Node Exporter (Host Hardware)
  - job_name: 'node-exporter'
    scheme: https
    tls_config:
      ca_file: /etc/prometheus/certs/ca.pem
      # Verified: Cert has IP SAN 172.30.0.1
    static_configs:
      - targets: ['172.30.0.1:9100']

  # 3. cAdvisor (Container Stats)
  - job_name: 'cadvisor'
    static_configs:
      - targets: ['cadvisor.cicd.local:8080']

  # 4. Elasticsearch Exporter
  - job_name: 'elasticsearch-exporter'
    scheme: https
    tls_config:
      ca_file: /etc/prometheus/certs/ca.pem
    static_configs:
      - targets: ['elasticsearch-exporter.cicd.local:9114']

  # 5. GitLab
  - job_name: 'gitlab'
    metrics_path: /-/metrics
    scheme: https
    tls_config:
      ca_file: /etc/prometheus/certs/ca.pem
    static_configs:
      - targets: ['gitlab.cicd.local:10300']

  # 6. Jenkins
  - job_name: 'jenkins'
    metrics_path: /prometheus/
    scheme: https
    tls_config:
      ca_file: /etc/prometheus/certs/ca.pem
    static_configs:
      - targets: ['jenkins.cicd.local:10400']

  # 7. SonarQube
  - job_name: 'sonarqube'
    metrics_path: /api/monitoring/metrics
    static_configs:
      - targets: ['sonarqube.cicd.local:9000']
    http_headers:
      X-Sonar-Passcode: $SONAR_WEB_SYSTEMPASSCODE

  # 8. Artifactory
  - job_name: 'artifactory'
    metrics_path: /artifactory/api/v1/metrics
    scheme: https
    tls_config:
      ca_file: /etc/prometheus/certs/ca.pem
    static_configs:
      - targets: ['artifactory.cicd.local:8443']
    http_headers:
      Authorization: Bearer $ARTIFACTORY_ADMIN_TOKEN

  # 9. Mattermost
  - job_name: 'mattermost'
    static_configs:
      - targets: ['mattermost.cicd.local:8067']
EOF

# B. Grafana Config (grafana.ini)
cat << EOF > "$GRAFANA_BASE/config/grafana.ini"
[server]
protocol = https
domain = grafana.cicd.local
cert_file = /etc/grafana/certs/grafana.crt
cert_key = /etc/grafana/certs/grafana.key
http_port = 3000

[database]
type = postgres
host = postgres.cicd.local:5432
name = grafana
user = grafana
ssl_mode = require

[security]
admin_user = admin
EOF

# C. Grafana Provisioning (datasources.yaml)
# We embed the CA content directly into the YAML for the TLS connection to Prometheus
CA_CONTENT=$(cat "$SRC_CA_CRT" | sed 's/^/          /')

cat << EOF > "$GRAFANA_BASE/provisioning/datasources/datasources.yaml"
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: https://prometheus.cicd.local:9090
    isDefault: true
    jsonData:
      tlsAuth: false
      tlsAuthWithCACert: true
    secureJsonData:
      tlsCACert: |
$CA_CONTENT
EOF

# --- 6. Scoped Environment Files ---
echo "--- Phase 5: Generating Env Files ---"

# Grafana Env
cat << EOF > "$GRAFANA_BASE/grafana.env"
GF_DATABASE_PASSWORD=$GRAFANA_DB_PASSWORD
GF_SECURITY_ADMIN_PASSWORD=$GRAFANA_ADMIN_PASSWORD
EOF

# Elasticsearch Exporter Env
cat << EOF > "$HOST_CICD_ROOT/elk/elasticsearch-exporter.env"
ES_URI=https://elastic:$ELASTIC_PASSWORD@elasticsearch.cicd.local:9200
ES_ALL=true
ES_INDICES=true
ES_CA=/certs/ca.pem
ES_SSL_SKIP_VERIFY=false
EOF

# --- 7. Permissions Lockdown ---
echo "--- Phase 6: Locking Down Permissions ---"

# Prometheus (UID 65534 - nobody)
sudo chown -R 65534:65534 "$PROMETHEUS_BASE"
# Grafana (UID 472 - grafana)
sudo chown -R 472:472 "$GRAFANA_BASE"

# Lock keys
sudo chmod 600 "$PROMETHEUS_BASE/config/certs/prometheus.key"
sudo chmod 600 "$GRAFANA_BASE/config/certs/grafana.key"
sudo chmod 600 "$GRAFANA_BASE/grafana.env"
sudo chmod 600 "$HOST_CICD_ROOT/elk/elasticsearch-exporter.env"

echo "✅ Architect Setup Complete."