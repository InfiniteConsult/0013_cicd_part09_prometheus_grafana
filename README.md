# Chapter 1: The Challenge - The Opaque Infrastructure

## 1.1 The "Black Box" City

In the previous eight articles, we have meticulously constructed a sovereign, end-to-end Software Supply Chain. We started with the bedrock of **Docker** and a custom **Certificate Authority**, then built a **Library** (GitLab) to store our blueprints, a **Factory** (Jenkins) to manufacture our products, an **Inspector** (SonarQube) to certify their quality, a **Warehouse** (Artifactory) to store them securely, a **Command Center** (Mattermost) to coordinate our teams, and an **Investigation Office** (ELK Stack) to analyze our logs.

Technically, our city is operational. The pipelines run, the code is analyzed, the artifacts are shipped, and the logs are indexed.

Functionally, however, our city is opaque. It is a "Black Box."

We know *that* the factory is running, but we do not know if the engines are overheating. We know the warehouse is accepting packages, but we do not know if the shelves are 99% full. When a build suddenly takes 15 minutes instead of 5, we are forced to guess the cause. Is the Jenkins container CPU-starved? Is the GitLab database locking up? Is the host machine running out of memory?

Currently, the only way to answer these questions is manual intervention. We have to SSH into the host, run `top` to check load averages, install `iotop` to check disk usage, and grepping through application-specific status pages. We are flying a complex spaceship with no instrument panel, relying on the sound of the engine to detect trouble.

In a professional environment, this lack of visibility is a critical risk. We cannot wait for a crash to know we are in danger. We need a centralized **Observatory**—a single pane of glass that constantly measures the vital signs of every component in our stack, alerting us to degradation *before* it becomes a disaster.

To achieve this, we will deploy the industry-standard cloud-native monitoring stack: **Prometheus** (The Brain) and **Grafana** (The Face).

## 1.2 The Technical Barrier: Troubleshooting by Flashlight

The fundamental flaw in our current architecture is not a lack of data; it is a lack of **aggregation**.

Currently, when a developer reports that "the pipeline is stuck," diagnosing the root cause requires a manual, multi-step investigation that resembles troubleshooting by flashlight in a dark room.

1. **Is it the Host?** We must SSH into the server and run `htop`. We might see high load averages, but we cannot tell *history*. Was the load high 10 minutes ago when the build failed, or is it high now because we are running diagnostics? We lack temporal context.
2. **Is it the Factory?** We log into the Jenkins UI to check the build queue. We might see executors are busy, but we cannot see if the JVM heap is exhausted or if Garbage Collection is pausing the system.
3. **Is it the Library?** We check GitLab logs. We might see slow SQL queries, but we cannot easily correlate them with the exact timestamp of the Jenkins build spike.

This disconnected workflow forces us to hold the entire state of the distributed system in our heads. We are trying to manually correlate a CPU spike on the host (Infrastructure Layer) with a slow database query in GitLab (Application Layer) and a timeout in Jenkins (Service Layer). This cognitive load is unsustainable. As our city grows, the complexity of these interactions increases exponentially, turning every minor incident into a major forensic investigation.

## 1.3 The Solution: The Observatory

To solve this, we must decouple **Metric Generation** from **Metric Analysis**. We need a system that passively collects the vital signs of our city and aggregates them into a single, unified view. We need to move from reactive troubleshooting to proactive observability.

We will achieve this by deploying the industry-standard "Cloud Native" monitoring stack:

1. **The Sensors (Exporters):** We will deploy small, lightweight agents alongside our services. These agents act as translators, converting the opaque internal state of a service (Linux Kernel stats, Docker cgroups, JVM memory pools) into a standardized, machine-readable format.
2. **The Brain (Prometheus):** This is our Time-Series Database (TSDB). Unlike traditional monitoring tools that wait for agents to "push" data to them, Prometheus actively "pulls" (scrapes) data from our sensors on a strict schedule. This architectural inversion makes the brain incredibly resilient; if a sensor dies, the brain knows immediately because the scrape fails.
3. **The Face (Grafana):** This is our visualization engine. It connects to the Brain, queries the historical data, and renders it into intuitive, real-time dashboards.

However, deploying this stack in our environment introduces a specific **Integration Hurdle**. We have built a "Zero Trust" city. Our services communicate over strict HTTPS channels using a private Certificate Authority. We cannot simply drop a default Prometheus container into the network and expect it to work. It will be blocked by our security layers. We must engineer our Observatory to possess the same cryptographic identity as the rest of our city, enabling it to peer inside our secure HTTPS enclaves without breaking the chain of trust.

# Chapter 2: Architecture - The Pull Model & The Chain of Trust

## 2.1 The Theory: "Push" vs. "Pull" Monitoring

Before we write code, we must understand the fundamental architectural shift that Prometheus represents. Traditional monitoring systems (like Nagios or older ELK setups) rely on a **"Push"** model. In this model, you install an intelligent agent on every server. This agent collects data and actively transmits it to a central collector.

This model has significant fragility. If the central server goes down, every agent in your fleet panics. They must buffer data locally, consuming RAM on your production servers, or drop data, creating gaps in your history. Furthermore, configuration is decentralized; if you want to change the reporting interval, you often have to update the config on hundreds of agents.

Prometheus inverts this architecture. It uses a **"Pull"** (Scrape) model.

In our stack, the agents (which we call Exporters) are dumb. They do not know Prometheus exists. They simply expose a lightweight HTTP endpoint (`/metrics`) that displays their current state. Prometheus is the active initiator. It wakes up on a defined schedule (e.g., every 15 seconds), reaches out to every target in its configuration, and "scrapes" the current data.

This inversion creates a highly resilient system. If Prometheus goes down for maintenance, the agents don't care; they just keep serving their endpoint. There is no buffering pressure on our production services. If a target dies, Prometheus knows instantly because the network connection fails—there is no waiting for a "heartbeat" to timeout. We control the entire monitoring cadence from one central configuration file (`prometheus.yml`), rather than managing config files scattered across the city.

## 2.2 The Components: Sensors, Brain, and Face

Our Observatory is built on three specialized pillars, each performing a single function with high efficiency.

1. **The Sensors (Exporters & Native Endpoints):**
   These are the translators and signals of our city. In a perfect world, every piece of software would speak Prometheus natively. In reality, we deal with a mix of modern applications and legacy systems. To handle this, we employ two distinct strategies for data collection:
   * **Native Instrumentation:** Many of our "Cloud Native" tools—**GitLab**, **Artifactory**, **SonarQube**, and **Mattermost**—have internalized the need for observability. They expose their own `/metrics` endpoints directly. We do not need to install extra software to monitor them; we simply need to configure Prometheus to scrape their built-in API. Even **Jenkins**, essentially a legacy Java application, joins this category thanks to its Prometheus plugin.
   * **The Exporter Pattern (Translators):** Other components—specifically the **Linux Kernel**, the **Docker Daemon**, and **Elasticsearch**—do not natively speak Prometheus. For these, we deploy "Exporters." These are lightweight sidecar processes that query the target (e.g., reading `/proc` files or hitting the Elasticsearch `_cluster/health` API) and translate that raw data into the standardized Prometheus format on the fly. We use **Node Exporter** for host hardware, **cAdvisor** for container stats, and the **Elasticsearch Exporter** for log cluster health.
   * *Architectural Note:* You will notice we are *not* deploying a PostgreSQL exporter. This is a deliberate scope decision. While a dedicated DB exporter offers deep insight into lock contention and buffer pools, our primary focus is "Service Health" as seen by the application. If GitLab is slow, its native metrics will reveal slow database transaction times, often giving us enough context without the added complexity of managing database credentials for a dedicated exporter.
2. **The Brain (Prometheus):**
   This is the Time-Series Database (TSDB). It is the central authority. It holds the map of the city (`prometheus.yml`) and is responsible for reaching out to every sensor—whether Native or Exporter—to collect data. It stores this data in a highly optimized format on disk and evaluates alerting rules. It is optimized for write throughput and reliability.
3. **The Face (Grafana):**
   This is the visualization engine. While Prometheus is excellent at storing data, its native UI is rudimentary. Grafana connects to Prometheus as a datasource. It executes queries (using PromQL) against the Brain and renders the results into rich, interactive dashboards. It is the single pane of glass where we will observe our city.

## 2.3 The Security Architecture: The Chain of Trust

Security in a distributed system is usually a trade-off between purity and pragmatism. In our "City," our primary directive is **"HTTPS Everywhere."** We have established a private Certificate Authority, and for the vast majority of our citizens—**GitLab, Jenkins, Artifactory, Mattermost, Prometheus, and Grafana**—we strictly enforce encrypted communication. When Prometheus scrapes Jenkins, it validates the server's identity using our Root CA, ensuring that no intruder can spoof the factory's vital signs.

However, we must address two specific architectural exceptions: **SonarQube** and **cAdvisor**.

Unlike our modern "Cloud Native" tools, neither of these applications supports native TLS termination. They expect to sit behind a reverse proxy (like Nginx) that handles the encryption for them. In a high-compliance production environment, we would build custom Docker images that bundle an Nginx sidecar into the container to wrap these services in SSL. However, to keep our architecture lean and focused on the *principles* of observability rather than the nuances of Nginx configuration, we have elected to run these two specific endpoints over plain HTTP.

We mitigate this risk through **Isolation** and **Authentication**:

1. **Network Isolation (cAdvisor):** The cAdvisor container is a "Dark Service." It exposes *no ports* to the host machine. It lives entirely within the `cicd-net` Docker network. The only entity that can reach it is Prometheus, which resides on the same private virtual network. It is effectively air-gapped from the rest of the world.
2. **Strict Authentication (SonarQube):** While SonarQube's metrics travel over HTTP, they are not open to the public. If a rogue process attempts to query the endpoint `http://sonarqube:9000/api/monitoring/metrics`, it will be rejected with an HTTP 403 error: `{"errors":[{"msg":"Insufficient privileges"}]}`. Access requires a high-entropy **System Passcode**, which we generate and inject strictly into the Prometheus configuration. We rely on strong identity (Who are you?) to compensate for the lack of transport encryption (Can anyone read this?) within our private network perimeter.

