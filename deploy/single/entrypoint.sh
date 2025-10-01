#!/usr/bin/env bash
set -euo pipefail

# ---------- REQUIRED ENV ----------
: "${SITE_NAME:?SITE_NAME not set}"
: "${ADMIN_PASSWORD:?ADMIN_PASSWORD not set}"
: "${DB_HOST:?DB_HOST not set}"
: "${DB_PORT:?DB_PORT not set}"
: "${DB_ROOT_USER:?DB_ROOT_USER not set}"
: "${DB_ROOT_PASSWORD:?DB_ROOT_PASSWORD not set}"
: "${DB_NAME:?DB_NAME not set}"
: "${PORT:?PORT not set}"

PUBLIC_URL="${PUBLIC_URL:-}"

BENCH=/home/frappe/frappe-bench
APPS="$BENCH/apps"
SITES="$BENCH/sites"
SITE_PATH="$SITES/$SITE_NAME"
VENV="$BENCH/env"
GUNICORN="$VENV/bin/gunicorn"

cd "$BENCH"

# ---------- helpers ----------
wait_for_tcp() {
  local host=$1 port=$2 label=$3
  echo "Waiting for $label $host:$port ..."
  for i in {1..60}; do
    if nc -z "$host" "$port" >/dev/null 2>&1; then
      echo "$label is reachable."
      return 0
    fi
    sleep 1
  done
  echo "WARN: $label not reachable after 60s."
  return 1
}

wait_for_db() {
  wait_for_tcp "$DB_HOST" "$DB_PORT" "MariaDB"
}

# ---------- Redis: start local unless provided ----------
if [[ -z "${REDIS_CACHE:-}" ]]; then
  echo "Starting local Redis on 127.0.0.1:6379 ..."
  mkdir -p /home/frappe/redis
  if ! pgrep -x redis-server >/dev/null 2>&1; then
    redis-server --daemonize yes \
      --bind 127.0.0.1 --port 6379 \
      --save "" --appendonly no \
      --dir /home/frappe/redis \
      --pidfile /home/frappe/redis/redis.pid
  fi
  REDIS_CACHE="redis://127.0.0.1:6379/0"
  REDIS_QUEUE="redis://127.0.0.1:6379/1"
  REDIS_SOCKETIO="redis://127.0.0.1:6379/2"
else
  # if Railway gives you Redis, export all 3 roles to the same URL
  REDIS_QUEUE="$REDIS_CACHE"
  REDIS_SOCKETIO="$REDIS_CACHE"
fi

# ---------- common config ----------
mkdir -p "$SITES"
cat > "$SITES/common_site_config.json" <<EOF
{
  "redis_cache": "$REDIS_CACHE",
  "redis_queue": "$REDIS_QUEUE",
  "redis_socketio": "$REDIS_SOCKETIO",
  "restart_supervisor_on_update": false,
  "auto_update": false
}
EOF
echo "Wrote common_site_config.json"

# ---------- ensure apps ----------
[ -d "$APPS/erpnext" ] || git clone --depth 1 -b version-15 https://github.com/frappe/erpnext "$APPS/erpnext"
[ -d "$APPS/hrms" ]    || git clone --depth 1 -b version-15 https://github.com/frappe/hrms "$APPS/hrms"

# ---------- WAIT ----------
wait_for_db
wait_for_tcp "$(echo "$REDIS_CACHE" | sed -E 's#redis://([^:/]+).*#\1#')" \
             "$(echo "$REDIS_CACHE" | sed -E 's#.*:([0-9]+)/.*#\1#')" \
             "Redis"

# ---------- Site ----------
if [ ! -f "$SITE_PATH/site_config.json" ]; then
  echo ">>> Creating site $SITE_NAME"
  bench new-site "$SITE_NAME" \
    --db-name "$DB_NAME" \
    --db-host "$DB_HOST" --db-port "$DB_PORT" \
    --db-root-username "$DB_ROOT_USER" \
    --mariadb-root-password "$DB_ROOT_PASSWORD" \
    --no-mariadb-socket \
    --admin-password "$ADMIN_PASSWORD" \
    --install-app erpnext \
    --force || echo "new-site failed; continuing."

  bench --site "$SITE_NAME" install-app hrms || {
    echo "HRMS install failed once; retrying..."
    sleep 5
    bench --site "$SITE_NAME" install-app hrms || echo "HRMS install skipped."
  }
else
  echo ">>> Site exists. Running migrate + build."
  bench --site "$SITE_NAME" migrate || echo "migrate failed; will still serve."
fi

# ---------- host/proxy ----------
if [[ -n "$PUBLIC_URL" ]]; then
  bench --site "$SITE_NAME" set-config host_name "$PUBLIC_URL" || true
  bench --site "$SITE_NAME" set-config use_x_forwarded_host true || true
  bench --site "$SITE_NAME" set-config use_x_forwarded_proto true || true
fi

bench build || echo "bench build failed; serving anyway."

# ---------- Serve ----------
export FRAPPE_SITE="$SITE_NAME"
exec "$GUNICORN" \
  -b 0.0.0.0:"$PORT" -w 2 -k gevent --timeout 120 \
  --chdir "$APPS/frappe" \
  frappe.app:application
