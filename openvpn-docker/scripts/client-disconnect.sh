#!/bin/bash
# Called by OpenVPN when a client disconnects (client-disconnect directive).
# Environment (set by OpenVPN):
#   $common_name             — client cert CN (= username)
#   $ifconfig_pool_remote_ip — IP that was assigned to the client
#   $trusted_ip              — client's real IP at disconnect time
#   $bytes_sent / $bytes_received — session traffic counters
set -euo pipefail

log() {
    echo "[client-disconnect] [${common_name:-?}] $*" >> /data/logs/connect.log
}

DURATION=""
if [[ -n "${time_duration:-}" ]]; then
    h=$(( time_duration / 3600 ))
    m=$(( (time_duration % 3600) / 60 ))
    s=$(( time_duration % 60 ))
    DURATION="${h}h${m}m${s}s"
fi

log "Client disconnected from ${trusted_ip:-?}, was ${ifconfig_pool_remote_ip:-?}, duration=${DURATION:-unknown}, sent=${bytes_sent:-?} recv=${bytes_received:-?}"

exit 0
