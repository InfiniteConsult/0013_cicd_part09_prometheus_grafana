#!/usr/bin/env bash

#
# -----------------------------------------------------------
#           03-deploy-exporters.sh
#
#  The "Translators" Script.
#  Deploys metrics exporters for Host, Docker, and ES.
# -----------------------------------------------------------

set -e
echo "🚀 Deploying Exporters (The Translators)..."

# --- 1. Load Paths & Secrets ---
HOST_CICD_ROOT="$HOME/cicd_stack"
ELK_BASE="$HOST_CICD_ROOT/elk"
PROMETHEUS_BASE="$HOST_CICD_ROOT/prometheus"
CA_DIR="$HOST_CICD_ROOT/ca"
CA_PASSWORD="password"  # Password for the Root CA Key

# Exporter Config Dirs
NODE_CONF_DIR="$PROMETHEUS_BASE/node_exporter"
ES_EXP_CONF_DIR="$ELK_BASE/elasticsearch-exporter"

# --- 2. Permission Fix (The Host Takeover) ---
echo "--- Preparing Directories ---"
sudo mkdir -p "$NODE_CONF_DIR/certs"
sudo mkdir -p "$ES_EXP_CONF_DIR/certs"

# Take ownership to current user for writing configs
sudo chown -R "$USER":"$USER" "$NODE_CONF_DIR"
sudo chown -R "$USER":"$USER" "$ES_EXP_CONF_DIR"

# --- 3. Custom Certificate Generation ---

ensure_generic_cert() {
    local service_name=$1
    local cert_path="$CA_DIR/pki/services/$service_name/$service_name.crt.pem"
    if [ ! -f "$cert_path" ]; then
        echo "   ⚠️  Certificate for $service_name not found. Generating..."
        ( cd ../0006_cicd_part02_certificate_authority && ./02-issue-service-cert.sh "$service_name" )
        echo "   ✅ Generated $service_name"
    else
        echo "   ℹ️  Certificate for $service_name already exists."
    fi
}

generate_node_exporter_cert() {
    echo "--- Generating Custom Certificate for Node Exporter ---"

    local SERVICE="node-exporter"
    local DOMAIN="node-exporter.cicd.local"
    local GATEWAY_IP="172.30.0.1"

    local KEY_FILE="$NODE_CONF_DIR/certs/node-exporter.key"
    local CRT_FILE="$NODE_CONF_DIR/certs/node-exporter.crt"
    local CSR_FILE="$NODE_CONF_DIR/certs/node-exporter.csr"
    local EXT_FILE="$NODE_CONF_DIR/certs/v3.ext"

    # Check if we need to generate (check if Gateway IP is in existing cert)
    if [ -f "$CRT_FILE" ]; then
        if openssl x509 -text -noout -in "$CRT_FILE" 2>/dev/null | grep -q "$GATEWAY_IP"; then
            echo "   ℹ️  Valid Node Exporter cert exists (IP $GATEWAY_IP present)."
            return
        else
            echo "   ⚠️  Old cert found without Gateway IP. Regenerating..."
        fi
    fi

    echo "   1. Generating Private Key..."
    openssl genrsa -out "$KEY_FILE" 2048

    echo "   2. Generating CSR..."
    openssl req -new -key "$KEY_FILE" -out "$CSR_FILE" \
        -subj "/C=ZA/ST=Gauteng/L=Johannesburg/O=Local CICD Stack/CN=$DOMAIN"

    echo "   3. Creating SAN Extension..."
    cat << EOF > "$EXT_FILE"
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = $DOMAIN
DNS.2 = localhost
IP.1 = 127.0.0.1
IP.2 = $GATEWAY_IP
EOF

    echo "   4. Signing with Root CA..."
    sudo openssl x509 -req -in "$CSR_FILE" \
        -CA "$CA_DIR/pki/certs/ca.pem" \
        -CAkey "$CA_DIR/pki/private/ca.key" \
        -CAcreateserial \
        -out "$CRT_FILE" \
        -days 825 \
        -sha256 \
        -extfile "$EXT_FILE" \
        -passin pass:"$CA_PASSWORD"

    sudo chown "$USER":"$USER" "$CRT_FILE"
    rm "$CSR_FILE" "$EXT_FILE"
    echo "   ✅ Generated Custom Node Exporter Cert."
}

echo "--- Verifying Certificates ---"
generate_node_exporter_cert
ensure_generic_cert "elasticsearch-exporter.cicd.local"