# Chapter 3: The Architect - Preparing the Environment

## 3.1 The Pre-Computation Strategy

In many tutorials, you are asked to manually create a `prometheus.yml` file, copy-paste some YAML, and hope for the best. In our City, we reject this manual "Click-Ops" approach. It is error-prone, insecure, and hard to replicate.

Instead, we employ a **Pre-Computation Strategy**. We use a shell script—The Architect (`01-setup-monitoring.sh`)—to dynamically generate our configuration files *before* the containers ever launch.

This approach offers critical advantages for our complex environment:

1. **Secret Injection:** We can securely inject high-entropy secrets (like the `SONAR_WEB_SYSTEMPASSCODE` or the `ARTIFACTORY_ADMIN_TOKEN`) directly into the configuration files without ever hardcoding them in our source repository.
2. **Path Consistency:** We ensure that certificate paths match exactly between the host (where we manage files) and the container (where the app reads them).
3. **Permission Management:** We can automate the complex permission hand-offs required to satisfy the strict UID requirements of Prometheus and Grafana.

This script acts as the construction crew that lays the foundation, pours the concrete, and wires the electricity before the residents move in.

## 3.2 The Map of the City (`prometheus.yml`)

The heart of our monitoring system is the `prometheus.yml` file. This file acts as the "Map of the City," telling the Brain exactly where every Sensor is located and how to talk to it.

Our Architect script generates a configuration with **9 distinct scrape jobs**, covering every layer of our stack:

1. **Infrastructure:**
   * `node-exporter`: Monitors the host hardware (CPU, RAM, Disk).
   * `cadvisor`: Monitors Docker containers.
   * `elasticsearch-exporter`: Monitors the log storage cluster.
2. **Applications:**
   * `jenkins`, `gitlab`, `artifactory`, `mattermost`: Monitor the service-level performance (HTTP request rates, build queues, transaction times).
3. **Special Cases:**
   * `sonarqube`: Uses a custom header (`X-Sonar-Passcode`) for authentication instead of a standard token.
   * `prometheus`: The Brain monitors itself to ensure *it* isn't running out of memory.


Crucially, the script enforces our **Zero Trust** model. For every service capable of it (Jenkins, GitLab, Artifactory), we set `scheme: https` and point to the `ca_file`. This ensures that when Prometheus reaches out to scrape metrics, it is validating the cryptographic identity of the target. We are not just blindly trusting that the IP `172.30.0.x` belongs to Jenkins; we are verifying it against our Root CA.

## 3.3 The Integration Hurdle: Embedded Trust (`datasources.yaml`)

While `prometheus.yml` defines how the Brain talks to the Sensors, `datasources.yaml` defines how the Face (Grafana) talks to the Brain (Prometheus).

Since our Prometheus instance is secured with HTTPS, Grafana cannot simply connect to `http://prometheus:9090`. It must connect to `https://prometheus.cicd.local:9090`. This introduces a classic "Chicken and Egg" problem regarding trust. Grafana needs to trust the Certificate Authority (CA) that signed Prometheus's certificate.

In a standard deployment, you might mount the `ca.pem` file into the Grafana container and point to it with a file path. However, this creates a hard dependency on the container's filesystem structure. If the mount fails or the path changes, Grafana breaks.

Our Architect script takes a more robust approach: **Certificate Embedding**.

Using `sed`, the script reads the content of our `ca.pem` on the host, indents it correctly for YAML, and injects the actual certificate data directly into the `datasources.yaml` file under the `secureJsonData.tlsCACert` field.

```yaml
    secureJsonData:
      tlsCACert: |
          -----BEGIN CERTIFICATE-----
          MIIFVTCCAz2gAwIBAgIU...
          ...
          -----END CERTIFICATE-----

```

This makes the configuration **portable** and **self-contained**. Grafana does not need to look for a file on disk; the trust store is baked directly into its provisioning logic. This ensures that the connection between the Face and the Brain is encrypted and verified from the very first millisecond of boot time.

## 3.4 The Critical Barrier: File Permissions (UID 65534 & 472)

The most common reason for a Prometheus or Grafana deployment to fail in a "hardened" environment is a permissions mismatch.

By default, when you mount a host directory into a Docker container, the permissions are passed through verbatim. If your config files on the host are owned by `root` (because you used `sudo`) or your personal user, the process inside the container must have read access to those users' files.

However, for security reasons, neither Prometheus nor Grafana runs as `root`.

* **Prometheus** runs as the `nobody` user (UID **65534**).
* **Grafana** runs as a specific `grafana` user (UID **472**).

If we simply mount our generated configuration files into the containers, they will crash immediately with `permission denied` errors because UID 65534 cannot read a file owned by UID 1000 (your user) or UID 0 (root) with strict permissions.

Our Architect script solves this via **Surgical Ownership**. In Phase 6, it performs a precise `chown` operation:

1. It changes the ownership of the Prometheus configuration and certificate directories to `65534:65534`.
2. It changes the ownership of the Grafana directories to `472:472`.

This ensures that when the containers wake up, the files they need to breathe (configs) and the ground they need to walk on (data volumes) belong to them. This preemptive alignment prevents the "CrashLoopBackOff" nightmare that plagues so many manual deployments.

## 3.5 The Source Code: 01-setup-monitoring.sh

```bash
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

  # 7. SonarQube (Prometheus v3.x Syntax)
  - job_name: 'sonarqube'
    metrics_path: /api/monitoring/metrics
    static_configs:
      - targets: ['sonarqube.cicd.local:9000']
    http_headers:
      X-Sonar-Passcode:
        values: ["$SONAR_WEB_SYSTEMPASSCODE"]

  # 8. Artifactory
  - job_name: 'artifactory'
    metrics_path: /artifactory/api/v1/metrics
    scheme: https
    tls_config:
      ca_file: /etc/prometheus/certs/ca.pem
    static_configs:
      - targets: ['artifactory.cicd.local:8443']
    bearer_token: "$ARTIFACTORY_ADMIN_TOKEN"

  # 9. Mattermost
  - job_name: 'mattermost'
    static_configs:
      - targets: ['mattermost.cicd.local:8067']
EOF


cat << EOF > "$PROMETHEUS_BASE/config/web-config.yml"
tls_server_config:
  cert_file: /etc/prometheus/certs/prometheus.crt
  key_file: /etc/prometheus/certs/prometheus.key
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

```

## 3.6 Deconstructing the Architect

The `01-setup-monitoring.sh` script is the physical implementation of the theory we just discussed. Let’s break down exactly how it enforces our architecture.

### 1. Secrets & Dependencies (Phase 1)

The script begins by sourcing the master `cicd.env` file. It validates that critical dependencies—specifically the `ARTIFACTORY_ADMIN_TOKEN` and `ELASTIC_PASSWORD`—already exist. This enforces the dependency chain: we cannot monitor the Warehouse or the Logs if those services haven't been built yet. It then programmatically generates new high-entropy secrets for Grafana and SonarQube, ensuring no default passwords ever exist in our system. This fulfills the **Pre-Computation Strategy** outlined in **Section 3.1**.

### 2. The Map Generation (Phase 4 - Prometheus)

The script uses a heredoc (`cat << EOF`) to write the `prometheus.yml` file. This isn't a static copy; it is dynamic. Notice how it injects the `$SONAR_WEB_SYSTEMPASSCODE` and `$ARTIFACTORY_ADMIN_TOKEN` variables directly into the scrape configuration. This creates the "Map of the City" discussed in **Section 3.2**, enabling Prometheus to authenticate with our secured endpoints immediately upon startup.

### 3. The Embedded Trust (Phase 4 - Grafana)

In the Grafana provisioning section, the script performs a critical text manipulation operation:
`CA_CONTENT=$(cat "$SRC_CA_CRT" | sed 's/^/          /')`.
It reads the Root CA certificate from the host, indents it to match YAML syntax, and embeds it directly into `datasources.yaml`. This implements the **Certificate Embedding** strategy from **Section 3.3**, allowing Grafana to verify Prometheus's HTTPS identity without needing an external volume mount for trust stores.

### 4. The Permission Fix (Phases 2 & 6)

Finally, the script wraps the configuration generation with explicit permission handling. In Phase 2, it changes directory ownership to the current user to allow writing configs without `sudo`. In Phase 6, it performs the "Surgical Strike" discussed in **Section 3.4**, flipping ownership of the `prometheus` directory to UID `65534` and the `grafana` directory to UID `472`. This guarantees that when the containers launch in later chapters, they encounter a filesystem they can actually read.

## 3.6 Deconstructing the Architect

The `01-setup-monitoring.sh` script is the physical implementation of the theory we just discussed. Let’s break down exactly how it enforces our architecture.

### 1. Secrets & Dependencies (Phase 1)

The script begins by sourcing the master `cicd.env` file. It validates that critical dependencies—specifically the `ARTIFACTORY_ADMIN_TOKEN` and `ELASTIC_PASSWORD`—already exist. This enforces the dependency chain: we cannot monitor the Warehouse or the Logs if those services haven't been built yet. It then programmatically generates new high-entropy secrets for Grafana and SonarQube, ensuring no default passwords ever exist in our system. This fulfills the **Pre-Computation Strategy** outlined in **Section 3.1**.

### 2. The Map Generation (Phase 4 - Prometheus)

The script uses a heredoc (`cat << EOF`) to write the `prometheus.yml` file. This isn't a static copy; it is dynamic. Notice how it injects the `$SONAR_WEB_SYSTEMPASSCODE` and `$ARTIFACTORY_ADMIN_TOKEN` variables directly into the scrape configuration. This creates the "Map of the City" discussed in **Section 3.2**, enabling Prometheus to authenticate with our secured endpoints immediately upon startup.

