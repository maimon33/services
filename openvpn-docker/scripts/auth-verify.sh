#!/bin/bash
# Called by OpenVPN via auth-user-pass-verify.
# $1 = path to temp file containing:
#   Line 1: username
#   Line 2: password (TOTP code)
# Environment: $common_name = cert CN set by OpenVPN
set -euo pipefail

AUTH_FILE="${1:?missing auth file argument}"
: "${REQUIRE_MFA:=true}"

USERNAME=$(sed -n '1p' "$AUTH_FILE")
PASSWORD=$(sed -n '2p' "$AUTH_FILE")

deny() {
    echo "[auth-verify] DENIED for '${USERNAME}': $*" >&2
    exit 1
}

allow() {
    echo "[auth-verify] ALLOWED '${USERNAME}'" >&2
    exit 0
}

# ── Validate username matches cert CN ─────────────────────────────────────────
if [[ "$USERNAME" != "$common_name" ]]; then
    deny "username '${USERNAME}' does not match cert CN '${common_name}'"
fi

# ── TOTP verification ─────────────────────────────────────────────────────────
SECRET_FILE="/data/users/${USERNAME}/totp.secret"

if [[ ! -f "$SECRET_FILE" ]]; then
    if [[ "$REQUIRE_MFA" == "true" ]]; then
        deny "no TOTP secret found and REQUIRE_MFA=true"
    else
        # No MFA configured for this user and not required globally — allow
        allow
    fi
fi

SECRET=$(cat "$SECRET_FILE")

# Python pyotp: verify with a ±1 window (90-second grace for clock skew)
# Use 'if' so set -e doesn't fire on a failed TOTP check before we can log it.
if python3 - "$SECRET" "$PASSWORD" << 'PYEOF'
import sys, pyotp
totp = pyotp.TOTP(sys.argv[1])
sys.exit(0 if totp.verify(sys.argv[2], valid_window=1) else 1)
PYEOF
then
    allow
else
    deny "invalid TOTP code"
fi
