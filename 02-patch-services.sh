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