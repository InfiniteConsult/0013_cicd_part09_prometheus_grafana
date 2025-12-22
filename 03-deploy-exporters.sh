#!/usr/bin/env bash

#
# -----------------------------------------------------------
#           03-deploy-exporters.sh
#
#  The "Translators" Script.
#  Deploys metrics exporters for Host, Docker, and ES.
#
#  1. Certs: Auto-generates specific certs for Node/ES exporters.
#  2. Config: Generates web-config.yml for TLS.
#  3. Node Exporter: Host Network + TLS.
#     * SECURITY: Binds to 172.30.0.1 (cicd-net Gateway) ONLY.
#  4. ES Exporter: Cicd-net + TLS + CA Trust.
#  5. cAdvisor: Cicd-net + HTTP (Docker Socket access).
# -----------------------------------------------------------

set -e
echo "🚀 Deploying Exporters (The Translators)..."

# --- 1. Load Paths ---
HOST_CICD_ROOT="$HOME/cicd_stack"
ELK_BASE="$HOST_CICD_ROOT/elk"
PROMETHEUS_BASE="$HOST_CICD_ROOT/prometheus"
CA_DIR="$HOST_CICD_ROOT/ca"

# Exporter Config Dirs
NODE_CONF_DIR="$PROMETHEUS_BASE/node_exporter"
ES_EXP_CONF_DIR="$ELK_BASE/elasticsearch-exporter"

# Ensure dirs exist
mkdir -p "$NODE_CONF_DIR/certs"
mkdir -p "$ES_EXP_CONF_DIR/certs"

# --- 2. Certificate Generation (Self-Healing) ---
# Function to check and generate certificate if missing
ensure_cert() {
    local service_name=$1
    local cert_path="$CA_DIR/pki/services/$service_name/$service_name.crt.pem"

    if [ ! -f "$cert_path" ]; then
        echo "   ⚠️  Certificate for $service_name not found. Generating..."
        # We assume this script is running in the article directory, so we step back to CA dir
        # If the CA script is missing, this will fail (as expected).
        (
            cd ../0006_cicd_part02_certificate_authority || exit 1
            if [ -x "./02-issue-service-cert.sh" ]; then
                ./02-issue-service-cert.sh "$service_name"
            else
                echo "❌ ERROR: CA generation script not found."
                exit 1
            fi
        )
        echo "   ✅ Generated $service_name"
    else
        echo "   ℹ️  Certificate for $service_name already exists."
    fi
}

echo "--- Verifying Certificates ---"
ensure_cert "node-exporter.cicd.local"
ensure_cert "elasticsearch-exporter.cicd.local"

# --- 3. Stage Certificates ---
echo "--- Staging Certificates ---"

# Copy Node Exporter Certs
cp "$CA_DIR/pki/services/node-exporter.cicd.local/node-exporter.cicd.local.crt.pem" "$NODE_CONF_DIR/certs/node-exporter.crt"
cp "$CA_DIR/pki/services/node-exporter.cicd.local/node-exporter.cicd.local.key.pem" "$NODE_CONF_DIR/certs/node-exporter.key"
# Fix permissions (User inside container is typically 'nobody' or root depending on image)
chmod 644 "$NODE_CONF_DIR/certs/node-exporter.crt"
chmod 644 "$NODE_CONF_DIR/certs/node-exporter.key"

# Copy ES Exporter Certs
cp "$CA_DIR/pki/services/elasticsearch-exporter.cicd.local/elasticsearch-exporter.cicd.local.crt.pem" "$ES_EXP_CONF_DIR/certs/elasticsearch-exporter.crt"
cp "$CA_DIR/pki/services/elasticsearch-exporter.cicd.local/elasticsearch-exporter.cicd.local.key.pem" "$ES_EXP_CONF_DIR/certs/elasticsearch-exporter.key"
# Also need CA to verify ES connection
cp "$CA_DIR/pki/certs/ca.pem" "$ES_EXP_CONF_DIR/certs/ca.pem"

chmod 644 "$ES_EXP_CONF_DIR/certs/"*

# --- 4. Generate TLS Web Configs ---
echo "--- Generating TLS Web Configs ---"