### 3. The Embedded Trust (Phase 4 - Grafana)

In the Grafana provisioning section, the script performs a critical text manipulation operation:
`CA_CONTENT=$(cat "$SRC_CA_CRT" | sed 's/^/          /')`.
It reads the Root CA certificate from the host, indents it to match YAML syntax, and embeds it directly into `datasources.yaml`. This implements the **Certificate Embedding** strategy from **Section 3.3**, allowing Grafana to verify Prometheus's HTTPS identity without needing an external volume mount for trust stores.

### 4. The Permission Fix (Phases 2 & 6)

Finally, the script wraps the configuration generation with explicit permission handling. In Phase 2, it changes directory ownership to the current user to allow writing configs without `sudo`. In Phase 6, it performs the "Surgical Strike" discussed in **Section 3.4**, flipping ownership of the `prometheus` directory to UID `65534` and the `grafana` directory to UID `472`. This guarantees that when the containers launch in later chapters, they encounter a filesystem they can actually read.

# Chapter 4: The Retrofit – Exposing the Metrics

## 4.1 The Hidden Pulse

We have successfully generated our "Map of the City" (`prometheus.yml`). The Brain knows where to look. However, if we were to launch Prometheus right now, it would be staring at a series of closed doors.

Most enterprise software ships with observability **disabled** or strictly limited by default. This is a sound security practice known as "Information Hiding." A metrics endpoint is essentially a high-resolution blueprint of your internal operations. It reveals your query volume, your memory usage, your error rates, and even the topology of your internal network. Exposing this to the public internet—or even to the wrong subnet—is a vulnerability.

Therefore, our services are currently holding their breath. GitLab's Nginx proxy blocks external access to `/-/metrics`. SonarQube demands a specific authentication header. Artifactory and Mattermost have the feature turned off entirely in their configuration files.

To build our Observatory, we must perform a **"Retrofit."**

We are moving into the realm of **Day 2 Operations**. We are not deploying fresh containers; we are surgically modifying the state of *running* infrastructure. We need to open these specific ports and endpoints to our private `cicd-net` network without exposing them to the host or the outside world.

This presents an engineering challenge: consistency. While our goal is the same for every service ("Open the `/metrics` endpoint"), the implementation varies wildly because each tool speaks a different configuration language:

* **Jenkins:** This is the exception that proves the rule. Because we installed the `prometheus` plugin in **Article 8**, Jenkins is already broadcasting. It exposes `/prometheus/` by default, requiring no further action from us today.
* **The Monoliths (GitLab & SonarQube):** These legacy-style applications are configured via flat text files (`gitlab.rb`) or environment variables (`sonarqube.env`). We will manipulate them using **Bash**.
* **The Modern Stack (Artifactory & Mattermost):** These newer applications store configuration in structured data formats (YAML) or internal databases accessible only via CLI APIs. We cannot safely edit these with `sed` or `echo`; we need the precision of **Python**.

We will tackle these in two waves, starting with the text-based Monoliths.

## 4.2 Patching the Monoliths (GitLab & SonarQube)

Our first target is the legacy stack. These applications rely on traditional configuration files and environment variables. We will automate their reconfiguration using the **Bash** script `02-patch-services.sh`.

This script performs two distinct operations: modifying a host-side text file for GitLab and injecting a secret into a container environment for SonarQube.

### The Source Code: `02-patch-services.sh`

Create this file at `~/Documents/FromFirstPrinciples/articles/0013_cicd_part09_prometheus_grafana/02-patch-services.sh`:

```bash
#!/usr/bin/env bash

#
# -----------------------------------------------------------
#           02-patch-services.sh
#
#  The "Retrofit" Script.
#  Modifies running services to expose metrics endpoints.
#
#  1. GitLab: Updates host-side gitlab.rb & triggers reconfigure.
#  2. SonarQube: Injects System Passcode into env & redeploys.
# -----------------------------------------------------------

set -e
echo "🔧 Starting Service Retrofit..."

# --- 1. Load Secrets & Paths ---
HOST_CICD_ROOT="$HOME/cicd_stack"
MASTER_ENV_FILE="$HOST_CICD_ROOT/cicd.env"

# GitLab Paths
GITLAB_CONFIG="$HOST_CICD_ROOT/gitlab/config/gitlab.rb"

# SonarQube Paths
SONAR_BASE="$HOST_CICD_ROOT/sonarqube"
SONAR_ENV_FILE="$SONAR_BASE/sonarqube.env"
# Determine deploy script location relative to this script or hardcoded
SONAR_DEPLOY_SCRIPT="$HOME/Documents/FromFirstPrinciples/articles/0010_cicd_part06_sonarqube/03-deploy-sonarqube.sh"

if [ ! -f "$MASTER_ENV_FILE" ]; then
    echo "ERROR: Master env file not found."
    exit 1
fi

# Load SONAR_WEB_SYSTEMPASSCODE
set -a; source "$MASTER_ENV_FILE"; set +a

if [ -z "$SONAR_WEB_SYSTEMPASSCODE" ]; then
    echo "ERROR: SONAR_WEB_SYSTEMPASSCODE not found in cicd.env"
    echo "   Did you run 01-setup-monitoring.sh?"
    exit 1
fi

# --- 2. Patch GitLab (Host File Update) ---
echo "--- Patching GitLab ---"

if [ -f "$GITLAB_CONFIG" ]; then
    # Idempotency check: Don't append if it exists
    if ! grep -q "monitoring_whitelist" "$GITLAB_CONFIG"; then
        echo "   Appending monitoring whitelist to host config..."
        # We need sudo because gitlab.rb is owned by root
        echo "gitlab_rails['monitoring_whitelist'] = ['172.30.0.0/24', '127.0.0.1']" | sudo tee -a "$GITLAB_CONFIG" > /dev/null
        echo "   Config updated."
    else
        echo "   Whitelist already present in gitlab.rb."
    fi

    # Trigger Reconfigure if container is running
    if [ "$(docker ps -q -f name=gitlab)" ]; then
        echo "   Triggering GitLab Reconfigure (this will take a minute)..."
        docker exec gitlab gitlab-ctl reconfigure > /dev/null
        echo "✅ GitLab Reconfigured."
    else
        echo "⚠️  GitLab container is not running. Changes will apply on next start."
    fi
else
    echo "❌ ERROR: $GITLAB_CONFIG not found on host."
    exit 1
fi

# --- 3. Patch SonarQube (Env Injection & Redeploy) ---
echo "--- Patching SonarQube ---"

if [ -f "$SONAR_ENV_FILE" ]; then
    echo "   Injecting System Passcode into sonarqube.env..."

    if ! grep -q "SONAR_WEB_SYSTEMPASSCODE" "$SONAR_ENV_FILE"; then
        # Ensure we can write (we likely own the dir, but file might be 600)
        chmod 600 "$SONAR_ENV_FILE"
        echo "" >> "$SONAR_ENV_FILE"
        echo "# Metrics Access" >> "$SONAR_ENV_FILE"
        echo "SONAR_WEB_SYSTEMPASSCODE=$SONAR_WEB_SYSTEMPASSCODE" >> "$SONAR_ENV_FILE"
    else
        echo "   Passcode already present."
    fi

    echo "   Redeploying SonarQube to apply changes..."

    if [ -x "$SONAR_DEPLOY_SCRIPT" ]; then
        # Run the original deploy script from its directory context
        (cd "$(dirname "$SONAR_DEPLOY_SCRIPT")" && ./03-deploy-sonarqube.sh)
        echo "✅ SonarQube Patched and Redeploying."
    else
        echo "❌ ERROR: Sonar deploy script not found at $SONAR_DEPLOY_SCRIPT"
        echo "   Please check the path or ensure Article 10 files exist."
        exit 1
    fi
else
    echo "❌ ERROR: sonarqube.env not found at $SONAR_ENV_FILE"
    exit 1
fi

echo "✨ Retrofit Complete."

```

### Deconstructing the Retrofit

**1. GitLab: The Whitelist (`monitoring_whitelist`)**
GitLab's integrated Prometheus exporter is protected by a strict IP whitelist. By default, it allows only `localhost`. Prometheus, however, lives at `172.30.0.x`.

* **The Config:** The script appends `gitlab_rails['monitoring_whitelist'] = ['172.30.0.0/24', '127.0.0.1']` to the host-side `gitlab.rb` file. This explicitly trusts our entire Docker subnet.
* **The Execution:** Instead of restarting the heavy GitLab container (which takes 5 minutes), we trigger `gitlab-ctl reconfigure` via `docker exec`. This recompiles the internal Nginx configuration on the fly, applying the whitelist in about 60 seconds.

**2. SonarQube: The Secret Handshake (`SONAR_WEB_SYSTEMPASSCODE`)**
SonarQube handles metrics differently. It does not use IP whitelisting; it uses a shared secret.

* **The Injection:** The script reads the `SONAR_WEB_SYSTEMPASSCODE` (which we generated in `01-setup-monitoring.sh`) from the master `cicd.env` and injects it into the scoped `sonarqube.env` file.
* **The Redeployment:** Because Docker environment variables are immutable once a container is created, we cannot just "reload" SonarQube. We must destroy and recreate the container. The script automates this by calling the original `03-deploy-sonarqube.sh` script from 0010_cicd_part06_sonarqube, ensuring a clean state transition.

## 4.2 Patching the Monoliths (GitLab & SonarQube)

Our first target is the legacy stack. These applications rely on traditional configuration files and environment variables. We will automate their reconfiguration using the **Bash** script `02-patch-services.sh`.

This script performs two distinct operations: modifying a host-side text file for GitLab and injecting a secret into a container environment for SonarQube.

### The Source Code: `02-patch-services.sh`

Create this file at `~/Documents/FromFirstPrinciples/articles/0013_cicd_part09_prometheus_grafana/02-patch-services.sh`:

