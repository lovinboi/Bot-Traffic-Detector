#!/usr/bin/env bash
# This script creates a new Proxmox LXC container and installs Open WebUI with Pipelines.
# It is designed to be self-contained and run directly on the Proxmox host.
# Copyright (c) 2021-2025 tteck, modified by Gemini & lovinboi

# --- Helper Functions ---
function msg_info() { echo -e "\e[1;34m[INFO]\e[0m ${1}"; }
function msg_ok() { echo -e "\e[1;32m[OK]\e[0m ${1}"; }
function msg_error() { echo -e "\e[1;31m[ERROR]\e[0m ${1}"; exit 1; }

# --- LXC Configuration ---
APP="Open WebUI w/ Pipelines"
var_cpu="4"
var_ram="8192"
var_disk="25"
var_os="debian"
var_version="12"
var_unprivileged="1"
var_hostname="openwebui"

# --- Main Logic ---

# Check if running on Proxmox
if ! command -v pveversion > /dev/null 2>&1; then
  msg_error "This script must be run on a Proxmox VE host."
fi

# Get next available LXC ID
NEXTID=$(pvesh get /cluster/nextid)
msg_info "Next available LXC ID is ${NEXTID}"

# Ask user for LXC ID
read -p "Enter LXC ID for '${APP}' [default: ${NEXTID}]: " CT_ID
CT_ID=${CT_ID:-$NEXTID}

# Get storage location
STORAGE_LIST=$(pvesh get /nodes/$(hostname)/storage --output-format json-pretty | grep 'storage"' | awk -F '"' '{print $4}')
echo "Available storage locations:"
select STORAGE in $STORAGE_LIST; do
  if [ -n "$STORAGE" ]; then
    break
  else
    echo "Invalid selection. Please try again."
  fi
done
msg_info "Using '${STORAGE}' for storage."

# Get Bridge
BRIDGE_LIST=$(pvesh get /nodes/$(hostname)/network --output-format json-pretty | grep '"iface":' | awk -F '"' '{print $4}')
echo "Available network bridges:"
select BRIDGE in $BRIDGE_LIST; do
  if [ -n "$BRIDGE" ]; then
    break
  else
    echo "Invalid selection. Please try again."
  fi
done
msg_info "Using '${BRIDGE}' for network."


# Download LXC Template
msg_info "Updating LXC template list..."
pveam update >/dev/null
msg_info "Downloading Debian 12 template..."
pveam download local debian-12-standard_12.2-1_amd64.tar.zst >/dev/null

# Create LXC
TEMPLATE="local:vztmpl/debian-12-standard_12.2-1_amd64.tar.zst"
msg_info "Creating LXC ${CT_ID}..."
pct create $CT_ID $TEMPLATE --hostname $var_hostname --cores $var_cpu --memory $var_ram --rootfs ${STORAGE}:${var_disk} --net0 name=eth0,bridge=${BRIDGE},ip=dhcp --onboot 1 --unprivileged $var_unprivileged >/dev/null

# Start LXC and wait for network
msg_info "Starting LXC and waiting for network..."
pct start $CT_ID
sleep 5 # Give LXC time to boot

# Get LXC IP
while ! IP=$(pct exec $CT_ID -- ip -4 a show dev eth0 | grep inet | awk '{print $2}' | cut -d/ -f1); do
  msg_info "Waiting for IP address..."
  sleep 2
done

msg_ok "LXC created with IP: ${IP}"

# --- Installation inside the LXC ---
msg_info "--- Starting Installation inside LXC ${CT_ID} ---"

# Define commands to run inside the LXC
INSTALL_COMMANDS="
export DEBIAN_FRONTEND=noninteractive
echo '--- Updating package lists ---'
apt-get update -y >/dev/null
echo '--- Installing dependencies ---'
apt-get install -y npm git curl sudo python3-pip python3-venv >/dev/null

echo '--- Installing Open WebUI ---'
cd /opt
git clone https://github.com/open-webui/open-webui.git >/dev/null
cd open-webui
npm install >/dev/null
export NODE_OPTIONS=\"--max-old-space-size=3584\"
npm run build >/dev/null
cd ./backend
pip install -r requirements.txt >/dev/null

echo '--- Creating Open WebUI Service ---'
cat <<'EOF' >/etc/systemd/system/open-webui.service
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

echo '--- Installing Ollama ---'
curl -fsSL https://ollama.com/install.sh | sh

echo '--- Installing LiteLLM for Pipelines ---'
python3 -m venv /opt/litellm
source /opt/litellm/bin/activate
pip install litellm >/dev/null
deactivate

echo '--- Configuring LiteLLM ---'
mkdir -p /etc/litellm
cat <<'EOF' >/etc/litellm/config.yaml
model_list:
  - model_name: ollama/llama3
    litellm_params:
      model: ollama/llama3
      api_base: http://127.0.0.1:11434
settings:
    telemetry: False
EOF

echo '--- Creating LiteLLM Service ---'
cat <<'EOF' >/etc/systemd/system/litellm.service
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

echo '--- Enabling Pipelines in Open WebUI ---'
sed -i '/\\[Service\\]/a Environment=\"PIPELINES_URL=http://127.0.0.1:8000\"' /etc/systemd/system/open-webui.service

echo '--- Starting Services ---'
systemctl daemon-reload
systemctl enable --now open-webui.service
systemctl enable --now litellm.service
"

# Execute the installation commands inside the LXC
pct exec $CT_ID -- bash -c "${INSTALL_COMMANDS}"

# --- Final Output ---
msg_ok "--- Installation Complete! ---"
echo ""
echo "You can access Open WebUI at:"
echo "http://${IP}:8080"
echo ""
echo "Pipelines are enabled and connected to the local Ollama instance."
echo "You may need to pull a model in Ollama before use (e.g., 'ollama run llama3')."
