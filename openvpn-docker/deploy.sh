#!/bin/bash
# deploy.sh — build and start the OpenVPN container on a remote host via SCP + SSH.
#
# All configuration (VPN settings + deploy target) lives in .env.
# Before first run: cp .env.example .env  and fill in your values.
#
# Usage:
#   ./deploy.sh   # deploy using .env
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

# ── Colours ───────────────────────────────────────────────────────────────────
bold=$'\e[1m'; reset=$'\e[0m'; cyan=$'\e[36m'; green=$'\e[32m'; yellow=$'\e[33m'; red=$'\e[31m'

info()    { echo "${cyan}▶${reset} $*"; }
success() { echo "${green}✔${reset} $*"; }
fatal()   { echo "${red}✖${reset} $*" >&2; exit 1; }

ask_yn() {
    local var="$1" prompt="$2" default="${3:-y}"
    local opts; [[ "$default" == "y" ]] && opts="${bold}Y${reset}/n" || opts="y/${bold}N${reset}"
    printf "  %s [%s]: " "$prompt" "$opts"
    read -r _input
    printf -v "$var" '%s' "${_input:-$default}"
}

# ── Require .env ─────────────────────────────────────────────────────────────
if [[ ! -f "$ENV_FILE" ]]; then
    fatal ".env not found. Copy .env.example to .env and fill in your values first."
fi

info "Loading .env"

# shellcheck source=/dev/null
source "$ENV_FILE"

# ── Validate required deploy vars ─────────────────────────────────────────────
: "${DEPLOY_HOST:?DEPLOY_HOST missing from .env}"
: "${DEPLOY_SSH_KEY:?DEPLOY_SSH_KEY missing from .env}"

DEPLOY_USER="${DEPLOY_USER:-ubuntu}"
DEPLOY_PORT="${DEPLOY_PORT:-22}"
DEPLOY_REMOTE_DIR="${DEPLOY_REMOTE_DIR:-/opt/openvpn}"

# Expand ~ in key path
DEPLOY_SSH_KEY="${DEPLOY_SSH_KEY/#\~/$HOME}"
[[ ! -f "$DEPLOY_SSH_KEY" ]] && fatal "SSH key not found: ${DEPLOY_SSH_KEY}"

SSH_OPTS="-i ${DEPLOY_SSH_KEY} -p ${DEPLOY_PORT} -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=15"
SCP_OPTS="-i ${DEPLOY_SSH_KEY} -P ${DEPLOY_PORT} -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15"
REMOTE="${DEPLOY_USER}@${DEPLOY_HOST}"

# ── Confirm ───────────────────────────────────────────────────────────────────
echo ""
echo "${bold}Ready to deploy${reset}"
printf "  %-22s %s\n" "VPN endpoint:"    "${SERVER_NAME}:${OPENVPN_PORT}/${OPENVPN_PROTO}"
printf "  %-22s %s\n" "MFA required:"    "${REQUIRE_MFA}"
printf "  %-22s %s\n" "Target:"          "${REMOTE}:${DEPLOY_REMOTE_DIR}"
printf "  %-22s %s\n" "SSH key:"         "${DEPLOY_SSH_KEY}"
echo ""
ask_yn _confirm "Proceed?" "y"
[[ "$(echo "${_confirm}" | tr '[:upper:]' '[:lower:]')" != "y" ]] && { info "Aborted."; exit 0; }

# ── Ensure Docker is installed on the remote host ────────────────────────────
echo ""
info "Checking remote dependencies..."
# shellcheck disable=SC2086
ssh $SSH_OPTS "$REMOTE" 'bash -s' << 'REMOTE_SETUP'
set -euo pipefail

ok()   { echo "  ✔ $*"; }
need() { echo "  ▶ $*"; }
die()  { echo "  ✖ $*" >&2; exit 1; }

# ── Detect OS ─────────────────────────────────────────────────────────────────
if [[ ! -f /etc/os-release ]]; then
    die "Cannot detect OS — /etc/os-release not found."
fi
# shellcheck source=/dev/null
source /etc/os-release

ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  COMPOSE_ARCH=x86_64  ;;
    aarch64) COMPOSE_ARCH=aarch64 ;;
    arm64)   COMPOSE_ARCH=aarch64 ;;
    *)       die "Unsupported architecture: $ARCH" ;;
esac

COMPOSE_URL="https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${COMPOSE_ARCH}"
COMPOSE_DEST="/usr/local/lib/docker/cli-plugins/docker-compose"

# ── Install Docker ─────────────────────────────────────────────────────────────
install_docker_ubuntu() {
    need "Installing Docker (Ubuntu)..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq ca-certificates curl gnupg lsb-release
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
        | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin
}

install_docker_al2() {
    need "Installing Docker (Amazon Linux 2)..."
    sudo amazon-linux-extras install docker -y
}

_add_docker_centos_repo() {
    sudo tee /etc/yum.repos.d/docker-ce.repo > /dev/null << 'REPO'
[docker-ce-stable]
name=Docker CE Stable - $basearch
baseurl=https://download.docker.com/linux/centos/9/$basearch/stable
enabled=1
gpgcheck=1
gpgkey=https://download.docker.com/linux/centos/gpg
REPO
}

