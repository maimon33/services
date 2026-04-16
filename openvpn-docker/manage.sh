#!/bin/bash
# manage.sh — manage VPN users and container remotely.
# All connection settings are read from .env (same file used by deploy.sh).
#
# Usage:
#   ./manage.sh <command> [args]
#
# Commands:
#   add-user    <username>          Create user, print TOTP QR, download both profiles locally
#   revoke-user <username>          Revoke a user's certificate (removes both profiles)
#   list-users                      List all users and cert status
#   get-config  <username> [full|split|both]  Download profile(s) to current directory
#   setup-totp  <username>          Regenerate TOTP secret for a user
#   list-routes              Show current routes.conf
#   add-route   <entry>      Add a CIDR, IP, or hostname to routes.conf
#   remove-route <entry>     Remove an entry from routes.conf (exact match)
#   logs        [-f]         Show container logs (pass -f to follow)
#   status                   Show container status
#   restart                  Restart the OpenVPN container

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

# ── Colours ───────────────────────────────────────────────────────────────────
bold=$'\e[1m'; reset=$'\e[0m'; cyan=$'\e[36m'; green=$'\e[32m'; red=$'\e[31m'

info()    { echo "${cyan}▶${reset} $*"; }
success() { echo "${green}✔${reset} $*"; }
fatal()   { echo "${red}✖${reset} $*" >&2; exit 1; }

usage() {
    grep '^#' "$0" | grep -E '^\# (Usage|Commands|  )' | sed 's/^# //'
    exit 1
}

# ── Load .env ─────────────────────────────────────────────────────────────────
[[ -f "$ENV_FILE" ]] || fatal ".env not found. Copy .env.example to .env first."
# shellcheck source=/dev/null
source "$ENV_FILE"

: "${DEPLOY_HOST:?DEPLOY_HOST missing from .env}"
: "${DEPLOY_SSH_KEY:?DEPLOY_SSH_KEY missing from .env}"

DEPLOY_USER="${DEPLOY_USER:-ubuntu}"
DEPLOY_PORT="${DEPLOY_PORT:-22}"
DEPLOY_REMOTE_DIR="${DEPLOY_REMOTE_DIR:-/opt/openvpn}"

DEPLOY_SSH_KEY="${DEPLOY_SSH_KEY/#\~/$HOME}"
[[ -f "$DEPLOY_SSH_KEY" ]] || fatal "SSH key not found: ${DEPLOY_SSH_KEY}"

REMOTE="${DEPLOY_USER}@${DEPLOY_HOST}"
SSH="ssh -i ${DEPLOY_SSH_KEY} -p ${DEPLOY_PORT} -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=15"

# Run a command inside the openvpn container
vpn_exec() { $SSH "$REMOTE" "sudo docker exec openvpn $*"; }

# ── Commands ──────────────────────────────────────────────────────────────────
cmd_add_user() {
    local user="${1:?Usage: manage.sh add-user <username>}"

    info "Creating user '${user}'..."
    vpn_exec vpn-add-user "$user"

    # Download both profiles
    for type in full split; do
        local out="${user}-${type}.ovpn"
        info "Downloading ${type} profile to ./${out}..."
        $SSH "$REMOTE" "sudo docker exec openvpn cat '/data/clients/${user}-${type}.ovpn'" > "$out"
        chmod 600 "$out"
        success "  ${type}: ./${out}"
    done
}

cmd_revoke_user() {
    local user="${1:?Usage: manage.sh revoke-user <username>}"
    info "Revoking user '${user}'..."
    vpn_exec vpn-revoke-user "$user"
    success "User '${user}' revoked."
}

cmd_list_users() {
    vpn_exec vpn-list-users
}

cmd_get_config() {
    local user="${1:?Usage: manage.sh get-config <username> [full|split|both]}"
    local type="${2:-both}"

    local types=()
    case "$type" in
        full)  types=(full) ;;
        split) types=(split) ;;
        both)  types=(full split) ;;
        *) fatal "tunnel type must be full, split, or both" ;;
    esac

    for t in "${types[@]}"; do
        local out="${user}-${t}.ovpn"
        info "Downloading ${t} profile for '${user}'..."
        $SSH "$REMOTE" "sudo docker exec openvpn cat '/data/clients/${user}-${t}.ovpn'" > "$out"
        chmod 600 "$out"
        success "  ${t}: ./${out}"
    done
}

cmd_setup_totp() {
    local user="${1:?Usage: manage.sh setup-totp <username>}"
    info "Regenerating TOTP for '${user}'..."
    vpn_exec vpn-setup-totp "$user"
}

cmd_logs() {
    local follow=""
    [[ "${1:-}" == "-f" ]] && follow="--follow"
    $SSH "$REMOTE" "sudo docker logs openvpn $follow"
}

cmd_status() {
    $SSH "$REMOTE" "sudo docker compose -f ${DEPLOY_REMOTE_DIR}/docker-compose.yml ps"
}

cmd_restart() {
    info "Restarting OpenVPN container..."
    $SSH "$REMOTE" "sudo docker compose -f ${DEPLOY_REMOTE_DIR}/docker-compose.yml restart"
    success "Container restarted."
}

ROUTES_FILE="${DEPLOY_REMOTE_DIR}/config/routes.conf"

cmd_list_routes() {
    $SSH "$REMOTE" "cat ${ROUTES_FILE}"
}

cmd_add_route() {
    local entry="${1:?Usage: manage.sh add-route <cidr|ip|hostname>}"
    info "Adding route '${entry}'..."
    $SSH "$REMOTE" "echo '${entry}' >> ${ROUTES_FILE}"
    success "Route added. Takes effect on next client reconnect."
}

cmd_remove_route() {
    local entry="${1:?Usage: manage.sh remove-route <cidr|ip|hostname>}"
    info "Removing route '${entry}'..."
    # grep -vF (fixed-string) handles slashes in CIDRs safely; redirect avoids sed -i rename issue
    $SSH "$REMOTE" "
        TMP=\$(mktemp)
        grep -vF '${entry}' ${ROUTES_FILE} > \"\$TMP\" || true
        cat \"\$TMP\" > ${ROUTES_FILE}
        rm -f \"\$TMP\"
    "
    success "Route removed. Takes effect on next client reconnect."
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
CMD="${1:-}"
shift || true

case "$CMD" in
    add-user)      cmd_add_user    "$@" ;;
    revoke-user)   cmd_revoke_user "$@" ;;
    list-users)    cmd_list_users       ;;
    get-config)    cmd_get_config  "$@" ;;
    setup-totp)    cmd_setup_totp  "$@" ;;
    list-routes)   cmd_list_routes      ;;
    add-route)     cmd_add_route   "$@" ;;
    remove-route)  cmd_remove_route "$@" ;;
    logs)          cmd_logs        "$@" ;;
    status)        cmd_status           ;;
    restart)       cmd_restart          ;;
    *)             usage                ;;
esac
