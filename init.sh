#!/usr/bin/env bash
set -euo pipefail

# -------- helpers --------
wait_tcp() {
  local host="$1" port="$2" label="${3:-$host:$port}"
  echo "Waiting for $label..."
  until bash -c ">/dev/tcp/$host/$port" >/dev/null 2>&1; do sleep 2; done
  echo "$label is up."
}
url_host() { local u="$1"; u="${u#*@}"; echo "${u%:*}"; }   # redis://user:pass@HOST:PORT -> HOST
url_port() { local u="$1"; echo "${u##*:}"; }               # redis://user:pass@HOST:PORT -> PORT

# -------- required env --------
: "${SITE_NAME:?missing}"; : "${ADMIN_PASSWORD:?missing}"
: "${DB_HOST:?missing}"; : "${DB_PORT:?missing}"
: "${DB_ROOT_USER:?missing}"; : "${DB_ROOT_PASSWORD:?missing}"
: "${REDIS_CACHE_URL:?missing}"; : "${REDIS_QUEUE_URL:?missing}"; : "${REDIS_SOCKETIO_URL:?missing}"

# -------- wait for external services --------
wait_tcp "$DB_HOST" "$DB_PORT" "MariaDB $DB_HOST:$DB_PORT"

RC_HOST="$(url_host "$REDIS_CACHE_URL")";    RC_PORT="$(url_port "$REDIS_CACHE_URL")"
RQ_HOST="$(url_host "$REDIS_QUEUE_URL")";    RQ_PORT="$(url_port "$REDIS_QUEUE_URL")"
RS_HOST="$(url_host "$REDIS_SOCKETIO_URL")"; RS_PORT="$(url_port "$REDIS_SOCKETIO_URL")"

wait_tcp "$RC_HOST" "$RC_PORT" "Redis cache"
wait_tcp "$RQ_HOST" "$RQ_PORT" "Redis queue"
wait_tcp "$RS_HOST" "$RS_PORT" "Redis socketio"

# -------- bench setup --------
if [ -d "/home/frappe/frappe-bench/apps/frappe" ]; then
  cd /home/frappe/frappe-bench
else
  cd /home/frappe
  bench init --skip-redis-config-generation --frappe-branch version-15 frappe-bench
  cd /home/frappe/frappe-bench

  bench get-app --branch version-15 https://github.com/frappe/erpnext
  bench get-app --branch version-15 https://github.com/frappe/hrms

  bench set-mariadb-host "$DB_HOST"
  bench set-redis-cache-host    "$REDIS_CACHE_URL"
  bench set-redis-queue-host    "$REDIS_QUEUE_URL"
  bench set-redis-socketio-host "$REDIS_SOCKETIO_URL"

  bench new-site "$SITE_NAME" \
    --force \
    --admin-password "$ADMIN_PASSWORD" \
    --db-type mariadb \
    --db-host "$DB_HOST" \
    --db-port "$DB_PORT" \
    --no-mariadb-socket \
    --mariadb-root-username "$DB_ROOT_USER" \
    --mariadb-root-password "$DB_ROOT_PASSWORD"

  bench --site "$SITE_NAME" install-app erpnext hrms
  bench --site "$SITE_NAME" set-config developer_mode 1
  bench --site "$SITE_NAME" enable-scheduler
  bench --site "$SITE_NAME" clear-cache
fi

bench use "$SITE_NAME"
exec bench start