install_docker_al2023() {
    need "Installing Docker CE (Amazon Linux 2023)..."
    _add_docker_centos_repo
    sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin
}

if command -v docker &>/dev/null; then
    ok "Docker already installed: $(docker --version)"
else
    case "$ID" in
        ubuntu|debian)        install_docker_ubuntu ;;
        amzn)
            case "$VERSION_ID" in
                2)    install_docker_al2 ;;
                2023) install_docker_al2023 ;;
                *)    die "Unsupported Amazon Linux version: $VERSION_ID" ;;
            esac
            ;;
        *)  die "Unsupported OS: $ID $VERSION_ID — install Docker manually." ;;
    esac

    sudo systemctl enable --now docker
    ok "Docker installed: $(sudo docker --version)"
fi

# ── Ensure Docker daemon is running ───────────────────────────────────────────
if ! sudo systemctl is-active --quiet docker; then
    need "Starting Docker daemon..."
    sudo systemctl start docker
fi
ok "Docker daemon running."

# ── Add current user to docker group (takes effect next login) ────────────────
if ! groups | grep -qw docker; then
    need "Adding $(whoami) to docker group..."
    sudo usermod -aG docker "$(whoami)"
    ok "Done — group active for this session via newgrp."
else
    ok "$(whoami) already in docker group."
fi

# ── Install Docker Compose plugin ─────────────────────────────────────────────
if sudo docker compose version &>/dev/null 2>&1; then
    ok "Docker Compose already installed: $(sudo docker compose version)"
else
    need "Installing Docker Compose plugin..."
    sudo mkdir -p "$(dirname "$COMPOSE_DEST")"
    sudo curl -fsSL "$COMPOSE_URL" -o "$COMPOSE_DEST"
    sudo chmod +x "$COMPOSE_DEST"
    ok "Docker Compose installed: $(sudo docker compose version)"
fi

# ── Install / upgrade Docker Buildx plugin ────────────────────────────────────
BUILDX_MIN="0.17.0"

_buildx_ok() {
    local ver
    ver=$(sudo docker buildx version 2>/dev/null | awk '{print $2}' | sed 's/^v//')
    [[ -n "$ver" ]] && printf '%s\n%s\n' "$BUILDX_MIN" "$ver" | sort -V -C
}

if _buildx_ok; then
    ok "Docker Buildx already installed: $(sudo docker buildx version)"
else
    need "Installing/upgrading Docker Buildx plugin (>= ${BUILDX_MIN} required)..."
    case "$ID" in
        ubuntu|debian)
            sudo apt-get install -y -qq docker-buildx-plugin
            ;;
        amzn)
            _add_docker_centos_repo
            # Replace Amazon's docker package with Docker CE to get the up-to-date buildx plugin
            sudo dnf install -y --allowerasing docker-ce docker-ce-cli containerd.io docker-buildx-plugin
            ;;
    esac
    # The package swap may have stopped the daemon; reload and restart
    sudo systemctl daemon-reload
    sudo systemctl enable --now docker
    ok "Docker Buildx installed: $(sudo docker buildx version)"
fi
REMOTE_SETUP

success "Remote dependencies ready."

# ── Copy files ────────────────────────────────────────────────────────────────
echo ""
info "Creating remote directories..."
# shellcheck disable=SC2086
ssh $SSH_OPTS "$REMOTE" "sudo mkdir -p ${DEPLOY_REMOTE_DIR}/config/pam.d ${DEPLOY_REMOTE_DIR}/scripts && sudo chown -R \$(whoami) ${DEPLOY_REMOTE_DIR}"

info "Copying files..."
# shellcheck disable=SC2086
scp $SCP_OPTS \
    "${SCRIPT_DIR}/Dockerfile" \
    "${SCRIPT_DIR}/docker-compose.yml" \
    "${REMOTE}:${DEPLOY_REMOTE_DIR}/"

# Copy config files — routes.conf is runtime-managed and must not be overwritten
# shellcheck disable=SC2086
scp $SCP_OPTS "${SCRIPT_DIR}/config/server.conf.template" \
    "${REMOTE}:${DEPLOY_REMOTE_DIR}/config/"
# shellcheck disable=SC2086
scp $SCP_OPTS -r "${SCRIPT_DIR}/config/pam.d/." \
    "${REMOTE}:${DEPLOY_REMOTE_DIR}/config/pam.d/"

# Only install routes.conf on first deploy; after that it is owned by the workflow
# shellcheck disable=SC2086
if ssh $SSH_OPTS "$REMOTE" "test -f ${DEPLOY_REMOTE_DIR}/config/routes.conf" 2>/dev/null; then
    info "routes.conf already exists on remote — skipping (managed at runtime via workflow)."
else
    # shellcheck disable=SC2086
    scp $SCP_OPTS "${SCRIPT_DIR}/config/routes.conf" \
        "${REMOTE}:${DEPLOY_REMOTE_DIR}/config/"
    success "routes.conf installed (first deploy)."
