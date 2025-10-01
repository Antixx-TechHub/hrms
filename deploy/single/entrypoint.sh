#!/usr/bin/env bash
set -euo pipefail

# -------- Required env --------
: "${SITE_NAME:?SITE_NAME not set}"
: "${ADMIN_PASSWORD:?ADMIN_PASSWORD not set}"
: "${DB_HOST:?DB_HOST not set}"
: "${DB_PORT:?DB_PORT not set}"
: "${DB_ROOT_USER:?DB_ROOT_USER not set}"          # usually "root" on Railway MariaDB
: "${DB_ROOT_PASSWORD:?DB_ROOT_PASSWORD not set}"  # MariaDB root password from Railway
: "${DB_NAME:?DB_NAME not set}"                    # e.g. ATH_HRMS
: "${PORT:?PORT not set}"                          # Railway assigns this

# -------- Optional env --------
# PUBLIC_URL: e.g. https://your-app.up.railway.app
PUBLIC_URL="${PUBLIC_URL:-}"
REDIS_CACHE="${REDIS_CACHE:-}"
REDIS_QUEUE="${REDIS_QUEUE:-}"
REDIS_SOCKETIO="${REDIS_SOCKETIO:-}"

BENCH=/home/frappe/frappe-bench
APPS="$BENCH/apps"
SITES="$BENCH/sites"
SITE_PATH="$SITES/$SITE_NAME"
VENV="$BENCH/env"
PIP="$VENV/bin/pip"
GUNICORN="$VENV/bin/gunicorn"

cd "$BENCH"

# Ensure sites folder + minimal files
mkdir -p "$SITES"
[ -f ./apps.txt ] || : > ./apps.txt
[ -f "$SITES/apps.txt" ] || cp ./apps.txt "$SITES/apps.txt"
[ -f "$SITES/common_site_config.json" ] || echo '{}' > "$SITES/common_site_config.json"

# -------- Redis: use Railway if provided; else start local one --------
if [[ -n "$REDIS_CACHE" && "$REDIS_CACHE" == redis://* ]]; then
  echo "Using provided Redis URLs"
else
  echo "Starting local Redis..."
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

# Wire redis + proxy settings into common_site_config
python - <<PY
import json, os, sys
p = "$SITES/common_site_config.json"
cfg = {}
try:
    with open(p) as f: cfg = json.load(f)
except: pass
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

# -------- Ensure ERPNext + HRMS apps are present (cloned in image build, but idempotent) --------
[ -d "$APPS/erpnext" ] || git clone --depth 1 -b version-15 https://github.com/frappe/erpnext "$APPS/erpnext"
[ -d "$APPS/hrms" ]    || git clone --depth 1 -b version-15 https://github.com/frappe/hrms    "$APPS/hrms"

# -------- Install app Python deps (best effort) --------
[ -f "$APPS/erpnext/requirements.txt" ] && "$PIP" install -q -r "$APPS/erpnext/requirements.txt" || true
[ -f "$APPS/hrms/requirements.txt" ]    && "$PIP" install -q -r "$APPS/hrms/requirements.txt"    || true

# -------- New site or migrate --------
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
    --force

  # Install HRMS (optional; will no-op if already installed)
  bench --site "$SITE_NAME" install-app hrms || echo "HRMS install skipped/failed; continue."
else
  echo ">>> Site exists. Running migrate + build."
  # If DB is temporarily unavailable, don't crash the container—try once.
  bench --site "$SITE_NAME" migrate || echo "migrate failed once; will serve anyway."
fi

# -------- Set public URL / reverse-proxy settings (Railway) --------
if [[ -n "$PUBLIC_URL" ]]; then
  bench --site "$SITE_NAME" set-config host_name "$PUBLIC_URL"
  bench --site "$SITE_NAME" set-config host_name_map "[\"${PUBLIC_URL#https://}\"]"
  bench --site "$SITE_NAME" set-config use_x_forwarded_host true
  bench --site "$SITE_NAME" set-config use_x_forwarded_proto true
fi

# -------- Build assets if missing (won't fail deploy) --------
bench build || echo "bench build failed; serving anyway."

# -------- Serve --------
export FRAPPE_SITE="$SITE_NAME"
exec "$GUNICORN" \
  -b 0.0.0.0:"$PORT" -w 2 -k gevent --timeout 120 \
  --chdir "$APPS/frappe" \
  frappe.app:application
