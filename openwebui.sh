#!/usr/bin/env bash

# Copyright (c) 2021-2025 tteck
# Author: havardthom, modified for Pipelines by Gemini & lovinboi
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://openwebui.com/
# Documentation: https://docs.openwebui.com/pipelines/

# --- Static Settings ---
APP="Open WebUI w/ Pipelines"
var_cpu="4"
var_ram="8192"
var_disk="25"
var_os="debian"
var_version="12"
var_unprivileged="1"
# ---

# --- Helper Functions (Replaced from build.func) ---
function msg_info() {
    echo -e "[INFO] ${1}"
}

function msg_ok() {
    echo -e "[OK] ${1}"
}

function msg_error() {
    echo -e "[ERROR] ${1}"
}

function ask_yes_no() {
    read -p "${1} [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "yes"
    else
        echo "no"
    fi
}
# ---

# --- Main Script ---
echo "----------------------------------------------------"
echo "  Setting up ${APP} for Proxmox VE"
echo "----------------------------------------------------"

# This section would normally build the container.
# For a standalone script, this assumes you are running it inside an EXISTING LXC.
# If you want this script to also create the LXC, that's a much bigger change.

msg_info "Installing Dependencies"
apt-get update
apt-get install -y npm git curl sudo python3-pip python3-venv
msg_ok "Installed Dependencies"

msg_info "Installing Open WebUI"
cd /opt
git clone https://github.com/open-webui/open-webui.git
cd open-webui
npm install
export NODE_OPTIONS="--max-old-space-size=3584" # Prevent build failures on low-RAM systems
npm run build
cd ./backend
pip install -r requirements.txt
msg_ok "Installed Open WebUI"

msg_info "Creating Open WebUI Service"
cat <<EOF >/etc/systemd/system/open-webui.service
[Unit]
Description=Open WebUI
After=network.target

[Service]
User=root
Group=root
WorkingDirectory=/opt/open-webui
ExecStart=/usr/bin/npm run start
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
msg_ok "Created Open WebUI Service"

if [[ "yes" == $(ask_yes_no "Would you like to install Ollama?") ]]; then
  msg_info "Installing Ollama"
  curl -fsSL https://ollama.com/install.sh | sh
  msg_ok "Installed Ollama"
fi

# --- LiteLLM and Pipelines Installation ---
msg_info "Installing LiteLLM for Pipelines"
python3 -m venv /opt/litellm
source /opt/litellm/bin/activate
pip install litellm
deactivate
msg_ok "Installed LiteLLM"

msg_info "Configuring LiteLLM"
mkdir -p /etc/litellm
cat <<EOF >/etc/litellm/config.yaml
# LiteLLM Configuration for Open WebUI Pipelines
model_list:
  - model_name: ollama/llama3 # Default model, change if needed
    litellm_params:
      model: ollama/llama3
      api_base: http://127.0.0.1:11434
settings:
    telemetry: False # Disables telemetry
EOF
msg_ok "Configured LiteLLM"

msg_info "Creating LiteLLM Service"
cat <<EOF >/etc/systemd/system/litellm.service
[Unit]
Description=LiteLLM Proxy for Open WebUI Pipelines
After=network.target

[Service]
User=root
Group=root
WorkingDirectory=/opt/litellm
ExecStart=/opt/litellm/bin/python /opt/litellm/bin/litellm --config /etc/litellm/config.yaml --port 8000
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
msg_ok "Created LiteLLM Service"

msg_info "Enabling Pipelines in Open WebUI"
# Insert the PIPELINES_URL environment variable into the service file
sed -i '/\[Service\]/a Environment="PIPELINES_URL=http://127.0.0.1:8000"' /etc/systemd/system/open-webui.service
msg_ok "Enabled Pipelines"

msg_info "Starting Services"
systemctl daemon-reload
systemctl enable --now open-webui.service
systemctl enable --now litellm.service
msg_ok "Started Services"

echo ""
echo "----------------------------------------------------"
echo "  ${APP} setup is complete!"
echo "----------------------------------------------------"
echo ""
echo "Access it at http://<your-lxc-ip>:8080"
echo "Pipelines are enabled and connected to the local Ollama instance."