```bash
#!/usr/bin/env bash

#
# -----------------------------------------------------------
#           02-patch-services.sh
#
#  The "Retrofit" Script.
#  Modifies running services to expose metrics endpoints.
#
#  1. GitLab: Updates host-side gitlab.rb & triggers reconfigure.
#  2. SonarQube: Injects System Passcode into env & redeploys.
# -----------------------------------------------------------

set -e
echo "🔧 Starting Service Retrofit..."

# --- 1. Load Secrets & Paths ---
HOST_CICD_ROOT="$HOME/cicd_stack"
MASTER_ENV_FILE="$HOST_CICD_ROOT/cicd.env"

# GitLab Paths
GITLAB_CONFIG="$HOST_CICD_ROOT/gitlab/config/gitlab.rb"

# SonarQube Paths
SONAR_BASE="$HOST_CICD_ROOT/sonarqube"
SONAR_ENV_FILE="$SONAR_BASE/sonarqube.env"
# Determine deploy script location relative to this script or hardcoded
SONAR_DEPLOY_SCRIPT="$HOME/Documents/FromFirstPrinciples/articles/0010_cicd_part06_sonarqube/03-deploy-sonarqube.sh"

if [ ! -f "$MASTER_ENV_FILE" ]; then
    echo "ERROR: Master env file not found."
    exit 1
fi

# Load SONAR_WEB_SYSTEMPASSCODE
set -a; source "$MASTER_ENV_FILE"; set +a

if [ -z "$SONAR_WEB_SYSTEMPASSCODE" ]; then
    echo "ERROR: SONAR_WEB_SYSTEMPASSCODE not found in cicd.env"
    echo "   Did you run 01-setup-monitoring.sh?"
    exit 1
fi

# --- 2. Patch GitLab (Host File Update) ---
echo "--- Patching GitLab ---"

if [ -f "$GITLAB_CONFIG" ]; then
    # Idempotency check: Don't append if it exists
    if ! grep -q "monitoring_whitelist" "$GITLAB_CONFIG"; then
        echo "   Appending monitoring whitelist to host config..."
        # We need sudo because gitlab.rb is owned by root
        echo "gitlab_rails['monitoring_whitelist'] = ['172.30.0.0/24', '127.0.0.1']" | sudo tee -a "$GITLAB_CONFIG" > /dev/null
        echo "   Config updated."
    else
        echo "   Whitelist already present in gitlab.rb."
    fi

    # Trigger Reconfigure if container is running
    if [ "$(docker ps -q -f name=gitlab)" ]; then
        echo "   Triggering GitLab Reconfigure (this will take a minute)..."
        docker exec gitlab gitlab-ctl reconfigure > /dev/null
        echo "✅ GitLab Reconfigured."
    else
        echo "⚠️  GitLab container is not running. Changes will apply on next start."
    fi
else
    echo "❌ ERROR: $GITLAB_CONFIG not found on host."
    exit 1
fi

# --- 3. Patch SonarQube (Env Injection & Redeploy) ---
echo "--- Patching SonarQube ---"

if [ -f "$SONAR_ENV_FILE" ]; then
    echo "   Injecting System Passcode into sonarqube.env..."

    if ! grep -q "SONAR_WEB_SYSTEMPASSCODE" "$SONAR_ENV_FILE"; then
        # Ensure we can write (we likely own the dir, but file might be 600)
        chmod 600 "$SONAR_ENV_FILE"
        echo "" >> "$SONAR_ENV_FILE"
        echo "# Metrics Access" >> "$SONAR_ENV_FILE"
        echo "SONAR_WEB_SYSTEMPASSCODE=$SONAR_WEB_SYSTEMPASSCODE" >> "$SONAR_ENV_FILE"
    else
        echo "   Passcode already present."
    fi

    echo "   Redeploying SonarQube to apply changes..."

    if [ -x "$SONAR_DEPLOY_SCRIPT" ]; then
        # Run the original deploy script from its directory context
        (cd "$(dirname "$SONAR_DEPLOY_SCRIPT")" && ./03-deploy-sonarqube.sh)
        echo "✅ SonarQube Patched and Redeploying."
    else
        echo "❌ ERROR: Sonar deploy script not found at $SONAR_DEPLOY_SCRIPT"
        echo "   Please check the path or ensure Article 10 files exist."
        exit 1
    fi
else
    echo "❌ ERROR: sonarqube.env not found at $SONAR_ENV_FILE"
    exit 1
fi

echo "✨ Retrofit Complete."

```

### Deconstructing the Retrofit

**1. GitLab: The Whitelist (`monitoring_whitelist`)**
GitLab's integrated Prometheus exporter is protected by a strict IP whitelist. By default, it allows only `localhost`. Prometheus, however, lives at `172.30.0.x`.

* **The Config:** The script appends `gitlab_rails['monitoring_whitelist'] = ['172.30.0.0/24', '127.0.0.1']` to the host-side `gitlab.rb` file. This explicitly trusts our entire Docker subnet.
* **The Execution:** Instead of restarting the heavy GitLab container (which takes 5 minutes), we trigger `gitlab-ctl reconfigure` via `docker exec`. This recompiles the internal Nginx configuration on the fly, applying the whitelist in about 60 seconds.

**2. SonarQube: The Secret Handshake (`SONAR_WEB_SYSTEMPASSCODE`)**
SonarQube handles metrics differently. It does not use IP whitelisting; it uses a shared secret.

* **The Injection:** The script reads the `SONAR_WEB_SYSTEMPASSCODE` (which we generated in `01-setup-monitoring.sh`) from the master `cicd.env` and injects it into the scoped `sonarqube.env` file.
* **The Redeployment:** Because Docker environment variables are immutable once a container is created, we cannot just "reload" SonarQube. We must destroy and recreate the container. The script automates this by calling the original `03-deploy-sonarqube.sh` script from Article 10, ensuring a clean state transition.

## 4.3 Patching the Modern Stack (Artifactory & Mattermost)

For our modern, cloud-native applications, we cannot rely on simple text manipulation. Their configurations are stored in structured formats (YAML) or internal databases. We handle this complexity with the Python script `03-patch-additional-services.py`.

### The Source Code: `03-patch-additional-services.py`

Create this file at `~/Documents/FromFirstPrinciples/articles/0013_cicd_part09_prometheus_grafana/03-patch-additional-services.py`:

```python
#!/usr/bin/env python3

import os
import sys
import subprocess
import yaml
from pathlib import Path

# --- Configuration ---
HOME_DIR = Path(os.environ.get("HOME"))
CICD_STACK_DIR = HOME_DIR / "cicd_stack"

# Artifactory Paths
ART_VAR_DIR = CICD_STACK_DIR / "artifactory" / "var"
ART_CONFIG_FILE = ART_VAR_DIR / "etc" / "system.yaml"
# PATH TO ORIGINAL DEPLOY SCRIPT
ART_DEPLOY_SCRIPT = HOME_DIR / "Documents/FromFirstPrinciples/articles/0009_cicd_part05_artifactory/05-deploy-artifactory.sh"

# Mattermost Configuration
MM_CONTAINER = "mattermost"

def run_command(cmd_list, description):
    """Runs a shell command and prints status."""
    print(f"   EXEC: {description}...")
    try:
        result = subprocess.run(
            cmd_list, check=True, capture_output=True, text=True
        )
        print(f"   ✅ Success.")
        return result.stdout.strip()
    except subprocess.CalledProcessError as e:
        print(f"   ❌ Failed: {e.stderr.strip()}")
        sys.exit(1)

def patch_artifactory():
    print(f"--- Patching Artifactory Configuration ({ART_CONFIG_FILE}) ---")

    if not ART_CONFIG_FILE.exists():
        print(f"❌ Error: Config file not found at {ART_CONFIG_FILE}")
        sys.exit(1)

    # 1. Read existing YAML
    try:
        with open(ART_CONFIG_FILE, 'r') as f:
            config = yaml.safe_load(f)
    except PermissionError:
        print("❌ Error: Cannot read config file. Try running: sudo chmod o+r " + str(ART_CONFIG_FILE))
        sys.exit(1)
    except yaml.YAMLError as exc:
        print(f"❌ Error parsing YAML: {exc}")
        sys.exit(1)

    # 2. Modify Structure (Idempotent)
    if 'shared' not in config: config['shared'] = {}
    if 'metrics' not in config['shared']: config['shared']['metrics'] = {}
    config['shared']['metrics']['enabled'] = True
    print(f"   > Set shared.metrics.enabled = true")

    if 'artifactory' not in config: config['artifactory'] = {}
    if 'metrics' not in config['artifactory']: config['artifactory']['metrics'] = {}
    config['artifactory']['metrics']['enabled'] = True
    print(f"   > Set artifactory.metrics.enabled = true")

    # 3. Write to Temp File
    tmp_path = Path("/tmp/artifactory_system.yaml.tmp")

    with open(tmp_path, 'w') as f:
        yaml.safe_dump(config, f, default_flow_style=False, sort_keys=False)

    # 4. Overwrite Protected File
    run_command(
        ["sudo", "cp", str(tmp_path), str(ART_CONFIG_FILE)],
        "Overwriting system.yaml (sudo)"
    )
    os.remove(tmp_path)
    print(f"   ✅ Patched system.yaml")

    # 5. Redeploy using Original Script (Instead of Restart)
    print(f"--- Redeploying Artifactory via Script ---")
    if ART_DEPLOY_SCRIPT.exists() and os.access(ART_DEPLOY_SCRIPT, os.X_OK):
        print(f"   EXEC: {ART_DEPLOY_SCRIPT.name} ...")
        try:
            # Run relative to script directory so it finds its local env files
            subprocess.run(
                f"./{ART_DEPLOY_SCRIPT.name}",
                cwd=str(ART_DEPLOY_SCRIPT.parent),
                check=True,
                shell=True
            )
            print("   ✅ Artifactory Redeployed.")
        except subprocess.CalledProcessError:
            print("   ❌ Failed to redeploy Artifactory.")
    else:
        print(f"   ⚠️  Deploy script not found or not executable at: {ART_DEPLOY_SCRIPT}")
        print("      Falling back to docker restart...")
        run_command(["docker", "restart", "artifactory"], "Restarting container")

def patch_mattermost():
    print(f"--- Patching Mattermost Configuration (via mmctl) ---")

    try:
        subprocess.run(["docker", "inspect", MM_CONTAINER], check=True, stdout=subprocess.DEVNULL)
    except subprocess.CalledProcessError:
        print(f"⚠️  Mattermost container '{MM_CONTAINER}' not running. Skipping.")
        return

    def mmctl_set(key, value):
        cmd = [
            "docker", "exec", "-i", MM_CONTAINER,
            "mmctl", "--local", "config", "set", key, str(value)
        ]
        run_command(cmd, f"Setting {key} = {value}")

    # Enable Metrics & Set Port
    mmctl_set("MetricsSettings.Enable", "true")
    mmctl_set("MetricsSettings.ListenAddress", ":8067")

    # Reload
    reload_cmd = ["docker", "exec", "-i", MM_CONTAINER, "mmctl", "--local", "config", "reload"]
    run_command(reload_cmd, "Reloading Mattermost Config")

def main():
    print("🔧 Starting Additional Services Patcher...")
    patch_artifactory()
    patch_mattermost()
    print("\n✨ All patches applied successfully.")

if __name__ == "__main__":
    main()

```

