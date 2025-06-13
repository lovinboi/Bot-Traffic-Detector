#!/usr/bin/env bash

# This script is designed to safely remove the packages and files
# that were incorrectly installed on the Proxmox host.
# Run this script directly on your Proxmox VE host shell.

echo "--- Starting Cleanup Process ---"
echo "This will remove the packages installed by the previous script."
echo ""
read -p "Press Enter to continue..."

# --- Step 1: Stop and disable the services that were created ---
echo "[INFO] Stopping and disabling created services..."
systemctl stop open-webui.service >/dev/null 2>&1
systemctl disable open-webui.service >/dev/null 2>&1
systemctl stop litellm.service >/dev/null 2>&1
systemctl disable litellm.service >/dev/null 2>&1
echo "[OK] Services stopped and disabled."

# --- Step 2: Remove the created directories ---
echo "[INFO] Removing created directories in /opt/..."
rm -rf /opt/open-webui
rm -rf /opt/litellm
echo "[OK] Directories removed."

# --- Step 3: Remove the created systemd service files ---
echo "[INFO] Removing service files..."
rm -f /etc/systemd/system/open-webui.service
rm -f /etc/systemd/system/litellm.service
systemctl daemon-reload
echo "[OK] Service files removed."

# --- Step 4: Purge the installed packages ---
echo "[INFO] Removing installed packages. This may take a few minutes..."
# We are using 'purge' to remove configuration files as well,
# and '--autoremove' to clean up all the dependencies that were pulled in.
apt-get purge --autoremove -y npm nodejs* python3-pip python3-venv git webpack terser eslint gyp build-essential
echo "[OK] Packages removed."

echo ""
echo "--- Cleanup Complete! ---"
echo "Your Proxmox host has been returned to its previous state."

