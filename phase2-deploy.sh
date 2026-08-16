#!/bin/bash
set -e
exec >/tmp/phase2.log 2>&1
echo "=== Phase 2 deploy $(date) ==="

# 1. Extract code
sudo tar -xzf /tmp/be.tar.gz -C /opt/sis/backend
sudo chown -R ubuntu:ubuntu /opt/sis/backend/src /opt/sis/backend/migrations

# 2. Run new migration. The migration runner is idempotent and re-checksums
#    everything; it will skip 001 (already applied) and run 002.
cd /opt/sis/backend
node scripts/migrate.js

# 3. Backfill JWT: existing sessions have no `tid` claim. Revoke them so
#    users re-login and the new JWT carries tid + RLS works correctly.
sudo -u postgres psql -d sis -c "UPDATE sessions SET revoked_at = now() WHERE revoked_at IS NULL;"

# 4. Restart backend
sudo systemctl restart sis-backend
sleep 5
sudo systemctl is-active sis-backend

# 5. Health
curl -s http://127.0.0.1:3001/health

# 6. New frontend
sudo rm -rf /var/www/sis/*
sudo tar -xzf /tmp/dist.tar.gz -C /var/www/sis
sudo chown -R www-data:www-data /var/www/sis

# 7. Reload Caddy (restart because admin api disabled)
sudo systemctl restart caddy

# 8. Verify
echo === sanity ===
sudo -u postgres psql -d sis -c "SELECT id, slug, name, plan FROM tenants;"
sudo -u postgres psql -d sis -c "SELECT type, COUNT(*) FROM entities WHERE deleted_at IS NULL GROUP BY type ORDER BY 2 DESC LIMIT 5;"
sudo -u postgres psql -d sis -c "SELECT COUNT(*) AS internal_auth_rows, COUNT(DISTINCT tenant_id) AS tenants FROM internal_auth;"

curl -s http://127.0.0.1:3001/health
echo
echo "=== DONE $(date) ==="