### Deconstructing the Retrofit

**1. Artifactory: YAML Surgery**
Artifactory 7 stores its configuration in `system.yaml`. This file is owned by UID 1030 and is often read-only to regular users.

* **The Logic:** We use Python's `PyYAML` library to load the file structure into memory. We navigate the nested dictionary to `shared.metrics.enabled` and `artifactory.metrics.enabled`, setting both to `True`. This ensures metrics are collected for both the shared microservices (Router/Access) and the core Artifactory service.
* **The Execution:** We write the modified config to a temporary file and use `sudo cp` to overwrite the protected original. We then trigger the original `05-deploy-artifactory.sh` script to force a clean restart of the Java process.

**2. Mattermost: The CLI Override**
Mattermost offers a powerful command-line interface (`mmctl`) that can modify the server's configuration database in real-time.

* **The Logic:** We execute `mmctl config set MetricsSettings.Enable true` directly inside the container via `docker exec`. We also bind the listener to `:8067` to avoid port conflicts with the main web application.
* **The Execution:** We finalize the change with `mmctl config reload`. Mattermost is unique in our stack; it applies these changes *instantly* without killing the process, demonstrating true cloud-native behavior.

## 4.4 Execution & Verification

Now that we have built our tools, we run them in sequence.

1. **Run the Bash Patcher:**
   ```bash
   chmod +x 02-patch-services.sh
   ./02-patch-services.sh
   
   ```
   *Result:* GitLab reconfigures (approx. 60s) and SonarQube restarts (approx. 2 mins).
2. **Run the Python Patcher:**
   ```bash
   chmod +x 03-patch-additional-services.py
   ./03-patch-additional-services.py
   
   ```
   *Result:* Artifactory restarts (approx. 2 mins) and Mattermost updates immediately.

Our applications are now broadcasting. The doors are open. In the next chapter, we will deploy the translators to handle the infrastructure layer.

# Chapter 5: The Translators – Infrastructure Sensors

## 5.1 The "Translation" Problem

We have successfully retrofitted our applications. GitLab, Jenkins, Artifactory, and Mattermost are now broadcasting their internal metrics in the standardized Prometheus format. We know *what* the software is doing.

But software does not run in a vacuum; it runs on infrastructure.

If the Host Machine runs out of RAM, every container crashes. If the Docker Daemon hangs due to disk I/O throttling, the pipeline stops. If the Elasticsearch cluster splits its brain, the logs vanish.

Crucially, **Prometheus cannot speak to these components directly.**

* The **Linux Kernel** speaks in system calls and `/proc` files.
* The **Docker Daemon** speaks via a Unix Socket and Control Groups (cgroups).
* **Elasticsearch** speaks via a proprietary JSON REST API.

Prometheus only speaks HTTP. It expects to hit a `/metrics` endpoint and receive a plain-text list of key-value pairs. It does not know how to read a `cgroup` or query a Unix socket.

To bridge this gap, we must deploy **Exporters**.

An Exporter is a lightweight "Translation Agent." It sits right next to the infrastructure component it is monitoring (often as a sidecar). Its job is simple:

1. **Query:** It polls the opaque internal state of the system (e.g., reading `/proc/meminfo`).
2. **Translate:** It converts that raw data into the standardized Prometheus exposition format (e.g., `node_memory_MemTotal_bytes`).
3. **Serve:** It exposes a lightweight HTTP server so Prometheus can scrape the translated data.

In this chapter, we will deploy three distinct translators to cover the blind spots in our city:

1. **Node Exporter:** For the Host Hardware (CPU, RAM, Disk, Network).
2. **cAdvisor:** For the Docker Engine (Container resource usage).
3. **Elasticsearch Exporter:** For the Log Storage Cluster (Health and Indices).

We will automate this deployment with `04-deploy-exporters.sh`. However, accessing the *Host* hardware from inside a *Container* requires us to break the very isolation rules we have spent eight articles enforcing.

## 5.2 The Host Sensor: Node Exporter (The "Boundary Breaker")

**Node Exporter** is the industry standard for hardware monitoring. It reads from the Linux `/proc` and `/sys` filesystems to report on CPU usage, memory distribution, disk I/O latency, and network traffic.

However, deploying Node Exporter in a containerized environment introduces a fundamental paradox: we want to monitor the **Host**, but the container is explicitly designed to be isolated *from* the Host. A standard container sees only its own virtual CPU slices and its own virtual network interface. It has no visibility into the physical hardware.

To bridge this gap, we must deliberately break the isolation model we have spent eight articles enforcing. In our deployment script, we apply two powerful flags that "tear down the walls" of the container:

1. **`--network host`:** We remove the network namespace isolation. This allows the exporter to see the host's actual physical network interfaces (eth0, wlan0), not just the virtual interface of the container.
2. **`--pid host`:** We share the Process ID namespace. This allows the exporter to see the host's process table, preventing the "blindness" typical of containerized monitoring tools where they can only see their own children.

### The Security "Dragon": The LAN Exposure

Running a container in Host Mode (`--network host`) comes with a dangerous side effect: **Port Exposure.**

When a normal container listens on port 9100, that port is reachable only inside the Docker network unless we explicitly map it (`-p 9100:9100`). But when a Host Mode container listens on port 9100, it opens that port on **every network interface of the physical machine**.

This means your detailed hardware metrics—potentially revealing kernel versions, running processes, and exact resource usage—would be instantly accessible to anyone on your office WiFi or corporate LAN. In a "Zero Trust" architecture, this information leakage is unacceptable.

### The Solution: The Gateway Bind

We solve this by binding the exporter strictly to the **Docker Gateway IP**.

In our network design (0005_cicd_part01_docker), we established `cicd-net` with a gateway of **`172.30.0.1`**. This IP address represents the "Host Machine" from the perspective of the containers. By configuring Node Exporter to listen *only* on this specific IP (`--web.listen-address=172.30.0.1:9100`), we create a "private door".

* **From the LAN:** The port 9100 is closed.
* **From the Container Network:** Prometheus can reach `172.30.0.1:9100` and scrape the metrics.

### The Trust Gap: Certificates vs. IPs

This binding solution creates a new problem: **TLS Identity**.

Standard SSL certificates are issued to **Domain Names** (e.g., `node-exporter.cicd.local`). However, because of our specific network binding, Prometheus must connect to this target via its **IP Address** (`172.30.0.1`), not a DNS name.

If we used a standard certificate, the TLS handshake would fail because the address in the URL (`172.30.0.1`) does not match the Common Name in the certificate (`node-exporter...`).

To fix this, our `04-deploy-exporters.sh` script includes a specialized function called `generate_node_exporter_cert`. This function dynamically generates a custom OpenSSL configuration that adds a specific **Subject Alternative Name (SAN)** entry:

```ini
[alt_names]
IP.2 = 172.30.0.1

```

By baking the Gateway IP directly into the cryptographic identity of the certificate, we ensure that Prometheus can connect securely to the raw IP address without breaking the chain of trust.

## 5.3 The Container Sensor: cAdvisor (The "Introspector")

While Node Exporter gives us the "Landlord's View" of the building (total electricity used, total water consumed), it tells us nothing about the individual tenants. If the server is slow, Node Exporter can tell us *that* CPU usage is high, but it cannot tell us *who* is responsible. Is Jenkins compiling a massive C++ project? Is GitLab performing a database migration? Or has the Artifactory Java process gone rogue?

To answer these questions, we need an **Introspector**. We need a tool that can look inside the Docker engine, identify every running container, and measure its specific resource consumption against the kernel's accounting ledgers.

The industry standard for this is **cAdvisor** (Container Advisor) by Google.

Deploying cAdvisor involves navigating the complex boundary between the Docker Daemon and the Linux Kernel. Unlike a standard web app that stays in its lane, cAdvisor is designed to be invasive. It essentially "spies" on its neighbors. To allow this, our deployment script grants it significant privileges.

### The Privilege Hurdle

In `04-deploy-exporters.sh`, we launch cAdvisor with a specific set of flags that might look alarming to a security-conscious engineer:

1. **`--privileged`:** We grant the container extended privileges.
2. **`--volume /:/rootfs:ro`:** We mount the entire host filesystem as read-only.
3. **`--volume /var/run:/var/run:ro`:** We mount the Docker socket.
4. **`--volume /sys:/sys:ro`:** We mount the kernel's system directory.

Why is this "God Mode" access necessary?

It comes down to **Control Groups (cgroups)**. This is the Linux kernel feature that Docker uses to limit how much CPU and RAM a container can use. Every time a container writes to RAM or uses a CPU cycle, the kernel updates a counter in a virtual file located deep inside `/sys/fs/cgroup`.

