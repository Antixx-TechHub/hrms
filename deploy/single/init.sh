#!/usr/bin/env bash
set -euo pipefail

# -------- Fixed credentials (Railway public proxies, as provided) --------
SITE_NAME="hrms.localhost"
ADMIN_PASSWORD="admin_001013"

DB_HOST="trolley.proxy.rlwy.net"
DB_PORT="51999"
DB_ROOT_USER="root"
DB_ROOT_PASSWORD="CYI-Vi3_B_4Ndf7C1e3.usRHOuU_zkRU"
DB_USER="railway"
DB_PASSWORD="hfxKFQNoMagViYHTotVOpsbiQ4Rzg_l-"
DB_NAME="new_ath_hrms"

REDIS_CACHE_URL="redis://default:TUwUwNxPhXtoaysMLvnyssapQWtRbGpz@nozomi.proxy.rlwy.net:46645"
REDIS_QUEUE_URL="redis://default:TUwUwNxPhXtoaysMLvnyssapQWtRbGpz@nozomi.proxy.rlwy.net:46645"
REDIS_SOCKETIO_URL="redis://default:TUwUwNxPhXtoaysMLvnyssapQWtRbGpz@nozomi.proxy.rlwy.net:46645"

# Your Railway domain
RAILWAY_DOMAIN="overflowing-harmony-production.up.railway.app"

# -------- helpers --------
wait_tcp() { local h="$1" p="$2" l="${3:-$h:$p}"; echo "Waiting for $l..."; until bash -lc ">/dev/tcp/$h/$p" >/dev/null 2>&1; do sleep 2; done; echo "$l is up."; }

# -------- wait for external services --------
wait_tcp "$DB_HOST" "$DB_PORT" "MariaDB $DB_HOST:$DB_PORT"

# -------- bench setup --------
if [ -d "/home/frappe/frappe-bench/apps/frappe" ]; then
  cd /home/frappe/frappe-bench
else
  cd /home/frappe
  bench init --skip-redis-config-generation --frappe-branch version-15 frappe-bench
  cd /home/frappe/frappe-bench

  bench get-app --branch version-15 https://github.com/frappe/erpnext
  bench get-app --branch version-15 https://github.com/frappe/hrms

  # Point to external services
  bench set-mariadb-host "$DB_HOST"
  bench set-config -g db_port "$DB_PORT"
  bench set-redis-cache-host    "$REDIS_CACHE_URL"
  bench set-redis-queue-host    "$REDIS_QUEUE_URL"
  bench set-redis-socketio-host "$REDIS_SOCKETIO_URL"

  # Ensure DB exists and user has rights
  mysql --protocol=TCP -h "$DB_HOST" -P "$DB_PORT" -u "$DB_ROOT_USER" -p"$DB_ROOT_PASSWORD" <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` DEFAULT CHARACTER SET utf8mb4;
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';
FLUSH PRIVILEGES;
SQL

  # Create site bound to that DB
  bench new-site "$SITE_NAME" \
    --force \
    --admin-password "$ADMIN_PASSWORD" \
    --db-type mariadb \
    --db-host "$DB_HOST" \
    --db-port "$DB_PORT" \
    --db-name "$DB_NAME" \
    --db-username "$DB_USER" \
    --db-password "$DB_PASSWORD" \
    --no-mariadb-socket \
    --mariadb-root-username "$DB_ROOT_USER" \
    --mariadb-root-password "$DB_ROOT_PASSWORD"

  bench --site "$SITE_NAME" install-app erpnext hrms
  bench --site "$SITE_NAME" enable-scheduler
fi

bench use "$SITE_NAME"

# Bind the Railway domain to this site to avoid 404
bench --site "$SITE_NAME" set-config host_name "$RAILWAY_DOMAIN"
ln -sf "sites/${SITE_NAME}" "sites/${RAILWAY_DOMAIN}"

# Make SITE_NAME visible to Procfile command
export SITE_NAME

# Procfile: force serve this site on Railway's $PORT
cat > Procfile <<'P'
web: bash -lc 'bench --site ${SITE_NAME} serve --port ${PORT} --noreload --nothreading'
schedule: bench schedule
worker-default: bench worker --queue default
worker-short: bench worker --queue short
worker-long: bench worker --queue long
socketio: node apps/frappe/socketio.js
P

exec bench start
