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

RAILWAY_DOMAIN="overflowing-harmony-production.up.railway.app"

BENCH_DIR="/home/frappe/frappe-bench"
SITES_DIR="$BENCH_DIR/sites"

as_frappe() {
  cd "$BENCH_DIR"

  # point bench to external services
  bench set-mariadb-host "$DB_HOST"
  bench set-config -g db_port "$DB_PORT"
  bench set-redis-cache-host    "$REDIS_CACHE_URL"
  bench set-redis-queue-host    "$REDIS_QUEUE_URL"
  bench set-redis-socketio-host "$REDIS_SOCKETIO_URL"

  # ensure site exists
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

  bench use "$SITE_NAME"
  bench --site "$SITE_NAME" set-config host_name "$RAILWAY_DOMAIN"
  ln -sfn "sites/${SITE_NAME}" "sites/${RAILWAY_DOMAIN}"

  export SITE_NAME
  cat > Procfile <<'P'
web: bash -lc 'bench --site ${SITE_NAME} serve --port ${PORT} --noreload --nothreading'
schedule: bench schedule
worker-default: bench worker --queue default
worker-short: bench worker --queue short
worker-long: bench worker --queue long
socketio: node apps/frappe/socketio.js
P

  exec bench start
}

# ---- root phase: fix volume perms, wait for DB, then drop to 'frappe' ----
if [[ "$(id -u)" -eq 0 ]]; then
  # ensure mount exists and is owned by frappe
  mkdir -p "$SITES_DIR" "$SITES_DIR/assets" "$SITES_DIR/logs"
  chown -R frappe:frappe "$SITES_DIR"

  # quick sanity: allow bench to write common_site_config.json
  touch "$SITES_DIR/common_site_config.json" || true
  chown frappe:frappe "$SITES_DIR/common_site_config.json" || true

  # wait for DB port
  echo "Waiting for MariaDB $DB_HOST:$DB_PORT..."
  until bash -lc ">/dev/tcp/$DB_HOST/$DB_PORT" >/dev/null 2>&1; do sleep 2; done
  echo "MariaDB $DB_HOST:$DB_PORT is up."

  # exec as 'frappe'
  exec su -s /bin/bash -c "/home/frappe/init.sh run" frappe
fi

# ---- frappe phase ----
if [[ "${1:-}" == "run" ]]; then
  as_frappe
fi

echo "Unexpected invocation"
exit 1
