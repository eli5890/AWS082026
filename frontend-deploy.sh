#!/bin/bash
set -e
exec >/tmp/fe.log 2>&1
echo START $(date)

sudo mkdir -p /var/www/sis
sudo tar -xzf /tmp/dist.tar.gz -C /var/www/sis
sudo chown -R www-data:www-data /var/www/sis

sudo tee /etc/nginx/sites-available/sis >/dev/null <<'NGX'
server {
  listen 80 default_server;
  listen [::]:80 default_server;
  server_name _;
  client_max_body_size 50M;

  root /var/www/sis;
  index index.html;

  # API + functions go to backend
  location /api/ {
    proxy_pass http://127.0.0.1:3001/api/;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_read_timeout 120s;
  }

  # Health check
  location = /health {
    proxy_pass http://127.0.0.1:3001/health;
  }

  # Static SPA — fall through to index.html
  location / {
    try_files $uri $uri/ /index.html;
  }
}
NGX

sudo nginx -t
sudo systemctl reload nginx
echo DONE $(date)