For cAdvisor to report that "Jenkins is using 2GB of RAM," it must be able to read these raw kernel counters directly from the host's `/sys` directory. Furthermore, to know that "cgroup ID 4f3a..." actually corresponds to the name "jenkins," it must talk to the Docker Socket to retrieve the container metadata.

### The Security Mitigation

Granting a container access to the Docker socket is equivalent to giving it root access to the host. If cAdvisor were compromised, an attacker could use that socket to spawn new privileged containers and take over the machine.

We mitigate this risk through **Network Isolation**.

Unlike Node Exporter, which we deliberately exposed to the Host Network, cAdvisor is a "Dark Container."

* We do **not** use `--network host`. It lives inside `cicd-net`.
* We do **not** publish any ports (`-p 8080:8080`).

This means cAdvisor is unreachable from the host machine, the LAN, or the internet. It listens on port 8080 *only* inside the private Docker network. The only entity that can talk to it is Prometheus (which is also on `cicd-net`). By combining high privilege (local access) with zero visibility (network access), we adhere to the Principle of Least Privilege in a containerized context.

## 5.4 The Middleware Sensor: Elasticsearch Exporter (The "Bridge")

Our final infrastructure target is the **Elasticsearch** cluster we built in 0012_cicd_part08_elk. This is the "Memory" of our city, storing gigabytes of build logs and audit trails. If it fills up or slows down, our "Investigation Office" goes dark.

Elasticsearch exposes a wealth of data via its API (`_cluster/health`, `_nodes/stats`), but it does so in hierarchical **JSON**. Prometheus cannot ingest JSON; it requires a flat, line-delimited format.

To solve this, we deploy the **Elasticsearch Exporter**.

This component functions as a **Protocol Bridge**. It sits between the Brain and the Memory.

1. **Incoming:** It accepts a scrape request from Prometheus.
2. **Translation:** It makes authenticated, encrypted API calls to the Elasticsearch cluster.
3. **Outgoing:** It flattens the JSON response into metrics like `elasticsearch_cluster_health_status{color="green"}` and serves them to Prometheus.

### The Authentication Chain

Deploying this bridge in a secured environment requires navigating a complex authentication chain. We effectively have two secured conversations happening simultaneously:

1. **Prometheus  Exporter:** Prometheus must trust the Exporter. We handle this by mounting our standard `web-config.yml` and the `elasticsearch-exporter` certificates we staged in Chapter 3.
2. **Exporter  Elasticsearch:** The Exporter must authenticate with the Database. It needs the `elastic` superuser credentials to query deep statistics.

We solve the second link using the **URI Injection** pattern. In Chapter 3 (`01-setup-monitoring.sh`), we pre-computed a file named `elasticsearch-exporter.env` containing the full connection string:
`ES_URI=https://elastic:PASSWORD@elasticsearch.cicd.local:9200`.

In our deployment script, we extract this URI and pass it to the container:
`--es.uri="$ES_URI"`.

### The Trust Triangle

Finally, we must ensure the Exporter trusts the Database. Since Elasticsearch is serving a self-signed certificate (from our CA), the Exporter (written in Go) will reject the connection by default.

We map our Root CA into the container at `/certs/ca.pem` and explicitly flag the application to use it:
`--es.ca=/certs/ca.pem`.

This closes the loop. Prometheus verifies the Exporter; the Exporter verifies the Database. The Chain of Trust is unbroken.

## 5.5 Execution & Verification

With our three translators defined—Node Exporter for the Host, cAdvisor for the Containers, and ES Exporter for the Middleware—we are ready to deploy.

We automate this using the `04-deploy-exporters.sh` script. This script orchestrates the entire process: generating the custom Gateway certificate, fixing permissions, and launching the containers with the necessary privilege flags.

### The Source Code: `04-deploy-exporters.sh`

Create this file at `~/Documents/FromFirstPrinciples/articles/0013_cicd_part09_prometheus_grafana/04-deploy-exporters.sh`:

```bash
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

```

Run the script from your host machine:

```bash
chmod +x 04-deploy-exporters.sh
./04-deploy-exporters.sh

```

**The Output Analysis:**
Watch the logs closely. You will see:

1. **Certificate Generation:** The script detects the missing `node-exporter` cert and generates a new one with the Gateway IP SAN.
2. **Container Launch:** Three containers spin up (`node-exporter`, `cadvisor`, `elasticsearch-exporter`).
3. **Access Points:** The script concludes by printing the targets:
   * Node Exporter: `https://172.30.0.1:9100/metrics` (Gateway Access).
   * ES Exporter: `https://elasticsearch-exporter.cicd.local:9114/metrics`.
   * cAdvisor: `http://cadvisor:8080/metrics`.

Our sensors are deployed. The city is now broadcasting on all frequencies. Before we turn on the "Brain" to record this data, we must perform a connectivity audit to ensure the signals are reaching the control center.

# Chapter 6: Quality Assurance – The Connectivity Verification

## 6.1 The "Blind Spot" Risk

We have generated our configurations, patched our services, and deployed our translators. On paper, our monitoring infrastructure is complete.

However, if we were to launch Prometheus immediately, we would be taking a significant operational risk. In a complex distributed system like our "City," configuration does not guarantee connectivity.

The moment Prometheus starts, it will attempt to scrape all nine targets simultaneously. If there is a single misconfiguration—a firewall rule blocking port 9100, a typo in a certificate Common Name, or a missing authentication token—Prometheus will flood its own logs with generic, unhelpful errors like `context deadline exceeded` or `connection refused`.

Diagnosing these errors from *within* the Prometheus logs is difficult because Prometheus is a high-level aggregator. It tells you *that* it failed, but rarely *why* it failed in sufficient detail to debug a TLS handshake or a DNS resolution issue.

This creates a **Blind Spot**. We have built the pipes, but we haven't checked if they flow.

To mitigate this, we adopt the philosophy of **"Trust but Verify."** Before we deploy the "Brain" (Prometheus), we must audit the nervous system. We need to perform an integration test that simulates a Prometheus scrape from the exact network vantage point that Prometheus will occupy.

Our verification scope covers three distinct layers of failure:

1. **Network Reachability:** Can we route packets to the target IP/Port? (Is the door open?)
2. **Identity Verification:** Does the internal DNS (`*.cicd.local`) resolve correctly, and does the SSL Certificate match that name? (Is this the right house?)
3. **Security Authorization:** Does the target accept our credentials (`Bearer Token` or `Passcode`) and return a valid HTTP 200 payload? (Do we have the key?)

Only when all three layers pass for every single service will we clear the "Brain" for deployment.

## 6.2 The Vantage Point (Host vs. Container)

A common mistake in validating distributed systems is testing from the wrong vantage point. It is tempting to simply run `curl https://gitlab.cicd.local:10300/` from your host terminal. If it returns a 200 OK, you might assume the system is healthy.

This assumption is dangerous because your **Host Machine** has superpowers that your containers do not.

1. **The `/etc/hosts` Cheat:** Your host machine resolves `gitlab.cicd.local` to `127.0.0.1` because we manually edited the hosts file in Article 7. Containers, however, rely on the internal Docker DNS server (`127.0.0.11`). If Docker DNS fails, your host will still work, but your containers will be blind.
2. **The Network Bypass:** Your host machine accesses the containers via **Port Mapping** (e.g., `127.0.0.1:10300`). Containers access each other via the **Bridge Network** (`172.30.0.x:10300`). Testing via `localhost` bypasses the entire software-defined network (SDN) layer, failing to catch firewall rules or routing errors inside the bridge.
3. **The Trust Store Divergence:** Your host machine trusts the CA because we ran `sudo update-ca-certificates`. The containers trust the CA because we baked it into their images (or mounted it). These are two completely separate filesystems. A pass on the host does not guarantee a pass in the container.

To perform a valid audit, we must simulate the perspective of Prometheus itself. We need to stand inside the `cicd-net` network, use the Docker DNS resolver, and rely on the container's internal CA bundle.

We achieve this by executing our verification logic **inside** the `dev-container`. This container acts as our "Test Probe." It sits on the same network as Prometheus, uses the same DNS, and has the same CA certificate mounted. If the `dev-container` can see the targets, we can be confident that Prometheus will see them too.

## 6.3 The Verifier Script (`05-verify-services.sh`)

To automate this audit, we utilize the `05-verify-services.sh` script. This tool acts as the "Integration Test" for the entire network mesh we have built over the last few articles. It bridges the gap between the host (where we hold the keys) and the container network (where the locks are).

### Architectural Highlights

**1. The Secret Bridge (Memory Injection)**
We face a security dilemma: the authentication tokens (`SONAR_WEB_SYSTEMPASSCODE`, `ARTIFACTORY_ADMIN_TOKEN`) live in `cicd.env` on the Host. We need to use them inside the `dev-container` to run `curl`. We cannot simply `cp` the env file into the container, as that would risk leaving sensitive artifacts on the container's filesystem.

The script solves this by reading the secrets into memory on the host and then injecting them directly into the environment of the `docker exec` process:

```bash
docker exec \
  -e SONAR_PASS="$SONAR_PASS" \
  -e ART_TOKEN="$ART_TOKEN" \
  dev-container \
  bash -c '...'

```

This ensures the secrets exist only in the RAM of the running test process and vanish immediately after the test completes.

**2. The Reusable Probe (`check_metric`)**
To avoid writing repetitive `curl` commands, the script defines a Bash function `check_metric` inside the container context. This function abstracts away the complexity of:

* Handling both HTTP and HTTPS.
* injecting arbitrary headers (Bearer Tokens vs. Sonar Passcodes).
* Parsing the output to verify that actual content was returned (preventing false positives from empty 200 OK responses).

### The Source Code: `05-verify-services.sh`

Create this file at `~/Documents/FromFirstPrinciples/articles/0013_cicd_part09_prometheus_grafana/05-verify-services.sh`:

