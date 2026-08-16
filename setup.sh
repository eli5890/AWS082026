#!/bin/bash
set -e
exec >/tmp/setup.log 2>&1
echo "START $(date)"
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
DEBIAN_FRONTEND=noninteractive sudo apt-get install -y nodejs
node -v
npm -v
psql --version
sudo systemctl enable --now postgresql
sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='sis'" | grep -q 1 || sudo -u postgres psql -c "CREATE USER sis WITH PASSWORD 'sis_local_only';"
sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='sis'" | grep -q 1 || sudo -u postgres createdb -O sis sis
echo "DONE $(date)"
