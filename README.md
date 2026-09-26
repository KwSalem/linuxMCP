# Linux VPS Agent — control a Linux server with Claude (via MCP)

Turn a Linux VPS into a **Claude-connectable MCP server** backed by a persistent
`tmux` shell.

This fork keeps the original linuxMCP server design and adds a deployment profile
that matches an existing **Nginx + Let's Encrypt** VPS stack and protects the MCP
endpoint with an **`x-api-key` request header**.

> Original project by **Mahmoud Alkhatib** · https://www.youtube.com/@malkhatib  
> MIT License — original author credit preserved.

---

## What you get

- Persistent `tmux` shell Claude can drive:
  - `run_command`
  - `send_keys`
  - `capture_pane`
  - `list_sessions`
  - `new_session`
  - `kill_session`
- MCP Streamable HTTP endpoint at `/mcp`
- Low-privilege service user: `mcpagent`
- Command denylist for destructive commands
- Full audit log
- Nginx reverse proxy
- Let's Encrypt TLS via Certbot
- `x-api-key` protection at Nginx
- MCP Python SDK pinned to **v1 (`mcp<2`)** for FastMCP compatibility

---

## Why this fork differs from the original deployment

The original deployment script used **Caddy** and installed the latest `mcp`
package. Two practical changes were required for this VPS:

1. The server already uses **Nginx** for other services such as n8n and OpenClaw,
   so linuxMCP is deployed as another Nginx virtual host instead of replacing the
   existing reverse proxy.
2. `linux_mcp_server.py` imports `FastMCP` from `mcp.server.fastmcp`. MCP SDK
   2.x renamed that API, so the deployment pins:

```bash
mcp<2
```

The tested compatible version during deployment was MCP 1.x.

---

## Architecture

```text
Claude
  |
  | HTTPS
  | x-api-key: <secret>
  v
Nginx :443
  |
  | valid key
  v
127.0.0.1:8080
  |
  v
linuxMCP
  |
  v
mcpagent + tmux
```

This lets the same VPS continue serving other hosts independently, for example:

```text
n8n.example.com  -> 127.0.0.1:5678
claw.example.com -> 127.0.0.1:18789
mcp.example.com  -> 127.0.0.1:8080
```

---

## Requirements

- Ubuntu / Debian VPS
- Root or sudo access
- A domain/subdomain with an A record pointing to the VPS
- Ports 80 and 443 reachable
- Claude plan with Custom Connectors support
- Existing Nginx is supported

---

## Quick start

Clone this fork:

```bash
git clone https://github.com/KwSalem/linuxMCP.git
cd linuxMCP
```

Run:

```bash
sudo ./deploy.sh mcp.example.com admin@example.com
```

The script will:

1. Install required packages.
2. Create the `mcpagent` service account.
3. Create `/opt/linux-mcp/venv`.
4. Install `mcp<2` and `uvicorn`.
5. Create the `linux-mcp.service` systemd unit.
6. Verify the server is listening on `127.0.0.1:8080`.
7. Create an Nginx HTTP site for ACME validation.
8. Issue/reuse a Let's Encrypt certificate.
9. Enable HTTPS and require an `x-api-key` header.

The generated credential details are saved root-only at:

```text
/root/linux-mcp-credentials.txt
```

View them with:

```bash
sudo cat /root/linux-mcp-credentials.txt
```

---

## Claude Custom Connector configuration

Use:

```text
URL:
https://mcp.example.com/mcp

Authentication:
No sign-in

Request header:
x-api-key

Value:
<the generated secret>

Required:
Enabled
```

Do **not** use `Authorization: Bearer ...` for this deployment profile. Claude
may interpret that header as OAuth and switch the connector into a sign-in flow.

---

## Use your own API key

If you do not want the installer to generate a random key:

```bash
sudo MCP_API_KEY='your-long-random-secret' ./deploy.sh mcp.example.com admin@example.com
```

Use a strong random value. For example:

```bash
openssl rand -hex 32
```

Never commit the real key to GitHub.

---

