#!/usr/bin/env bash
set -euo pipefail

# -------- Fixed credentials (Railway public proxies) --------
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

cd /home/frappe/frappe-bench

# helpers
wait_tcp() {
  local h="$1" p="$2" l="${3:-$h:$p}"
  echo "Waiting for $l..."
  until bash -lc ">/dev/tcp/$h/$p" >/dev/null 2>&1; do sleep 2; done
  echo "$l is up."
}

# wait external deps
wait_tcp "$DB_HOST" "$DB_PORT" "MariaDB $DB_HOST:$DB_PORT"

# point bench to external services (idempotent)
bench set-mariadb-host "$DB_HOST"
bench set-config -g db_port "$DB_PORT"
bench set-redis-cache-host    "$REDIS_CACHE_URL"
bench set-redis-queue-host    "$REDIS_QUEUE_URL"
bench set-redis-socketio-host "$REDIS_SOCKETIO_URL"

# ALWAYS ensure the site exists
if [[ ! -d "sites/${SITE_NAME}" ]]; then
  echo "Creating site ${SITE_NAME}..."

  mysql --protocol=TCP -h "$DB_HOST" -P "$DB_PORT" -u "$DB_ROOT_USER" -p"$DB_ROOT_PASSWORD" <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` DEFAULT CHARACTER SET utf8mb4;
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';
FLUSH PRIVILEGES;
SQL

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

# bind host and force site on $PORT
bench use "$SITE_NAME"
bench --site "$SITE_NAME" set-config host_name "$RAILWAY_DOMAIN"
ln -sfn "sites/${SITE_NAME}" "sites/${RAILWAY_DOMAIN}"

export SITE_NAME

# Procfile: serve on Railway $PORT
cat > Procfile <<'P'
web: bash -lc 'bench --site ${SITE_NAME} serve --port ${PORT} --noreload --nothreading'
schedule: bench schedule
worker-default: bench worker --queue default
worker-short: bench worker --queue short
worker-long: bench worker --queue long
socketio: node apps/frappe/socketio.js
P

exec bench start
