#!/bin/bash
set -e
exec >/tmp/nginx.log 2>&1
echo START $(date)
DEBIAN_FRONTEND=noninteractive sudo apt-get install -y -qq nginx
sudo tee /etc/nginx/sites-available/sis >/dev/null <<'NGX'
server {
  listen 80 default_server;
  listen [::]:80 default_server;
  server_name _;
  client_max_body_size 50M;
  location / {
    proxy_pass http://127.0.0.1:3001;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_read_timeout 120s;
  }
}
NGX
sudo rm -f /etc/nginx/sites-enabled/default
sudo ln -sf /etc/nginx/sites-available/sis /etc/nginx/sites-enabled/sis
sudo nginx -t
sudo systemctl enable --now nginx
sudo systemctl reload nginx
curl -s http://127.0.0.1/health
echo NG_DONE $(date)
