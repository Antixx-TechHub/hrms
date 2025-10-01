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

# ---------- OPTIONAL ----------
PUBLIC_URL="${PUBLIC_URL:-}"   # e.g. https://<your-app>.up.railway.app
REDIS_CACHE="${REDIS_CACHE:-}"       # e.g. redis://:pwd@redis.railway.internal:6379/0
REDIS_QUEUE="${REDIS_QUEUE:-}"
REDIS_SOCKETIO="${REDIS_SOCKETIO:-}"

BENCH=/home/frappe/frappe-bench
APPS="$BENCH/apps"
SITES="$BENCH/sites"
SITE_PATH="$SITES/$SITE_NAME"
VENV="$BENCH/env"
GUNICORN="$VENV/bin/gunicorn"

cd "$BENCH"

# ---------- tiny helpers ----------
wait_for_db() {
  echo "Waiting for MariaDB ${DB_HOST}:${DB_PORT} ..."
  for i in {1..60}; do
    if mysqladmin --protocol=tcp -h "$DB_HOST" -P "$DB_PORT" -u"$DB_ROOT_USER" -p"$DB_ROOT_PASSWORD" ping >/dev/null 2>&1; then
      echo "MariaDB is reachable."
      return 0
    fi
    sleep 1
  done
  echo "ERROR: MariaDB not reachable after 60s."
  return 1
}

wait_for_redis() {
  local url="$1" label="$2"
  # Expect formats redis://host:port/db or redis://:pwd@host:port/db
  local host port
  host="$(python - <<'PY' "$url"
import os,sys,urllib.parse
u=urllib.parse.urlparse(os.environ["url"])
print(u.hostname or "")
PY
)"
  port="$(python - <<'PY' "$url"
import os,sys,urllib.parse
u=urllib.parse.urlparse(os.environ["url"])
print(u.port or 6379)
PY
)"
  echo "Waiting for ${label} ${host}:${port} ..."
  for i in {1..60}; do
    if (echo PING | timeout 1 bash -c "cat < /dev/tcp/${host}/${port}" >/dev/null 2>&1); then
      echo "${label} is reachable."
      return 0
    fi
    sleep 1
  done
  echo "WARN: ${label} not reachable after 60s; continuing."
  return 0
}

# ---------- bench context ----------
mkdir -p "$SITES"
[ -f ./apps.txt ] || : > ./apps.txt
[ -f "$SITES/apps.txt" ] || cp ./apps.txt "$SITES/apps.txt"
[ -f "$SITES/common_site_config.json" ] || echo '{}' > "$SITES/common_site_config.json"

# ---------- Redis: use Railway if provided; else start local ----------
if [[ -n "$REDIS_CACHE" && "$REDIS_CACHE" == redis://* ]]; then
  echo "Using provided Redis URLs from env."
else
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
fi

# ---------- persist common config (redis/proxy) ----------
python - <<PY
import json, os
p = "$SITES/common_site_config.json"
try:
  with open(p) as f: cfg=json.load(f)
except Exception: cfg={}
cfg.update({
  "redis_cache": os.environ.get("REDIS_CACHE",""),
  "redis_queue": os.environ.get("REDIS_QUEUE",""),
  "redis_socketio": os.environ.get("REDIS_SOCKETIO",""),
  "restart_supervisor_on_update": False,
  "auto_update": False
})
with open(p,"w") as f: json.dump(cfg, f, indent=2)
print("Wrote common_site_config.json")
PY

# ---------- Ensure apps exist (idempotent) ----------
[ -d "$APPS/erpnext" ] || git clone --depth 1 -b version-15 https://github.com/frappe/erpnext "$APPS/erpnext"
[ -d "$APPS/hrms" ]    || git clone --depth 1 -b version-15 https://github.com/frappe/hrms    "$APPS/hrms"

# ---------- WAIT for external services ----------
wait_for_db
wait_for_redis "$REDIS_CACHE" "redis_cache"
wait_for_redis "$REDIS_QUEUE" "redis_queue"
wait_for_redis "$REDIS_SOCKETIO" "redis_socketio"

# ---------- Site init / migrate ----------
if [ ! -f "$SITE_PATH/site_config.json" ]; then
  echo ">>> Initializing site $SITE_NAME with DB $DB_NAME"
  bench new-site "$SITE_NAME" \
    --db-name "$DB_NAME" \
    --db-host "$DB_HOST" --db-port "$DB_PORT" \
    --db-root-username "$DB_ROOT_USER" \
    --mariadb-root-password "$DB_ROOT_PASSWORD" \
    --no-mariadb-socket \
    --admin-password "$ADMIN_PASSWORD" \
    --install-app erpnext \
    --force || echo "new-site failed (may already exist); continuing."

  # HRMS can be sensitive to Redis being ready—retry once if it fails
  bench --site "$SITE_NAME" install-app hrms || {
    echo "HRMS install failed once; retrying after 5s..."
    sleep 5
    bench --site "$SITE_NAME" install-app hrms || echo "HRMS install skipped/failed; continuing."
  }
else
  echo ">>> Site exists. Running migrate + build."
  bench --site "$SITE_NAME" migrate || echo "migrate failed; will still serve."
fi

# ---------- Public URL (reverse proxy) ----------
if [[ -n "$PUBLIC_URL" ]]; then
  bench --site "$SITE_NAME" set-config host_name "$PUBLIC_URL" || true
  bench --site "$SITE_NAME" set-config host_name_map "[\"${PUBLIC_URL#https://}\"]" || true
  bench --site "$SITE_NAME" set-config use_x_forwarded_host true || true
  bench --site "$SITE_NAME" set-config use_x_forwarded_proto true || true
fi

# ---------- Build assets (don’t block boot) ----------
bench build || echo "bench build failed; serving anyway."

# ---------- Serve ----------
export FRAPPE_SITE="$SITE_NAME"
exec "$GUNICORN" \
  -b 0.0.0.0:"$PORT" -w 2 -k gevent --timeout 120 \
  --chdir "$APPS/frappe" \
  frappe.app:application
