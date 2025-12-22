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
ART_CONTAINER = "artifactory"

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
    # We assume read access is allowed (usually 644 or user group).
    # If this fails, the user needs to sudo chmod the file first.
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
    # Ensure 'shared' -> 'metrics' -> 'enabled': true
    if 'shared' not in config: config['shared'] = {}
    if 'metrics' not in config['shared']: config['shared']['metrics'] = {}

    config['shared']['metrics']['enabled'] = True
    print(f"   > Set shared.metrics.enabled = true")

    # Ensure 'artifactory' -> 'metrics' -> 'enabled': true
    if 'artifactory' not in config: config['artifactory'] = {}
    if 'metrics' not in config['artifactory']: config['artifactory']['metrics'] = {}

    config['artifactory']['metrics']['enabled'] = True
    print(f"   > Set artifactory.metrics.enabled = true")

    # 3. Write to Temp File (Avoids Permission Denied)
    tmp_path = Path("/tmp/artifactory_system.yaml.tmp")
    print(f"   > Writing patched config to temp file: {tmp_path}")

    with open(tmp_path, 'w') as f:
        # Note: PyYAML strips comments. In a programmatic patch, this is often unavoidable
        # without heavier libs like ruamel.yaml. We prioritize structure correctness here.
        yaml.safe_dump(config, f, default_flow_style=False, sort_keys=False)

    # 4. Overwrite Protected File using Sudo
    run_command(
        ["sudo", "cp", str(tmp_path), str(ART_CONFIG_FILE)],
        "Overwriting system.yaml (sudo)"
    )

    # 5. Cleanup
    os.remove(tmp_path)

    print(f"   ✅ Patched system.yaml")

    # 6. Restart Artifactory
    print(f"--- Restarting Artifactory (This will take time) ---")
    run_command(["docker", "restart", ART_CONTAINER], "Restarting container")

def patch_mattermost():
    print(f"--- Patching Mattermost Configuration (via mmctl) ---")

    # Check if container is running
    try:
        subprocess.run(["docker", "inspect", MM_CONTAINER], check=True, stdout=subprocess.DEVNULL)
    except subprocess.CalledProcessError:
        print(f"⚠️  Mattermost container '{MM_CONTAINER}' not running. Skipping.")
        return

    # Helper for mmctl execution
    def mmctl_set(key, value):
        cmd = [
            "docker", "exec", "-i", MM_CONTAINER,
            "mmctl", "--local", "config", "set", key, str(value)
        ]
        run_command(cmd, f"Setting {key} = {value}")

    # 1. Enable Metrics
    mmctl_set("MetricsSettings.Enable", "true")

    # 2. Set Listen Address (Internal port 8067 is standard)
    mmctl_set("MetricsSettings.ListenAddress", ":8067")

    # 3. Reload Config
    reload_cmd = [
        "docker", "exec", "-i", MM_CONTAINER,
        "mmctl", "--local", "config", "reload"
    ]
    run_command(reload_cmd, "Reloading Mattermost Config")

def main():
    print("🔧 Starting Additional Services Patcher...")

    # Patch Artifactory
    patch_artifactory()

    # Patch Mattermost
    patch_mattermost()

    print("\n✨ All patches applied successfully.")
    print("   - Artifactory: Metrics enabled (restarted).")
    print("   - Mattermost: Metrics enabled on port 8067 (reloaded).")

if __name__ == "__main__":
    main()