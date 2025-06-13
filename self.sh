#!/usr/bin/env bash
# This script INSTALLS Open WebUI with Pipelines inside an EXISTING Debian 12 LXC.
# It should be run as root inside the container.

# --- Helper Functions ---
function msg_info() { echo -e "\e[1;34m[INFO]\e[0m ${1}"; }
function msg_ok() { echo -e "\e[1;32m[OK]\e[0m ${1}"; }
function msg_error() { echo -e "\e[1;31m[ERROR]\e[0m ${1}"; }

# --- Installation Logic ---
msg_info "--- Starting Open WebUI Installation ---"

export DEBIAN_FRONTEND=noninteractive
msg_info "--- Configuring locale ---"
apt-get update -y >/dev/null
apt-get install -y locales >/dev/null
echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen
locale-gen >/dev/null
export LANG=en_US.UTF-8
export LANGUAGE=en_US:en
export LC_ALL=en_US.UTF-8
msg_ok "Locale configured."

msg_info "--- Installing dependencies ---"
apt-get install -y git curl sudo python3-pip python3-venv >/dev/null
msg_ok "Dependencies installed."

msg_info "--- Installing Node.js v20 ---"
curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null
apt-get install -y nodejs >/dev/null
msg_ok "Node.js v20 installed."

msg_info "--- Cloning Open WebUI Repository ---"
cd /opt
git clone https://github.com/open-webui/open-webui.git
if [ ! -d "/opt/open-webui" ] || [ ! -f "/opt/open-webui/backend/main.py" ]; then
    msg_error "Failed to clone Open WebUI or the repository is incomplete. Please check network and try again."
    exit 1
fi
msg_ok "Repository cloned successfully."

msg_info "--- Installing Frontend (npm install) ---"
cd /opt/open-webui
npm install >/dev/null
msg_ok "Frontend installed."

msg_info "--- Building Frontend (npm run build) - This may take several minutes. ---"
export NODE_OPTIONS="--max-old-space-size=8192"
npm run build >/dev/null
msg_ok "Frontend built successfully."

msg_info "--- Installing Backend (pip install) ---"
cd /opt/open-webui/backend
pip install --break-system-packages -r requirements.txt >/dev/null
msg_ok "Backend installed."

msg_info "--- Installing Ollama ---"
curl -fsSL https://ollama.com/install.sh | sh
msg_ok "Ollama installed."

msg_info "--- Installing LiteLLM for Pipelines ---"
cd /opt
python3 -m venv /opt/litellm
source /opt/litellm/bin/activate
pip install litellm >/dev/null
deactivate
msg_ok "LiteLLM installed."

msg_info "--- Configuring LiteLLM ---"
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
msg_ok "LiteLLM configured."

msg_info "--- Creating Services ---"
# Open WebUI Service
cat <<'EOF' >/etc/systemd/system/open-webui.service
[Unit]
Description=Open WebUI
After=network.target

[Service]
User=root
Group=root
WorkingDirectory=/opt/open-webui
Environment="PIPELINES_URL=http://127.0.0.1:8000"
ExecStart=/bin/sh -c "cd /opt/open-webui && PYTHONPATH=. /usr/local/bin/uvicorn backend.main:app --host 0.0.0.0 --port 8080"
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# LiteLLM Service
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
msg_ok "Services created."

msg_info "--- Starting Services ---"
systemctl daemon-reload
systemctl enable --now open-webui.service
systemctl enable --now litellm.service
msg_ok "Services started."

msg_ok "--- Installation Complete! ---"
echo ""
echo "You can now access Open WebUI at http://<YOUR_LXC_IP>:8080"
echo "Pipelines are enabled and connected to the local Ollama instance."
