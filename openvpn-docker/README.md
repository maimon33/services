# OpenVPN Docker

Self-hosted OpenVPN server on Ubuntu 24.04 with TOTP/MFA, dynamic hostname-based routing, persistent PKI, and a single GitHub Actions workflow for the full user lifecycle.

---

## Table of Contents

- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Configuration](#configuration)
  - [Environment Variables](#environment-variables)
  - [Routes (Dynamic Routing)](#routes-dynamic-routing)
- [User Management](#user-management)
  - [Manual (inside container)](#manual-inside-container)
  - [GitHub Actions Workflow](#github-actions-workflow)
- [MFA / TOTP](#mfa--totp)
- [Persistent Data](#persistent-data)
- [Updating the Server](#updating-the-server)
- [Client Setup](#client-setup)
- [GitHub Secrets Reference](#github-secrets-reference)
- [Directory Structure](#directory-structure)

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Docker host                                            │
│                                                         │
│  ┌──────────────────────────────────────────────────┐  │
│  │  openvpn container  (ubuntu:24.04)               │  │
│  │                                                  │  │
│  │  OpenVPN 2.x  ──►  tun0  ──►  iptables NAT      │  │
│  │  auth-verify.sh    (pyotp TOTP)                  │  │
│  │  client-connect.sh (dynamic routes from          │  │
│  │                     routes.conf on each connect) │  │
│  │                                                  │  │
│  │  /data  (named volume)                           │  │
│  │    pki/      ── EasyRSA CA, server + client certs│  │
│  │    users/    ── per-user TOTP secrets            │  │
│  │    clients/  ── generated .ovpn profiles        │  │
│  │    ccd/      ── per-client static config        │  │
│  │    logs/     ── openvpn, auth, connect logs     │  │
│  └──────────────────────────────────────────────────┘  │
│                           ▲                             │
│  config/routes.conf ──────┘  (bind-mounted, live)      │
└─────────────────────────────────────────────────────────┘
         ▲ UDP 1194
         │
    VPN clients  (cert + TOTP)
```

**Auth flow:** each client presents its certificate (primary identity) and enters its TOTP code as the password. The server validates both before allowing the tunnel.

---

## Prerequisites

- Docker + Docker Compose v2 on the host
- Host kernel with TUN support (`/dev/net/tun`)
- Public hostname or Elastic IP pointed at the host
- (Optional) AWS SES sending identity for TOTP email delivery

---

## Quick Start

```bash
# 1. Clone / copy this directory to your server
git clone <repo> && cd openvpn-docker

# 2. Create your .env
cp .env.example .env
# Edit at minimum: SERVER_NAME, INTERNAL_NETWORKS

# 3. Build and start
docker compose up -d --build

# The first start initialises the PKI automatically (takes ~60 s for DH params).
# Watch progress:
docker compose logs -f

# 4. Add your first user
docker exec openvpn vpn-add-user alice@example.com
# Prints a TOTP QR code and writes /data/clients/alice@example.com.ovpn

# 5. Copy the profile to the user
docker exec openvpn cat /data/clients/alice@example.com.ovpn > alice.ovpn
```

---

## Configuration

### Environment Variables

Copy `.env.example` to `.env` and adjust:

| Variable | Default | Description |
|---|---|---|
| `SERVER_NAME` | _(required)_ | Public hostname or IP clients connect to |
| `OPENVPN_PORT` | `1194` | UDP port to listen on |
| `OPENVPN_PROTO` | `udp` | `udp` or `tcp` |
| `CA_NAME` | `OpenVPN CA` | CA display name embedded in certificates |
| `EASYRSA_CERT_EXPIRE` | `825` | Client cert validity in days |
| `EASYRSA_CRL_DAYS` | `3650` | CRL validity in days |
| `VPN_NETWORK` | `10.8.0.0` | Tunnel network address |
| `VPN_SUBNET` | `255.255.255.0` | Tunnel netmask |
| `PUSH_DNS_1` / `PUSH_DNS_2` | `1.1.1.1` / `8.8.8.8` | DNS servers pushed to clients |
| `INTERNAL_NETWORKS` | _(empty)_ | Space-separated CIDRs the host can forward to (used in iptables) |
| `REQUIRE_MFA` | `true` | Deny connections without a configured TOTP secret |
| `TOTP_ISSUER` | `VPN` | Label shown in authenticator apps |

### Routes (Dynamic Routing)

Edit `config/routes.conf` on the host at any time. Changes are picked up on the **next client connect** — no container restart required.

```
# config/routes.conf

# Static CIDR ranges
10.0.0.0/8
192.168.1.0/24

# Single hosts
10.0.5.42

# Hostnames — resolved to A records at connect time
api.internal.example.com
db-primary.prod.internal
```

Supported entries:

| Format | Behaviour |
|---|---|
| `10.0.0.0/8` | Pushed as a CIDR route |
| `192.168.1.50` | Pushed as a /32 host route |
| `api.internal.example.com` | Resolved via `dig` at connect time; each A record pushed as a /32 |

> **Tip:** For services that change IP frequently, use the hostname form. The client always gets current IPs without any server changes.

---

## User Management

### Manual (inside container)

```bash
# Add a user (creates cert, TOTP secret, .ovpn profile)
docker exec openvpn vpn-add-user alice@example.com

# List all users with cert status and MFA indicator
docker exec openvpn vpn-list-users

# Revoke a user (cert added to CRL, OpenVPN reloaded immediately)
docker exec openvpn vpn-revoke-user alice@example.com

# Regenerate TOTP secret for a user (e.g. they lost their phone)
docker exec openvpn vpn-setup-totp alice@example.com

# Re-download a profile (e.g. user lost their .ovpn)
docker exec openvpn cat /data/clients/alice@example.com.ovpn > alice.ovpn
```

### GitHub Actions Workflow

**`vpn-manage.yml`** — one workflow, all actions.

Go to **Actions → VPN — User Management → Run workflow** and choose:

| Action | What it does |
|---|---|
| `add-user` | Creates cert + TOTP. Uploads `.ovpn` as 1-day artifact. Sends TOTP setup email via SES. Shows secret in job summary. |
| `revoke-user` | Revokes cert, regenerates CRL, reloads OpenVPN. |
| `regen-totp` | Generates a new TOTP secret. Emails it via SES. Shows in job summary. |
| `get-profile` | Re-downloads the existing `.ovpn` as a 1-day artifact. |
| `list-users` | Prints the user table to the job summary. |

The **username** field accepts an email address (used as both the cert CN and the SES delivery address).

> **Profile security:** `.ovpn` artifacts auto-expire after 24 hours. Download promptly and deliver to the user over a secure channel. Do not share the artifact URL.

---

## MFA / TOTP

The server uses [pyotp](https://github.com/pyauth/pyotp) to validate TOTP codes server-side. No separate auth server is required.

**How it works:**

1. `add-user` generates a random base32 secret stored at `/data/users/<username>/totp.secret`.
2. A QR code is printed to the terminal (and emailed if SES is configured).
3. On every VPN connection, OpenVPN calls `auth-verify.sh` which:
   - Checks that the provided username matches the connecting certificate's CN.
   - Validates the 6-digit TOTP code with a ±1 time window (90 s grace for clock skew).
4. A wrong code or missing secret (when `REQUIRE_MFA=true`) denies the connection.

**To set up MFA for a user:**
```bash
docker exec openvpn vpn-setup-totp alice@example.com
# Prints QR code and otpauth:// URI to the terminal
```

**Compatible apps:** Google Authenticator, Authy, 1Password, Bitwarden, any TOTP app.

**SAML / OAuth2 / OIDC (advanced):** OpenVPN CE does not have native SAML support. For SSO with Okta, Azure AD, or Google Workspace, consider [openvpn-auth-oauth2](https://github.com/jkroepke/openvpn-auth-oauth2) as a drop-in replacement for `auth-verify.sh`. Set `AUTH_MODE=oauth2` in `.env` and configure the `OAUTH2_*` variables.

---

## Persistent Data

All state lives in the `openvpn_data` Docker named volume, mounted at `/data`:

```
/data/
  pki/
    ca.crt              CA certificate
    issued/             Issued certificates (server + clients)
    private/            Private keys
    crl.pem             Certificate Revocation List
    dh.pem              Diffie-Hellman parameters
    tc.key              TLS-crypt key
  users/
    <username>/
      totp.secret       Base32 TOTP secret
  clients/
    <username>.ovpn     Generated client profiles
  ccd/
    <username>          Per-client static push directives (optional)
  server.conf           Rendered server configuration
  ipp.txt               IP persistence (client → IP mapping)
  logs/
    openvpn.log
    openvpn-status.log
    auth.log
    connect.log
```

To access the data directly from the host:

```bash
# Option A: docker cp
docker cp openvpn:/data/clients/alice@example.com.ovpn .

# Option B: switch to a bind mount in docker-compose.yml
# volumes:
#   openvpn_data:
#     driver_opts:
#       type: none
#       o: bind
#       device: /opt/openvpn/data
```

---

## Updating the Server

**Config-only change** (e.g. adding routes, changing DNS):
```bash
# Edit config/routes.conf — picked up on next client connect, no restart needed.

# For server.conf changes, restart OpenVPN:
docker compose restart openvpn
```

**Image rebuild** (e.g. OS packages, script changes):
```bash
docker compose build --no-cache
docker compose up -d
# The /data volume is preserved — PKI and all user data survive the rebuild.
```

**CRL renewal** (runs automatically on each container start):
```bash
docker exec openvpn bash -c \
  "EASYRSA_PKI=/data/pki EASYRSA_BATCH=1 /usr/share/easy-rsa/easyrsa gen-crl && chmod 644 /data/pki/crl.pem"
pkill -SIGUSR1 openvpn  # soft-reload inside the container
```

---

## Client Setup

1. Import the `.ovpn` profile into your OpenVPN client:
   - **macOS:** Tunnelblick or OpenVPN Connect
   - **Windows:** OpenVPN Connect or OpenVPN GUI
   - **Linux:** `openvpn --config alice.ovpn` or NetworkManager
   - **iOS / Android:** OpenVPN Connect

2. When prompted:
   - **Username:** your VPN username (same as the cert CN, e.g. `alice@example.com`)
   - **Password:** the current 6-digit code from your authenticator app

> The code changes every 30 seconds. If the connection is refused, wait for the next code and retry.

---

## GitHub Secrets Reference

Set these in **Settings → Secrets and variables → Actions**:

| Secret | Description |
|---|---|
| `VPN_HOST` | SSH hostname or IP of the Docker host |
| `VPN_SSH_USER` | SSH user on the host (needs `docker exec` permission) |
| `VPN_SSH_KEY` | SSH private key (PEM format) |
| `VPN_SSH_PORT` | SSH port (default: `22`) |
| `VPN_SERVER_NAME` | Public VPN hostname (same as `SERVER_NAME` in `.env`) |
| `VPN_CONTAINER_NAME` | Docker container name (default: `openvpn`) |
| `VPN_TOTP_ISSUER` | Issuer label in authenticator apps (default: `VPN`) |
| `SES_FROM_EMAIL` | Verified SES sender address |
| `AWS_ACCESS_KEY_ID` | AWS key with `ses:SendEmail` permission |
| `AWS_SECRET_ACCESS_KEY` | Corresponding AWS secret |
| `AWS_REGION` | SES region (default: `us-east-1`) |

To skip SES email delivery, leave `SES_FROM_EMAIL` unset — TOTP details will still appear in the job summary.

---

## Directory Structure

```
openvpn-docker/
├── Dockerfile                        Ubuntu 24.04 image
├── docker-compose.yml
├── .env.example                      All tunable variables
├── config/
│   ├── server.conf.template          envsubst-rendered on first start
│   ├── routes.conf                   Live-editable: CIDRs + hostnames to push
│   └── pam.d/openvpn                 PAM reference config (not active by default)
├── scripts/
│   ├── entrypoint.sh                 Container start: TUN, iptables, PKI init, OpenVPN
│   ├── init-pki.sh                   First-time EasyRSA + server.conf setup
│   ├── add-user.sh                   Cert + TOTP + .ovpn in one command
│   ├── revoke-user.sh                Revoke cert, regenerate CRL, reload OpenVPN
│   ├── list-users.sh                 Table of all users with status
│   ├── gen-client-config.sh          Builds inline .ovpn profile
│   ├── setup-totp.sh                 Generates TOTP secret + QR code
│   ├── auth-verify.sh                Called on every connect: cert CN + TOTP check
│   └── client-connect.sh             Resolves routes.conf and pushes to client
└── .github/workflows/
    └── vpn-manage.yml                Single workflow: add / revoke / regen-totp / get-profile / list
```
