#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)
# Copyright (c) 2021-2025 tteck
# Author: havardthom, modified for Pipelines by Gemini
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://openwebui.com/
# Documentation: https://docs.openwebui.com/pipelines/

APP="Open WebUI w/ Pipelines"
var_tags="${var_tags:-ai;interface;pipelines}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-8192}"
var_disk="${var_disk:-25}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function default_settings() {
  CT_TYPE="1"
  PW=""
  CT_ID=$NEXTID
  HN=$NSAPP
  DISK_SIZE="$var_disk"
  CORE_COUNT="$var_cpu"
  RAM_SIZE="$var_ram"
  BRG="vmbr0"
  NET="dhcp"
  GATE=""
  APT_CACHER=""
  APT_CACHER_IP=""
  DISABLE_IPV6="no"
  MTU=""
  SD=""
  NS=""
  MAC=""
  VLAN=""
  SSH="no"
  VERB="no"
  echo_default
}

function update_script() {
  header_info
  check_container_storage
  check_container_resources
  if [[ ! -d /opt/open-webui ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  if [ -x "/usr/bin/ollama" ]; then
    msg_info "Updating Ollama"
    OLLAMA_VERSION=$(ollama -v | awk '{print $NF}')
    RELEASE=$(curl -s https://api.github.com/repos/ollama/ollama/releases/latest | grep "tag_name" | awk '{print substr($2, 3, length($2)-4)}')
    if [ "$OLLAMA_VERSION" != "$RELEASE" ]; then
      curl -fsSLO https://ollama.com/download/ollama-linux-amd64.tgz
      tar -C /usr -xzf ollama-linux-amd64.tgz
      rm -rf ollama-linux-amd64.tgz
      msg_ok "Ollama updated to version $RELEASE"
    else
      msg_ok "Ollama is already up to date."
    fi
  fi

  msg_info "Updating Open WebUI (Patience)"
  systemctl stop open-webui.service
  cd /opt/open-webui
  mkdir -p /opt/open-webui-backup
  cp -rf /opt/open-webui/backend/data /opt/open-webui-backup
  git add -A
  $STD git stash
  $STD git reset --hard
  output=$(git pull --no-rebase)
  if echo "$output" | grep -q "Already up to date."; then
    msg_ok "Open WebUI is already up to date."
  else
    $STD npm install
    export NODE_OPTIONS="--max-old-space-size=3584"
    $STD npm run build
    cd ./backend
    $STD pip install -r requirements.txt -U
    cp -rf /opt/open-webui-backup/* /opt/open-webui/backend
    if git stash list | grep -q 'stash@{'; then
      $STD git stash pop
    fi
  fi
  systemctl start open-webui.service
  
  msg_info "Updating LiteLLM"
  if [ -d /opt/litellm ]; then
    systemctl stop litellm.service
    source /opt/litellm/bin/activate
    pip install --upgrade litellm
    deactivate
    systemctl start litellm.service
    msg_ok "LiteLLM Updated"
  else
    msg_warn "LiteLLM not found, skipping update."
  fi
  
  msg_ok "Updated Successfully"
  exit
}

start
build_container
description

msg_info "Installing Dependencies"
$STD apt-get update
$STD apt-get install -y npm git curl sudo python3-pip python3-venv
msg_ok "Installed Dependencies"

msg_info "Installing Open WebUI"
cd /opt
$STD git clone https://github.com/open-webui/open-webui.git
cd open-webui
$STD npm install
export NODE_OPTIONS="--max-old-space-size=3584" # Prevent build failures on low-RAM systems
$STD npm run build
cd ./backend
$STD pip install -r requirements.txt
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
$STD python3 -m venv /opt/litellm
source /opt/litellm/bin/activate
$STD pip install litellm
deactivate
msg_ok "Installed LiteLLM"

msg_info "Configuring LiteLLM"
mkdir -p /etc/litellm
cat <<EOF >/etc/litellm/config.yaml
# LiteLLM Configuration for Open WebUI Pipelines
# This file tells LiteLLM how to connect to your local Ollama instance.

model_list:
  - model_name: ollama/llama3 # Default model, change if needed
    litellm_params:
      model: ollama/llama3
      api_base: http://127.0.0.1:11434

# You can add more Ollama models here. For example:
#  - model_name: ollama/mistral
#    litellm_params:
#      model: ollama/mistral
#      api_base: http://127.0.0.1:11434

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
$STD systemctl daemon-reload
$STD systemctl enable --now open-webui.service
$STD systemctl enable --now litellm.service
msg_ok "Started Services"

motd_ssh
customize

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access it using the following URL:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:8080${CL}"
echo -e "\n${INFO}${GN}Pipelines are enabled and connected to the local Ollama instance.${CL}"

