#!/bin/bash
set -e
exec >/tmp/caddy.log 2>&1
echo "START $(date)"

# 1. Install Caddy (Cloudsmith repo)
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
DEBIAN_FRONTEND=noninteractive sudo apt-get update -qq
DEBIAN_FRONTEND=noninteractive sudo apt-get install -y caddy

# 2. Stop nginx and disable it
sudo systemctl stop nginx
sudo systemctl disable nginx || true

# 3. Caddyfile — automatic HTTPS via Let's Encrypt when a domain is set,
#    otherwise serves over HTTP + a self-signed internal cert on :443.
#    SaaS multi-host config: every host hits the same SPA/API; tenant
#    is resolved server-side by Host header.
HOST_FILE=/etc/caddy/sis-host
if [ ! -f "$HOST_FILE" ]; then
  echo ":80" | sudo tee "$HOST_FILE" >/dev/null
fi
HOST=$(cat "$HOST_FILE")

sudo tee /etc/caddy/Caddyfile >/dev/null <<CADDY
{
    # Disable admin API on a public port
    admin off
    # Email used for ACME notifications when a real domain is in use
    email ops@example.com
}

# Catch-all — works for the bare IP today and for any wildcard/custom
# domain you point at the server tomorrow. Caddy will automatically
# provision Let's Encrypt certs for real hostnames; the bare IP falls
# back to its self-signed internal CA.
$HOST {
    encode zstd gzip

    # Static SPA
    root * /var/www/sis
    @api  path /api/* /health
    handle @api {
        reverse_proxy 127.0.0.1:3001 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
            transport http { read_timeout 120s }
        }
    }
    handle {
        try_files {path} /index.html
        file_server
    }

    # Reasonable security defaults
    header {
        # Strict-Transport-Security only when we have a real cert
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "strict-origin-when-cross-origin"
        X-Frame-Options "SAMEORIGIN"
    }
}
CADDY

# 4. Enable & start
sudo systemctl enable --now caddy
sudo systemctl restart caddy
sleep 3
sudo systemctl is-active caddy
curl -ks https://127.0.0.1/health || curl -s http://127.0.0.1/health
echo "DONE $(date)"
