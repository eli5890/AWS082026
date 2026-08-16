#!/bin/bash
set -e
exec >/tmp/phase1.log 2>&1
echo "=== Phase 1 deploy $(date) ==="

# 1. Extract backend changes
sudo tar -xzf /tmp/be.tar.gz -C /opt/sis/backend
sudo chown -R ubuntu:ubuntu /opt/sis/backend/src /opt/sis/backend/scripts /opt/sis/backend/migrations /opt/sis/backend/package.json

# 2. Rotate secrets if they look like placeholders, ALWAYS in production
ENV_FILE=/opt/sis/backend/.env
sudo cp "$ENV_FILE" "${ENV_FILE}.bak.$(date +%s)" || true

gen() { openssl rand -base64 48 | tr -d '\n' | tr '+/' '-_'; }

upsert() {
  local key="$1"; local val="$2"
  if sudo grep -q "^${key}=" "$ENV_FILE"; then
    sudo sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
  else
    echo "${key}=${val}" | sudo tee -a "$ENV_FILE" >/dev/null
  fi
}

JWT_SECRET=$(gen)
PUBLIC_QUOTE_SECRET=$(gen)
SENTRY_DSN=$(sudo grep -E '^SENTRY_DSN=' "$ENV_FILE" | cut -d= -f2-)

upsert NODE_ENV production
upsert JWT_SECRET "$JWT_SECRET"
upsert PUBLIC_QUOTE_SECRET "$PUBLIC_QUOTE_SECRET"
upsert LOG_LEVEL info
# Lock CORS to the server's public IP / hostnames the user actually visits.
# Replace with real domains once attached.
upsert CORS_ORIGINS "http://16.171.169.154,https://16.171.169.154"

# 3. Install / upgrade deps (multer 2.x, file-type, @sentry/node, pg-migrate, pino-roll)
cd /opt/sis/backend
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install --omit=dev --no-audit --no-fund

# 4. Seed schema_migrations so the migration runner doesn't re-apply
sudo -u postgres psql -d sis -tc "CREATE TABLE IF NOT EXISTS schema_migrations (filename TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT now(), checksum TEXT NOT NULL);"
CHK=$(sha256sum /opt/sis/backend/migrations/001_initial_schema.sql | cut -d' ' -f1)
sudo -u postgres psql -d sis -c "INSERT INTO schema_migrations(filename, checksum) VALUES ('001_initial_schema.sql', '$CHK') ON CONFLICT (filename) DO UPDATE SET checksum = EXCLUDED.checksum;"
# Confirm via dry run
node scripts/migrate.js

# 5. Restart backend
sudo systemctl restart sis-backend
sleep 4
sudo systemctl is-active sis-backend
curl -s http://127.0.0.1:3001/health

# 6. Deploy new frontend
sudo rm -rf /var/www/sis/*
sudo tar -xzf /tmp/dist.tar.gz -C /var/www/sis
sudo chown -R www-data:www-data /var/www/sis

# 7. Caddy (replaces nginx)
if ! command -v caddy >/dev/null 2>&1; then
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/ubuntu any-version main" | sudo tee /etc/apt/sources.list.d/caddy-stable.list
  echo "deb-src [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/ubuntu any-version main" | sudo tee -a /etc/apt/sources.list.d/caddy-stable.list
  DEBIAN_FRONTEND=noninteractive sudo apt-get update -qq
  DEBIAN_FRONTEND=noninteractive sudo apt-get install -y caddy
fi

# Stop nginx, give port 80 to Caddy
sudo systemctl stop nginx || true
sudo systemctl disable nginx || true

sudo tee /etc/caddy/Caddyfile >/dev/null <<'CADDY'
{
    admin off
    email ops@example.com
    # Don't auto-issue certs for the bare IP; on real domains it will.
    auto_https disable_redirects
}

# Match anything (IP or hostname) — multi-tenant aware in backend.
:80, :443 {
    encode zstd gzip

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

    header {
        X-Content-Type-Options "nosniff"
        Referrer-Policy "strict-origin-when-cross-origin"
        X-Frame-Options "SAMEORIGIN"
    }

    # Caddy internal cert (self-signed) for :443 until a real domain is bound
    tls internal
}
CADDY

sudo systemctl enable --now caddy
sudo systemctl reload caddy 2>/dev/null || sudo systemctl restart caddy
sleep 3
sudo systemctl is-active caddy

# 8. Log rotation for the backend log file via logrotate
sudo tee /etc/logrotate.d/sis-backend >/dev/null <<'LR'
/var/log/sis-backend.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    sharedscripts
    postrotate
        systemctl reload sis-backend >/dev/null 2>&1 || true
    endscript
}
LR

# 9. Health checks
echo "--- HEALTH ---"
curl -ks https://127.0.0.1/health
echo
curl -s http://127.0.0.1/health
echo
echo "=== DONE $(date) ==="
