#!/usr/bin/env bash
set -euo pipefail

# -------- Fixed credentials --------
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
COMMON_CFG="$SITES_DIR/common_site_config.json"

# ---- root phase ----
if [[ "$(id -u)" -eq 0 && "${1:-}" != "run" ]]; then
  # ensure mount and ownership
  mkdir -p "$SITES_DIR" "$SITES_DIR/assets" "$SITES_DIR/logs"
  chown -R frappe:frappe "$SITES_DIR"

  # seed valid JSON to avoid JSONDecodeError on empty file
  if [[ ! -f "$COMMON_CFG" || ! -s "$COMMON_CFG" ]]; then
    install -o frappe -g frappe -m 0644 /dev/null "$COMMON_CFG"
    printf '{}' > "$COMMON_CFG"
    chown frappe:frappe "$COMMON_CFG"
  fi

  # wait DB
  echo "Waiting for MariaDB $DB_HOST:$DB_PORT..."
  until bash -lc ">/dev/tcp/$DB_HOST/$DB_PORT" >/dev/null 2>&1; do sleep 2; done
  echo "MariaDB $DB_HOST:$DB_PORT is up."

  export PATH="/usr/local/bin:/usr/bin:/bin:/home/frappe/.local/bin"
  exec su -s /bin/bash -c "/home/frappe/init.sh run" frappe
fi

# ---- frappe phase ----
export PATH="/usr/local/bin:/usr/bin:/bin:/home/frappe/.local/bin"
cd "$BENCH_DIR"

# locate bench
BENCH_BIN="$(command -v bench || true)"
if [[ -z "${BENCH_BIN}" || ! -x "${BENCH_BIN}" ]]; then
  for c in /home/frappe/.local/bin/bench /usr/local/bin/bench /usr/bin/bench; do
    [[ -x "$c" ]] && BENCH_BIN="$c" && break
  done
fi
[[ -x "${BENCH_BIN:-}" ]] || { echo "bench not found"; exit 127; }

# if common_site_config.json somehow empty, reseed
if [[ ! -s "$COMMON_CFG" ]]; then printf '{}' > "$COMMON_CFG"; fi

# external services
"$BENCH_BIN" set-mariadb-host "$DB_HOST"
"$BENCH_BIN" set-config -g db_port "$DB_PORT"
"$BENCH_BIN" set-redis-cache-host    "$REDIS_CACHE_URL"
"$BENCH_BIN" set-redis-queue-host    "$REDIS_QUEUE_URL"
"$BENCH_BIN" set-redis-socketio-host "$REDIS_SOCKETIO_URL"

# ensure site exists
if [[ ! -d "sites/${SITE_NAME}" ]]; then
  echo "Creating site ${SITE_NAME}..."
  mysql --protocol=TCP -h "$DB_HOST" -P "$DB_PORT" -u "$DB_ROOT_USER" -p"$DB_ROOT_PASSWORD" <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` DEFAULT CHARACTER SET utf8mb4;
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';
FLUSH PRIVILEGES;
SQL

  "$BENCH_BIN" new-site "$SITE_NAME" \
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

  "$BENCH_BIN" --site "$SITE_NAME" install-app erpnext hrms
  "$BENCH_BIN" --site "$SITE_NAME" enable-scheduler
fi

# bind host and force site on $PORT
"$BENCH_BIN" use "$SITE_NAME"
"$BENCH_BIN" --site "$SITE_NAME" set-config host_name "$RAILWAY_DOMAIN"
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

exec "$BENCH_BIN" start
