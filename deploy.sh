#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# deploy.sh - deploy linuxMCP behind Nginx + Let's Encrypt with x-api-key auth
#
# Original project:
#   Author : Mahmoud Alkhatib
#   YouTube: https://www.youtube.com/@malkhatib
#   License: MIT - free to use, modify, and share. Keep this credit. :)
#
# KwSalem deployment profile:
#   - Nginx reverse proxy (works alongside existing n8n/OpenClaw hosts)
#   - Let's Encrypt via Certbot webroot
#   - x-api-key protection at Nginx
#   - MCP Python SDK pinned to v1 (<2) for FastMCP compatibility
#
# USAGE:
#   sudo ./deploy.sh <domain> [admin-email]
#   e.g. sudo ./deploy.sh mcp.example.com admin@example.com
#
# Optional: pre-set MCP_API_KEY to use your own secret. If omitted, this script
# generates a 64-hex-character key and stores it root-only.
# ============================================================================

SERVICE_USER="mcpagent"
APP_DIR="/opt/linux-mcp"
PORT="8080"
GRANT_SUDO="false"
WEBROOT="/var/www/acme"
NGINX_SITE="/etc/nginx/sites-available/mcp"
NGINX_LINK="/etc/nginx/sites-enabled/mcp"
CREDS_FILE="/root/linux-mcp-credentials.txt"

DOMAIN="${1:-}"
EMAIL="${2:-admin@${DOMAIN:-example.com}}"
API_KEY="${MCP_API_KEY:-}"

[[ -z "$DOMAIN" ]] && { echo "Usage: sudo ./deploy.sh <domain> [email]"; exit 1; }
[[ $EUID -ne 0 ]] && { echo "Please run with sudo / as root."; exit 1; }

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
[[ -f "$SRC_DIR/linux_mcp_server.py" ]] || {
  echo "linux_mcp_server.py not found next to this script."; exit 1;
}

if [[ -z "$API_KEY" ]]; then
  API_KEY="$(openssl rand -hex 32 2>/dev/null || true)"
fi
[[ -n "$API_KEY" ]] || { echo "Could not generate MCP API key."; exit 1; }

# Keep generated Nginx config safe because it contains the API key.
umask 077

echo ">> [1/9] Installing base packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y tmux python3 python3-venv python3-pip nginx certbot \
                   python3-certbot-nginx ufw curl openssl

echo ">> [2/9] Creating low-privilege service user '$SERVICE_USER'..."
id -u "$SERVICE_USER" >/dev/null 2>&1 || \
  useradd --create-home --shell /bin/bash "$SERVICE_USER"

if [[ "$GRANT_SUDO" == "true" ]]; then
  echo "   !! GRANT_SUDO=true -> giving $SERVICE_USER passwordless root."
  echo "$SERVICE_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$SERVICE_USER"
  chmod 440 "/etc/sudoers.d/$SERVICE_USER"
fi

echo ">> [3/9] Installing the MCP server..."
mkdir -p "$APP_DIR"
cp "$SRC_DIR/linux_mcp_server.py" "$APP_DIR/"
python3 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install --quiet --upgrade pip
# linux_mcp_server.py uses FastMCP from the MCP v1 SDK. MCP 2.x renamed this API.
"$APP_DIR/venv/bin/pip" install --quiet --upgrade 'mcp<2' uvicorn
touch "$APP_DIR/audit.log"
chown -R "$SERVICE_USER:$SERVICE_USER" "$APP_DIR"

echo ">> [4/9] Creating systemd service..."
NNP="true"; [[ "$GRANT_SUDO" == "true" ]] && NNP="false"
cat >/etc/systemd/system/linux-mcp.service <<EOF_SERVICE
[Unit]
Description=Linux VPS Agent (MCP server)
After=network.target

[Service]
Type=simple
User=$SERVICE_USER
WorkingDirectory=$APP_DIR
Environment=MCP_HOST=127.0.0.1
Environment=MCP_PORT=$PORT
Environment=MCP_ALLOWED_HOST=$DOMAIN
Environment=MCP_AUDIT_LOG=$APP_DIR/audit.log
ExecStart=$APP_DIR/venv/bin/python $APP_DIR/linux_mcp_server.py
Restart=on-failure
NoNewPrivileges=$NNP

[Install]
WantedBy=multi-user.target
EOF_SERVICE
systemctl daemon-reload
systemctl enable linux-mcp.service
systemctl restart linux-mcp.service

echo ">> [5/9] Verifying linuxMCP on 127.0.0.1:$PORT..."
for _ in $(seq 1 30); do
  if ss -lnt | grep -q "127.0.0.1:$PORT"; then break; fi
  sleep 1
done
ss -lnt | grep -q "127.0.0.1:$PORT" || {
  systemctl status linux-mcp --no-pager || true
  journalctl -u linux-mcp -n 50 --no-pager || true
  echo "linuxMCP did not start on port $PORT."; exit 1;
}

echo ">> [6/9] Preparing Nginx HTTP site for Let's Encrypt..."
mkdir -p "$WEBROOT/.well-known/acme-challenge"
cat >"$NGINX_SITE" <<EOF_HTTP
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root $WEBROOT;
    }

    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_cache off;
        proxy_request_buffering off;
    }
}
EOF_HTTP
chmod 600 "$NGINX_SITE"
ln -sfn "$NGINX_SITE" "$NGINX_LINK"
nginx -t
systemctl reload nginx

echo ">> [7/9] Issuing / reusing Let's Encrypt certificate..."
certbot certonly --webroot -w "$WEBROOT" \
  --non-interactive --agree-tos --no-eff-email \
  --email "$EMAIL" --keep-until-expiring -d "$DOMAIN"

echo ">> [8/9] Enabling HTTPS + x-api-key protection..."
cat >"$NGINX_SITE" <<EOF_HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root $WEBROOT;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer" always;

    location /mcp {
        if (\$http_x_api_key != "$API_KEY") {
            return 401;
        }

        proxy_pass http://127.0.0.1:$PORT/mcp;
        proxy_http_version 1.1;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_cache off;
        proxy_request_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
EOF_HTTPS
chmod 600 "$NGINX_SITE"
nginx -t
systemctl reload nginx

echo ">> [9/9] Firewall + credentials..."
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

cat >"$CREDS_FILE" <<EOF_CREDS
linuxMCP endpoint: https://$DOMAIN/mcp
Claude authentication: No sign-in
Request header name: x-api-key
Request header value: $API_KEY
EOF_CREDS
chmod 600 "$CREDS_FILE"

HTTP_CODE="$(curl -sk -o /dev/null -w '%{http_code}' "https://$DOMAIN/mcp" || true)"
if [[ "$HTTP_CODE" != "401" ]]; then
  echo "WARNING: expected unauthenticated /mcp to return 401, got: ${HTTP_CODE:-none}"
fi

echo "--------------------------------------------------------------"
echo " MCP endpoint : https://$DOMAIN/mcp"
echo " Claude auth  : No sign-in"
echo " Header name  : x-api-key"
echo " Header value : saved in $CREDS_FILE (root-only)"
echo " Show secret  : sudo cat $CREDS_FILE"
echo " Watch live   : sudo -u $SERVICE_USER tmux attach -t claude"
echo " Audit log    : tail -f $APP_DIR/audit.log"
echo " Sudo powers  : GRANT_SUDO=$GRANT_SUDO"
echo "--------------------------------------------------------------"
echo " Built by Mahmoud Alkhatib  |  https://www.youtube.com/@malkhatib"
echo " KwSalem profile: Nginx + Certbot + x-api-key hardening"
echo "--------------------------------------------------------------"