fi

# shellcheck disable=SC2086
scp $SCP_OPTS -r "${SCRIPT_DIR}/scripts/." "${REMOTE}:${DEPLOY_REMOTE_DIR}/scripts/"

success "Files copied."

# ── .env — diff against remote if exists, prompt before overwrite ─────────────
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    # shellcheck disable=SC2086
    if ssh $SSH_OPTS "$REMOTE" "test -f ${DEPLOY_REMOTE_DIR}/.env" 2>/dev/null; then
        _remote_env_tmp=$(mktemp)
        # shellcheck disable=SC2086
        scp $SCP_OPTS -q "${REMOTE}:${DEPLOY_REMOTE_DIR}/.env" "$_remote_env_tmp"

        echo ""
        if diff -q "$_remote_env_tmp" "${SCRIPT_DIR}/.env" &>/dev/null; then
            success ".env on remote is identical — skipping."
        else
            echo "${yellow}⚠${reset}  Remote .env differs from local. Changes (remote → local):"
            echo ""
            diff --color=always "$_remote_env_tmp" "${SCRIPT_DIR}/.env" 2>/dev/null \
                || diff "$_remote_env_tmp" "${SCRIPT_DIR}/.env" || true
            echo ""
            ask_yn _copy_env "Overwrite remote .env with local?" "n"
            if [[ "$(echo "${_copy_env}" | tr '[:upper:]' '[:lower:]')" == "y" ]]; then
                # shellcheck disable=SC2086
                scp $SCP_OPTS "${SCRIPT_DIR}/.env" "${REMOTE}:${DEPLOY_REMOTE_DIR}/.env"
                success ".env overwritten on remote."
            else
                info "Kept existing remote .env."
            fi
        fi
        rm -f "$_remote_env_tmp"
    else
        ask_yn _copy_env "Copy local .env to ${REMOTE}:${DEPLOY_REMOTE_DIR}/.env?" "y"
        if [[ "$(echo "${_copy_env}" | tr '[:upper:]' '[:lower:]')" == "y" ]]; then
            # shellcheck disable=SC2086
            scp $SCP_OPTS "${SCRIPT_DIR}/.env" "${REMOTE}:${DEPLOY_REMOTE_DIR}/.env"
            success ".env copied to remote."
        else
            info "Skipped — make sure ${DEPLOY_REMOTE_DIR}/.env exists on the server before the container starts."
        fi
    fi
fi

# ── Compose profiles ─────────────────────────────────────────────────────────
COMPOSE_PROFILES=""
if [[ "${ENABLE_ADMIN_UI:-false}" == "true" ]]; then
    COMPOSE_PROFILES="--profile admin"
    info "Admin UI enabled — will start openvpn-admin on port ${ADMIN_PORT:-8080}"
fi

# ── Build and start ───────────────────────────────────────────────────────────
info "Building image and starting container..."
# shellcheck disable=SC2086
ssh $SSH_OPTS "$REMOTE" "
    set -e
    cd ${DEPLOY_REMOTE_DIR}
    sudo docker compose ${COMPOSE_PROFILES} build --pull
    sudo docker compose ${COMPOSE_PROFILES} up -d
    echo ''
    sudo docker compose ${COMPOSE_PROFILES} ps
"

# ── Apply server.conf template changes ────────────────────────────────────────
# The live /data/server.conf is only generated on first init and never updated
# automatically. Regenerate it from the (now-updated) template and reload
# OpenVPN with SIGUSR1 if anything changed. SIGUSR1 preserves the TUN interface
# (persist-tun) so existing clients reconnect automatically within keepalive window.
info "Checking server.conf against template..."
# shellcheck disable=SC2086
ssh $SSH_OPTS "$REMOTE" "
    sudo docker exec openvpn bash -c '
        export EASYRSA_PKI VPN_NETWORK VPN_SUBNET PUSH_DNS_1 PUSH_DNS_2 OPENVPN_PROTO
        envsubst < /etc/openvpn/config-templates/server.conf.template > /tmp/server.conf.new
        if diff -q /tmp/server.conf.new /data/server.conf > /dev/null 2>&1; then
            echo \"  ✔ server.conf is up to date\"
        else
            cp /tmp/server.conf.new /data/server.conf
            echo \"  ▶ server.conf updated — reloading OpenVPN (SIGUSR1)...\"
            kill -USR1 1
        fi
        rm -f /tmp/server.conf.new
    '
"

echo ""
success "OpenVPN is running on ${SERVER_NAME}:${OPENVPN_PORT}/${OPENVPN_PROTO}"
if [[ "${ENABLE_ADMIN_UI:-false}" == "true" ]]; then
    echo ""
    echo "  Admin UI   : http://${SERVER_NAME}:${ADMIN_PORT:-8080}  (user: ${ADMIN_USERNAME:-admin})"
fi
echo ""
echo "  Add a user : ./manage.sh add-user <email>"
echo "  List users : ./manage.sh list-users"
echo "  Logs       : ./manage.sh logs -f"
echo ""