# Node Exporter Web Config
cat << EOF > "$NODE_CONF_DIR/web-config.yml"
tls_server_config:
  cert_file: /etc/node_exporter/certs/node-exporter.crt
  key_file: /etc/node_exporter/certs/node-exporter.key
EOF

# ES Exporter Web Config
cat << EOF > "$ES_EXP_CONF_DIR/web-config.yml"
tls_server_config:
  cert_file: /etc/elasticsearch_exporter/certs/elasticsearch-exporter.crt
  key_file: /etc/elasticsearch_exporter/certs/elasticsearch-exporter.key
EOF

# --- 5. Deploy Node Exporter ---
echo "--- Deploying Node Exporter (Host Hardware) ---"
if [ "$(docker ps -q -f name=node-exporter)" ]; then docker rm -f node-exporter; fi

# NOTE: We bind to 172.30.0.1 (Gateway IP) to expose metrics ONLY to the
# internal bridge network and the host, effectively blocking external LAN access.

docker run -d \
  --name node-exporter \
  --restart always \
  --network host \
  --pid host \
  --volume "/:/host:ro,rslave" \
  --volume "$NODE_CONF_DIR/web-config.yml":/etc/node_exporter/web-config.yml:ro \
  --volume "$NODE_CONF_DIR/certs":/etc/node_exporter/certs:ro \
  quay.io/prometheus/node-exporter:latest \
  --path.rootfs=/host \
  --web.listen-address=172.30.0.1:9100 \
  --web.config.file=/etc/node_exporter/web-config.yml

# --- 6. Deploy Elasticsearch Exporter ---
echo "--- Deploying ES Exporter ---"
if [ "$(docker ps -q -f name=elasticsearch-exporter)" ]; then docker rm -f elasticsearch-exporter; fi

# Env file created by 01-setup-monitoring.sh
ES_ENV_FILE="$HOST_CICD_ROOT/elk/elasticsearch-exporter.env"

# Source env file to get ES_URI variable for the command line
if [ -f "$ES_ENV_FILE" ]; then
    source "$ES_ENV_FILE"
else
    echo "❌ ERROR: ES env file not found at $ES_ENV_FILE"
    exit 1
fi

docker run -d \
  --name elasticsearch-exporter \
  --restart always \
  --network cicd-net \
  --hostname elasticsearch-exporter \
  --env-file "$ES_ENV_FILE" \
  --volume "$ES_EXP_CONF_DIR/web-config.yml":/web-config.yml:ro \
  --volume "$ES_EXP_CONF_DIR/certs":/etc/elasticsearch_exporter/certs:ro \
  --volume "$ES_EXP_CONF_DIR/certs/ca.pem":/certs/ca.pem:ro \
  quay.io/prometheuscommunity/elasticsearch-exporter:latest \
  --web.config.file=/web-config.yml \
  --es.uri="$ES_URI" \
  --es.ca=/certs/ca.pem \
  --es.all \
  --es.indices

# --- 7. Deploy cAdvisor ---
echo "--- Deploying cAdvisor (Container Stats) ---"
if [ "$(docker ps -q -f name=cadvisor)" ]; then docker rm -f cadvisor; fi

# NOTE: Updated to ghcr.io/google/cadvisor:v0.55.1
# Added --device /dev/kmsg for OOM detection support.

docker run -d \
  --name cadvisor \
  --restart always \
  --network cicd-net \
  --hostname cadvisor \
  --privileged \
  --device /dev/kmsg \
  --volume /:/rootfs:ro \
  --volume /var/run:/var/run:ro \
  --volume /sys:/sys:ro \
  --volume /var/lib/docker/:/var/lib/docker:ro \
  --volume /dev/disk/:/dev/disk:ro \
  ghcr.io/google/cadvisor:v0.55.1

echo "✅ Exporters Deployed."
echo "   - Node Exporter: https://172.30.0.1:9100/metrics (Gateway Bind)"
echo "   - ES Exporter:   https://elasticsearch-exporter:9114/metrics"
echo "   - cAdvisor:      http://cadvisor:8080/metrics"