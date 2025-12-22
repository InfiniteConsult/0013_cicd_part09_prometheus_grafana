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
    check_metric "cAdvisor"      "http://cadvisor:8080/metrics"

    # --- Applications (The Retrofit) ---
    check_metric "GitLab"        "https://gitlab.cicd.local:10300/-/metrics"
    check_metric "Jenkins"       "https://jenkins.cicd.local:10400/prometheus/"
    check_metric "Mattermost"    "http://mattermost:8067/metrics"

    # Authenticated Checks
    check_metric "SonarQube"     "http://sonarqube.cicd.local:9000/api/monitoring/metrics" \
        "-H" "X-Sonar-Passcode: $SONAR_PASS"

    check_metric "Artifactory"   "https://artifactory.cicd.local:8443/artifactory/api/v1/metrics" \
        "-H" "Authorization: Bearer $ART_TOKEN"
'