```bash
#!/usr/bin/env bash

#
# -----------------------------------------------------------
#           05-verify-services.sh
#
#  The "Verifier" Script.
#  Runs a test loop inside the dev-container to validate
#  that all 8 endpoints are reachable and returning metrics.
# -----------------------------------------------------------

set -e

# --- 1. Load Secrets from Host ---
ENV_FILE="$HOME/cicd_stack/cicd.env"

if [ -f "$ENV_FILE" ]; then
    # We source the file so Bash handles quote removal automatically.
    # We run this in a subshell so we don't pollute the main script environment excessively.
    eval $(
        set -a
        source "$ENV_FILE"
        # Print the variables we need so the parent script can capture them
        echo "export SONAR_PASS='$SONAR_WEB_SYSTEMPASSCODE'"
        echo "export ART_TOKEN='$ARTIFACTORY_ADMIN_TOKEN'"
        set +a
    )
else
    echo "❌ ERROR: cicd.env not found."
    exit 1
fi

echo "🚀 Starting Metrics Verification (Targeting: dev-container)..."
echo "---------------------------------------------------"

# --- 2. Execute Loop Inside Container ---
# We pass the secrets as environment variables to the container command
docker exec \
  -e SONAR_PASS="$SONAR_PASS" \
  -e ART_TOKEN="$ART_TOKEN" \
  dev-container \
  bash -c '
    # Function to check a metric endpoint
    check_metric() {
        NAME=$1
        URL=$2
        HEADER_FLAG=${3:-}
        HEADER_VAL=${4:-}

        echo "🔍 $NAME"
        echo "   URL: $URL"

        # We capture the output. If curl fails, it usually prints to stderr.
        # We use tail -2 to show the last few lines of the metric payload.
        if [ -n "$HEADER_FLAG" ]; then
            CONTENT=$(curl -s "$HEADER_FLAG" "$HEADER_VAL" "$URL" | tail -n 2)
        else
            CONTENT=$(curl -s "$URL" | tail -n 2)
        fi

        # Check if content is empty (curl failed silently or empty response)
        if [ -z "$CONTENT" ]; then
            echo "   ❌ FAILED (No Content)"
        else
            echo "$CONTENT"
            echo "   ✅ OK"
        fi
        echo "---------------------------------------------------"
    }

    # --- Infrastructure (The Translators) ---
    check_metric "Node Exporter" "https://172.30.0.1:9100/metrics"
    check_metric "ES Exporter"   "https://elasticsearch-exporter.cicd.local:9114/metrics"
    check_metric "cAdvisor"      "http://cadvisor.cicd.local:8080/metrics"

    # --- Applications (The Retrofit) ---
    check_metric "GitLab"        "https://gitlab.cicd.local:10300/-/metrics"
    check_metric "Jenkins"       "https://jenkins.cicd.local:10400/prometheus/"
    check_metric "Mattermost"    "http://mattermost.cicd.local:8067/metrics"

    # Authenticated Checks
    check_metric "SonarQube"     "http://sonarqube.cicd.local:9000/api/monitoring/metrics" \
        "-H" "X-Sonar-Passcode: $SONAR_PASS"

    check_metric "Artifactory"   "https://artifactory.cicd.local:8443/artifactory/api/v1/metrics" \
        "-H" "Authorization: Bearer $ART_TOKEN"
'

```

## 6.4 Execution & Forensics

We are now ready to audit the city. Run the verification script from your host machine:

```bash
chmod +x 05-verify-services.sh
./05-verify-services.sh

```

**Pro Tip:** The script defaults to showing only the last 2 lines of output (using `tail -n 2`) to keep the console clean. If you wish to inspect the full flood of telemetry—which spans thousands of lines—you can edit the script to remove the `| tail -n 2` pipe and then redirect the output to a file for manual review:
`./05-verify-services.sh > full_metrics_dump.txt`

### The Evidence

When you run the standard script, you should see a cascade of green checks. This is your "Connectivity Certificate."

```text
🚀 Starting Metrics Verification (Targeting: dev-container)...
---------------------------------------------------
🔍 Node Exporter
   URL: https://172.30.0.1:9100/metrics
promhttp_metric_handler_requests_total{code="503"} 0
   ✅ OK
---------------------------------------------------
🔍 cAdvisor
   URL: http://cadvisor.cicd.local:8080/metrics
process_virtual_memory_max_bytes 1.8446744073709552e+19
   ✅ OK
---------------------------------------------------
🔍 GitLab
   URL: https://gitlab.cicd.local:10300/-/metrics
ruby_sampler_duration_seconds_total 499.7820231985699
   ✅ OK
---------------------------------------------------
🔍 SonarQube
   URL: http://sonarqube.cicd.local:9000/api/monitoring/metrics
sonarqube_health_web_status 1.0
   ✅ OK
...

```

If you see `✅ OK` for all 8 targets, you have proven three critical facts:

1. **Routing:** The `cicd-net` bridge is correctly routing traffic between containers and the gateway.
2. **DNS:** The internal names `gitlab.cicd.local` etc. are resolving to the correct internal IPs.
3. **Trust:** The `dev-container` (and therefore Prometheus) successfully negotiated TLS handshakes with our internal Certificate Authority.

But looking at these logs, you might wonder: **What exactly are we looking at?**
What does `ruby_sampler_duration_seconds_total` actually mean? Why is `sonarqube_health_web_status` exactly 1.0?

To move from "Verification" to "Understanding," we need to learn the language of Prometheus.

## 6.5 Metric Anatomy: Understanding the Signal

The output we just witnessed is not random noise. It is a highly structured language known as the **Prometheus Exposition Format**. Every line follows a strict syntax that tells the database exactly how to store and index the data.

To an uninitiated eye, it looks like a wall of text. But once you understand the four fundamental "Data Types," you can read the health of your server like a dashboard.

### 1. The Counter (The "Odometer")

* **Identifier:** Usually ends in `_total` (e.g., `node_cpu_seconds_total`, `http_requests_total`).
* **Behavior:** It starts at zero when the process launches and **only goes up**. It never decreases (unless the process crashes and restarts).
* **The Analogy:** Think of the odometer in a car. It tells you the car has driven 100,000 kilometers in its lifetime.
* **The Usage:** The raw number is mostly useless ("This server has handled 1 million requests since 2021"). The value lies in the **Rate of Change**. By comparing the counter now vs. 1 minute ago, Prometheus can calculate "Requests Per Second."
* **Example from our Log:**
```text
node_network_transmit_drop_total 4671

```


This doesn't mean the network is failing *now*. It means 4,671 packets have been dropped since the machine turned on. If this number jumps to 5,000 in the next second, *then* we have a crisis.

### 2. The Gauge (The "Speedometer")

* **Identifier:** Standard nouns (e.g., `node_memory_MemFree_bytes`, `sonarqube_health_web_status`).
* **Behavior:** It can go up and down arbitrarily.
* **The Analogy:** Think of a speedometer or a fuel gauge. It tells you the state of the system **right now**.
* **The Usage:** You don't calculate the rate of a gauge; you look at its absolute value. Is the tank empty? Is the temperature too high?
* **Example from our Log:**
```text
process_virtual_memory_max_bytes 1.84e+19

```


This is a snapshot. At this exact millisecond, the process has access to this much virtual memory.

### 3. The Histogram (The "Heatmap")

* **Identifier:** Appears as a triplet: `_bucket`, `_sum`, and `_count`.
* **Behavior:** It groups observations into "buckets" to track distribution, usually for latency.
* **The Analogy:** Imagine sorting mail into slots based on weight: "Under 10g", "Under 50g", "Under 100g".
* **The Usage:** This allows us to calculate **Percentiles** (e.g., the P99). It answers questions like "Do 99% of my users see a response time under 0.5 seconds?" even if the average is much lower.
* **Example from our Log (Mattermost):**
```text
mattermost_api_time_bucket{le="0.1"} 15
mattermost_api_time_bucket{le="+Inf"} 20

```


This tells us that out of 20 total requests (`+Inf`), 15 of them completed in **L**ess than or **E**qual to (`le`) 0.1 seconds.

### 4. The Summary (The "Pre-Calculated")

* **Identifier:** Contains a `quantile` label (e.g., `quantile="0.9"`).
* **Behavior:** Similar to a Histogram, but the heavy math (calculating the P99) is done by the **Client** (the app), not the Server (Prometheus).
* **The Usage:** Useful for accurate snapshots of complex runtimes (like Go or Java garbage collection) without burdening the monitoring server with expensive calculations.
* **Example from our Log (Jenkins/Java):**
```text
jvm_gc_collection_seconds{quantile="0.5"} 0.003

```


This tells us the median (0.5) garbage collection pause was 3 milliseconds. We cannot re-aggregate this (you cannot average an average), but it gives us an instant health check.

## 6.6 Decoding the City's Voice (Practical Examples)

Now that we understand the grammar, we can translate the specific messages our city is sending. The `verification` script output provides a glimpse into the operational reality of our stack.

**1. The Infrastructure Voice (Node Exporter & cAdvisor)**

* **The Resource Tank:** `node_memory_MemFree_bytes` (Gauge).
  If this gauge drops near zero, the host is starving. In a Linux environment, "Free" memory is often low because the kernel caches files, so we usually combine this with `node_memory_Cached_bytes` to get the true "Available" memory.
* **The OOM Killer:** `container_memory_failures_total` (Counter).
  This is one of the most critical signals in the Docker ecosystem. If this counter increases, it means a container tried to grab more RAM than its limit allowed, and the kernel likely killed it (OOM Killed). If you see this incrementing for SonarQube, your Java Heap is too big for the container.

**2. The Application Voice (GitLab, Jenkins, SonarQube)**

* **GitLab's Heartbeat:** `ruby_sampler_duration_seconds_total` (Counter).
  GitLab is a massive Ruby on Rails monolith. This metric tracks the time the Ruby runtime spends just managing itself (sampling stack traces for performance profiling). A spike here indicates the application is struggling under its own weight, independent of user traffic.