# --- 4. Stage Certificates ---
echo "--- Staging Certificates ---"

cp "$CA_DIR/pki/services/elasticsearch-exporter.cicd.local/elasticsearch-exporter.cicd.local.crt.pem" "$ES_EXP_CONF_DIR/certs/elasticsearch-exporter.crt"
cp "$CA_DIR/pki/services/elasticsearch-exporter.cicd.local/elasticsearch-exporter.cicd.local.key.pem" "$ES_EXP_CONF_DIR/certs/elasticsearch-exporter.key"
cp "$CA_DIR/pki/certs/ca.pem" "$ES_EXP_CONF_DIR/certs/ca.pem"

# --- 5. Generate TLS Web Configs ---
echo "--- Generating TLS Web Configs ---"

cat << EOF > "$NODE_CONF_DIR/web-config.yml"
tls_server_config:
  cert_file: /etc/node_exporter/certs/node-exporter.crt
  key_file: /etc/node_exporter/certs/node-exporter.key
EOF

cat << EOF > "$ES_EXP_CONF_DIR/web-config.yml"
tls_server_config:
  cert_file: /etc/elasticsearch_exporter/certs/elasticsearch-exporter.crt
  key_file: /etc/elasticsearch_exporter/certs/elasticsearch-exporter.key
EOF

# --- 6. Permission Lockdown (UID 65534) ---
echo "--- Locking Permissions (UID 65534) ---"
sudo chown -R 65534:65534 "$NODE_CONF_DIR"
sudo chown -R 65534:65534 "$ES_EXP_CONF_DIR"
sudo chmod 600 "$NODE_CONF_DIR/certs/node-exporter.key"
sudo chmod 600 "$ES_EXP_CONF_DIR/certs/elasticsearch-exporter.key"

# --- 7. Deploy Node Exporter ---
echo "--- Deploying Node Exporter (Host Hardware) ---"
if [ "$(docker ps -q -f name=node-exporter)" ]; then docker rm -f node-exporter; fi

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

# --- 8. Deploy Elasticsearch Exporter ---
echo "--- Deploying ES Exporter ---"
if [ "$(docker ps -q -f name=elasticsearch-exporter)" ]; then docker rm -f elasticsearch-exporter; fi

ES_ENV_FILE="$HOST_CICD_ROOT/elk/elasticsearch-exporter.env"

if [ -f "$ES_ENV_FILE" ]; then
    ES_URI=$(sudo grep ES_URI "$ES_ENV_FILE" | cut -d= -f2-)
else
    echo "❌ ERROR: ES env file not found at $ES_ENV_FILE"
    exit 1
fi

docker run -d \
  --name elasticsearch-exporter \
  --restart always \
  --network cicd-net \
  --hostname elasticsearch-exporter.cicd.local \
  --volume "$ES_EXP_CONF_DIR/web-config.yml":/web-config.yml:ro \
  --volume "$ES_EXP_CONF_DIR/certs":/etc/elasticsearch_exporter/certs:ro \
  --volume "$ES_EXP_CONF_DIR/certs/ca.pem":/certs/ca.pem:ro \
  quay.io/prometheuscommunity/elasticsearch-exporter:latest \
  --web.config.file=/web-config.yml \
  --es.uri="$ES_URI" \
  --es.ca=/certs/ca.pem \
  --es.all \
  --es.indices

# --- 9. Deploy cAdvisor ---
echo "--- Deploying cAdvisor (Container Stats) ---"
if [ "$(docker ps -q -f name=cadvisor)" ]; then docker rm -f cadvisor; fi

docker run -d \
  --name cadvisor \
  --restart always \
  --network cicd-net \
  --hostname cadvisor.cicd.local \
  --privileged \
  --device /dev/kmsg \
  --volume /:/rootfs:ro \
  --volume /var/run:/var/run:ro \
  --volume /sys:/sys:ro \
  --volume /var/lib/docker/:/var/lib/docker:ro \
  --volume /dev/disk/:/dev/disk:ro \
  ghcr.io/google/cadvisor:latest

echo "✅ Exporters Deployed."
echo "   - Node Exporter: https://172.30.0.1:9100/metrics (Gateway Bind)"
echo "   - ES Exporter:   https://elasticsearch-exporter.cicd.local:9114/metrics"
echo "   - cAdvisor:      http://cadvisor:8080/metrics"