#!/bin/bash
# Generate a TOTP secret for a user and display the QR code.
# Usage: setup-totp.sh <username>
set -euo pipefail

USERNAME="${1:?Usage: setup-totp.sh <username>}"
: "${TOTP_ISSUER:=VPN}"

USER_DIR="/data/users/${USERNAME}"
SECRET_FILE="${USER_DIR}/totp.secret"

mkdir -p "$USER_DIR"

# Generate a random base32 secret (160-bit = 32 base32 chars)
SECRET=$(python3 -c "import pyotp; print(pyotp.random_base32())")
echo "$SECRET" > "$SECRET_FILE"
# Readable by nobody (OpenVPN drops to nobody to run auth-verify.sh)
chmod 640 "$SECRET_FILE"
chgrp nogroup "$SECRET_FILE"

OTP_URI="otpauth://totp/${TOTP_ISSUER}:${USERNAME}?secret=${SECRET}&issuer=${TOTP_ISSUER}&algorithm=SHA1&digits=6&period=30"

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  TOTP Setup for: ${USERNAME}"
echo "════════════════════════════════════════════════════════════"
echo ""
echo "  Secret (manual entry): ${SECRET}"
echo ""
echo "  Scan this QR code with Google Authenticator, Authy, or"
echo "  any TOTP-compatible app:"
echo ""
qrencode -t ANSIUTF8 -o - "$OTP_URI" 2>/dev/null || echo "  (qrencode not available — use secret above)"
echo ""
echo "  Or copy this URI into your authenticator app:"
echo "  ${OTP_URI}"
echo ""
echo "  When connecting to the VPN:"
echo "    Username: ${USERNAME}"
echo "    Password: <6-digit TOTP code from your authenticator app>"
echo "════════════════════════════════════════════════════════════"
echo ""
