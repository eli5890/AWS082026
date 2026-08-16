#!/bin/bash
set -e
exec >/tmp/deploy.log 2>&1
echo "DEPLOY_START $(date)"

# Extract code
sudo mkdir -p /opt/sis
sudo chown ubuntu:ubuntu /opt/sis
cd /opt/sis
tar xzf /tmp/sis.tar.gz

# Apply schema (idempotent — drop+recreate would lose data; only run if empty)
TABLES=$(sudo -u postgres psql -d sis -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'")
if [ "$TABLES" -lt 3 ]; then
  echo "Applying schema..."
  sudo -u postgres psql -d sis -f /opt/sis/db/schema.sql
fi

# .env
cat > /opt/sis/backend/.env <<'EOF'
NODE_ENV=production
PORT=3001
LOG_LEVEL=info
CORS_ORIGINS=*
DATABASE_URL=postgresql://sis:sis_local_only@127.0.0.1:5432/sis
JWT_SECRET=ec494c4ee71ad527f71b7a2df44bfa941c01ce3dae905814f2062d04df5a5d76
PUBLIC_QUOTE_SECRET=42c8479c9a26b586c6e742de513aac94b8b2661d71de10fd7fc18925a35962ba
SESSION_COOKIE_NAME=sis_session
BASE_URL=http://16.171.169.154
AWS_REGION=eu-north-1
S3_BUCKET=
TWILIO_ACCOUNT_SID=
TWILIO_AUTH_TOKEN=
TWILIO_SMS_FROM=
TWILIO_WHATSAPP_FROM=
SENDGRID_API_KEY=
SENDGRID_FROM_EMAIL=
OPENAI_API_KEY=
LINET_LOGIN_ID=
LINET_LOGIN_HASH=
LINET_COMPANY_ID=
ROBOFLOW_API_KEY=
CONVERTAPI_SECRET=
EOF
chmod 600 /opt/sis/backend/.env

# Install deps (skip Playwright browsers — can be installed later)
cd /opt/sis/backend
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci --omit=dev

# systemd service
sudo tee /etc/systemd/system/sis-backend.service >/dev/null <<'EOF'
[Unit]
Description=SIS backend
After=network.target postgresql.service
Wants=postgresql.service

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/opt/sis/backend
EnvironmentFile=/opt/sis/backend/.env
ExecStart=/usr/bin/node src/server.js
Restart=on-failure
RestartSec=5
StandardOutput=append:/var/log/sis-backend.log
StandardError=append:/var/log/sis-backend.log

[Install]
WantedBy=multi-user.target
EOF

sudo touch /var/log/sis-backend.log
sudo chown ubuntu:ubuntu /var/log/sis-backend.log
sudo systemctl daemon-reload
sudo systemctl enable --now sis-backend

sleep 3
curl -s http://127.0.0.1:3001/health || echo "HEALTH_FAIL"
echo "DEPLOY_DONE $(date)"
