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