## Verify the deployment

Service status:

```bash
sudo systemctl status linux-mcp --no-pager
```

Confirm the local listener:

```bash
ss -lntp | grep 8080
```

Unauthenticated public request should return **401**:

```bash
curl -i https://mcp.example.com/mcp
```

Authenticated MCP reachability test:

```bash
curl -i \
  -H "x-api-key: YOUR_SECRET" \
  -H "Accept: text/event-stream" \
  https://mcp.example.com/mcp
```

A response such as:

```text
400 Bad Request: Missing session ID
```

is expected for this simple curl test and proves the request passed Nginx
authentication and reached the MCP server.

---

## Test from Claude

After the connector is added, try:

```text
Use my-vps-mcp and run:
whoami
```

Expected service account:

```text
mcpagent
```

Then test session persistence:

```text
Use my-vps-mcp and run:
cd /tmp && pwd
```

In a later request:

```text
Use my-vps-mcp and run:
pwd
```

If it still returns `/tmp`, the persistent tmux session is working.

---

## Watch Claude work live

```bash
sudo -u mcpagent tmux attach -t claude
```

Audit log:

```bash
tail -f /opt/linux-mcp/audit.log
```

---

## Files installed on the VPS

```text
/opt/linux-mcp/linux_mcp_server.py
/opt/linux-mcp/venv/
/opt/linux-mcp/audit.log
/etc/systemd/system/linux-mcp.service
/etc/nginx/sites-available/mcp
/etc/nginx/sites-enabled/mcp
/root/linux-mcp-credentials.txt
```

---

## Security notes

linuxMCP exposes controlled shell capabilities. Treat the endpoint as privileged.

Recommended:

- Keep `GRANT_SUDO=false` unless root-level tasks are intentionally required.
- Keep the MCP process bound to `127.0.0.1`; expose it only through Nginx.
- Require `x-api-key` at the reverse proxy.
- Keep Claude tool permissions on **Needs approval** until you are comfortable
  with the command boundary.
- Rotate the API key if it is ever pasted into logs, screenshots, chat, shell
  history, or another untrusted location.
- Never commit credentials or generated Nginx files containing real keys.
- Review `/opt/linux-mcp/audit.log` regularly.

The built-in command denylist is a safety layer, not a complete sandbox.

---

## Troubleshooting

### `ModuleNotFoundError: No module named 'mcp.server.fastmcp'`

The installed SDK is MCP 2.x while this server uses the MCP 1.x FastMCP API.

Fix:

```bash
sudo systemctl stop linux-mcp
/opt/linux-mcp/venv/bin/pip install --upgrade --force-reinstall 'mcp<2'
sudo systemctl reset-failed linux-mcp
sudo systemctl restart linux-mcp
```

Verify:

```bash
/opt/linux-mcp/venv/bin/python -c "from mcp.server.fastmcp import FastMCP; print('FastMCP OK')"
```

### Claude opens another service instead of linuxMCP

Check that the MCP hostname has its own Nginx virtual host:

```bash
sudo nginx -T | grep -nE 'server_name|proxy_pass|listen'
```

The MCP host must proxy to:

```text
127.0.0.1:8080
```

### `421 Misdirected Request`

Make sure the systemd unit includes:

```text
Environment=MCP_ALLOWED_HOST=<your-mcp-domain>
```

Then:

```bash
sudo systemctl daemon-reload
sudo systemctl restart linux-mcp
```

### Public request returns `401 Unauthorized`

That is correct when the `x-api-key` header is missing or wrong.

### Simple authenticated curl returns `400 Missing session ID`

That is also expected. It confirms Nginx accepted the API key and the request
reached the MCP Streamable HTTP endpoint.

---

## Nginx example

See:

```text
nginx/mcp.conf.example
```

The example intentionally contains placeholders instead of real secrets.

---

## License / attribution

MIT License.

Original linuxMCP work and author attribution remain credited to Mahmoud Alkhatib.
This fork adds the Nginx, Certbot, MCP-v1 pinning, and API-key deployment profile.