* **SonarQube's Pulse:** `sonarqube_health_web_status` (Gauge).
  This is a binary signal: `1.0` means healthy, `0.0` means dead. It’s simple, but vital. It tells us that the web server is not just running, but successfully connected to its Database and Elasticsearch backend.
* **Jenkins' Throughput:** `jvm_memory_pool_allocated_bytes_created` (Counter).
  Jenkins is memory-hungry. This counter shows the churn—how many bytes of temporary objects are being created. In a heavy build environment, this number skyrockets as pipelines instantiate thousands of short-lived variables.

**3. The Storage Voice (Artifactory)**

* **The Warehouse Capacity:** `jfrt_stg_summary_repo_size_bytes` (Gauge).
  This tells us the physical disk consumption of a specific repository (e.g., `libs-release-local`). It allows us to set alerts: "Warn me when the Maven repository exceeds 50GB."

## 6.7 Conclusion

We have done the hard work. We have retrofitted the endpoints, built the translators, pierced the isolation layers, and verified the signals.

The nervous system is fully active. Every component of our architecture—from the silicon of the CPU to the Ruby code of GitLab—is now broadcasting a continuous stream of detailed telemetry.

But currently, these signals are just vanishing into the void. We have no "Brain" to record them, analyze them, or alert us when they deviate from the norm.

In the next chapter, we will deploy **Prometheus**. We will configure it to scrape these validated endpoints, storing the history of our city in a Time Series Database so we can finally visualize the invisible.

# Chapter 7: The Brain – Deploying Prometheus

## 7.1 The Time-Series Database (TSDB)

We have successfully built a nervous system. Across our "City," sensors are firing—reporting CPU temperatures, garbage collection pauses, and API latency. However, these signals are ephemeral. If Node Exporter reports that CPU usage spiked to 100% at 3:00 AM, but no one was watching at that exact second, the information is lost forever.

We need a memory. We need a system that can ingest these millions of fleeting data points, timestamp them, and store them efficiently for retrieval.

You might ask: *Why not just use Postgres?* We already have a robust Postgres deployment running for SonarQube and GitLab.

The answer lies in the shape of the data. Operational telemetry is fundamentally different from transactional data.

* **Transactional Data (Postgres):** "User A updated their profile." This is low volume, requires strict consistency (ACID), and often involves updating existing rows.
* **Time-Series Data (Prometheus):** "CPU is 40%... now 42%... now 45%." This is massive volume (thousands of writes per second), purely append-only (we never "update" history), and is queried by time ranges ("Show me the trend over the last hour").

Prometheus is a specialized **Time-Series Database (TSDB)** designed exactly for this workload. It does not wait for agents to send it data (the "Push" model). Instead, it acts as the "Brain" of our architecture. It maintains a list of targets (the "Map" we built in Chapter 3), and every 15 seconds, it reaches out to every limb of the infrastructure to capture its current state (the "Pull" model).

This Pull model is crucial for system reliability. If a service goes down, Prometheus knows immediately because the scrape fails. In a Push model, the monitoring system can't easily distinguish between "The service is down" and "The service is just quiet."

To give our Brain long-term memory, we will mount a Docker volume (`prometheus-data`). This ensures that even if we destroy and redeploy the Prometheus container, the history of our city remains intact.

## 7.2 Security by Design (The "Nobody" User)

Deploying Prometheus introduces a specific operational constraint that catches many engineers off guard: **Identity**.

In the Docker ecosystem, laziness is common. Most containers default to running as `root` (UID 0) inside the container. This makes permission management easy—root can read and write anything—but it is a security nightmare. If a vulnerability is found in the application, the attacker gains root access to the container and potentially the host.

Prometheus takes the high road. The official image is engineered to run as the **`nobody` user (UID 65534)** by default. This is the standard "Least Privilege" identity on Linux systems. It has no shell, no home directory, and most importantly, it owns nothing.

This creates a conflict with our deployment strategy.

We are injecting our "Map" (`prometheus.yml`) and our "Shield" (`web-config.yml`) by **Bind Mounting** them from the Host machine into the container.

* **Host Path:** `~/cicd_stack/prometheus/config/prometheus.yml` (Owned by you, UID 1000).
* **Container Path:** `/etc/prometheus/prometheus.yml` (Read by Prometheus, UID 65534).

If we simply mounted these files, the Prometheus process would crash with `Permission Denied` because the `nobody` user cannot read files owned by your personal account (assuming standard strict permissions).

This explains the "Surgical Strike" we performed back in **Chapter 3** (`01-setup-monitoring.sh`). By running `sudo chown -R 65534:65534` on the configuration directory, we pre-aligned the file ownership. We ensured that when the Brain wakes up, it has the permission to read its own memories.

*Note: For the database itself (`/prometheus`), we utilize a **Named Volume** (`prometheus-data`). Unlike the configuration files which we manage manually, the database storage is managed entirely by the Docker Engine, which handles the complex permissions required for high-throughput writes automatically.*

## 7.3 Self-Defense (TLS for Prometheus)

We often think of Prometheus as a **Client**: it reaches out to scrape metrics from other services. But Prometheus is also a **Server**. It exposes a powerful HTTP API and a Web UI on port 9090.

This interface is the "Brain's" primary output. It is where human operators write PromQL queries to diagnose outages, and it is where visualization tools like Grafana connect to fetch the data they need to draw charts.

In a standard "quick start" tutorial, Prometheus runs on plain HTTP. This is acceptable for a hobby project, but in a production environment (and in our "City"), unencrypted HTTP is a vulnerability. It means that:

1. **Snooping:** Anyone on the network can read the metric stream (which often contains sensitive business intelligence like build volumes or user counts).
2. **Spoofing:** A malicious actor could impersonate the Prometheus server and feed false data to your dashboards.

To prevent this, we apply the same **Zero Trust** standard to the monitoring system that we applied to the application stack. We configure Prometheus to speak **HTTPS** natively.

This is handled by the `--web.config.file` flag in our deployment script. This flag points to the `web-config.yml` file we generated back in Chapter 3, which contains:

```yaml
tls_server_config:
  cert_file: /etc/prometheus/certs/prometheus.crt
  key_file: /etc/prometheus/certs/prometheus.key

```

When Prometheus starts, it will load these certificates and open a secure listener on port 9090.

**The Payoff: End-to-End Trust**

Because we have meticulously managed our Public Key Infrastructure (PKI) throughout this series, we get two massive benefits immediately:

1. **The Host Browser:** When you visit `https://prometheus.cicd.local:9090` from your host machine, you will see a green "Secure" padlock. This is because in 0006_cicd_part02_certificate_authority, we imported our custom Root CA into the host's system trust store. Your browser recognizes the signature and trusts the site instantly.
2. **The Future Connection (Grafana):** In the upcoming chapters, we will deploy Grafana. Grafana will not talk to Prometheus over `http://localhost`. It will connect securely via `https://prometheus.cicd.local:9090`. Because we injected the Root CA into the Grafana container during the "Setup" phase (Chapter 3), this internal API connection will be fully encrypted and mutually trusted without any "insecure skip verify" hacks.

We have now secured the Brain. It scrapes securely, and it serves securely.






## 7.4 The Deployment Script (`06-deploy-prometheus.sh`)

We now have all the components: the User Identity (`nobody`), the Storage Volume (`prometheus-data`), the Configuration Map (`prometheus.yml`), and the TLS Shield (`web-config.yml`).

We bring them together in the deployment script.

**Analysis of the Script:**

* **The Identity Flag (`--user 65534:65534`):** This forces the container to run strictly as the unprivileged `nobody` user. It matches the file ownerships we set on the host config directories.
* **The "Map" Mount:** We mount our handcrafted `prometheus.yml` (from Chapter 3) to `/etc/prometheus/prometheus.yml`. This tells the Brain where the Limbs are.
* **The "Shield" Mount:** We mount the `web-config.yml` and the `certs` directory. This enables the HTTPS listener.
* **The "Memories" Mount:** We map the named volume `prometheus-data` to `/prometheus`. This is where the Time Series Database (TSDB) actually lives.

### The Source Code: `06-deploy-prometheus.sh`

Create this file at `~/Documents/FromFirstPrinciples/articles/0013_cicd_part09_prometheus_grafana/06-deploy-prometheus.sh`:

```bash
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

```

## 7.5 First Breath (Target Verification)

It is time to turn on the machine.

Run the deployment script from your host:

```bash
chmod +x 06-deploy-prometheus.sh
./06-deploy-prometheus.sh

```

If the container starts successfully (check `docker ps`), we proceed to the "Moment of Truth."

Open your web browser on the host and navigate to:
**`https://prometheus.cicd.local:9090/targets`**

*Note: Because you installed the Root CA in the CA article you should see a secure padlock icon in the address bar. The browser trusts this internal site just as it trusts a public bank website.*

### The Goal: 9/9 UP

You will be greeted by the Prometheus Targets interface. This is the real-time status dashboard of the collector.

You are looking for a table listing our 9 defined targets (Node Exporter, cAdvisor, Jenkins, GitLab, etc.).

* **State:** Every single target should be marked **UP** in green.
* **Error:** There should be no red text or "Context Deadline Exceeded" errors.

This screen is the visual confirmation of everything we worked for. It proves that the Brain can reach the Limbs, authenticate, and parse the data.

### The First Query

To prove that data is actually being recorded to the disk, click on **Query** in the top navigation bar.

In the expression bar, type the simplest query possible:

```promql
up

```

Click **Execute**.

You should see a list of results with a value of `1`.
In PromQL, `up` is a synthetic metric.

* `1` = The scrape was successful.
* `0` = The scrape failed.

If you switch to the **Graph** tab (next to Table), you will see a flat line at `1`. This is the heartbeat of your city. As long as that line stays at 1, your infrastructure is alive.

The Brain is active. The data is flowing. We are now ready to give this data a face. In the next chapter, we will deploy **Grafana** to transform these raw numbers into beautiful, actionable insights.