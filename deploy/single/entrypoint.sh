#!/usr/bin/env bash
set -euo pipefail

# -------- inputs --------
SITE_NAME="${SITE_NAME:-site1.local}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:?set ADMIN_PASSWORD}"

# Railway MariaDB (internal first, then public)
DB_HOST="${DB_HOST:-${MARIADB_HOST:-${MARIADB_PUBLIC_HOST:?set MARIADB_PUBLIC_HOST}}}"
DB_PORT="${DB_PORT:-${MARIADB_PORT:-${MARIADB_PUBLIC_PORT:?set MARIADB_PUBLIC_PORT}}}"
DB_USER="${DB_USER:-${MARIADB_USER:?set MARIADB_USER}}"
DB_PASSWORD="${DB_PASSWORD:-${MARIADB_PASSWORD:?set MARIADB_PASSWORD}}"
DB_NAME="${DB_NAME:-${MARIADB_DATABASE:?set MARIADB_DATABASE}}"

# Optional Redis (use your service vars or leave empty)
REDIS_CACHE="${REDIS_CACHE:-}"
REDIS_QUEUE="${REDIS_QUEUE:-}"
REDIS_SOCKETIO="${REDIS_SOCKETIO:-}"

PORT="${PORT:-8000}"

# -------- paths --------
BENCH=/home/frappe/frappe-bench
SITES="$BENCH/sites"
APPS="$BENCH/apps"
SITE_PATH="$SITES/$SITE_NAME"
VENV="$BENCH/env"
PIP="$VENV/bin/pip"
GUNICORN="$VENV/bin/gunicorn"

cd "$BENCH"

# 0) ensure minimal bench context
mkdir -p "$SITES"
[ -f ./apps.txt ] || : > ./apps.txt
[ -f "$SITES/apps.txt" ] || cp ./apps.txt "$SITES/apps.txt"
[ -f "$SITES/common_site_config.json" ] || echo '{}' > "$SITES/common_site_config.json"

# 1) write redis endpoints into common_site_config.json (no jq)
if [ -n "$REDIS_CACHE" ] || [ -n "$REDIS_QUEUE" ] || [ -n "$REDIS_SOCKETIO" ]; then
  {
    echo "{"
    c=0
    if [ -n "$REDIS_CACHE" ]; then   echo "  \"redis_cache\": \"${REDIS_CACHE}\""; c=1; fi
    if [ -n "$REDIS_QUEUE" ]; then   [ $c -eq 1 ] && echo ","; echo "  \"redis_queue\": \"${REDIS_QUEUE}\""; c=1; fi
    if [ -n "$REDIS_SOCKETIO" ]; then [ $c -eq 1 ] && echo ","; echo "  \"redis_socketio\": \"${REDIS_SOCKETIO}\""; fi
    echo "}"
  } > "$SITES/common_site_config.json"
fi

# 2) fetch apps via git (avoid bench get-app)
[ -d "$APPS/erpnext" ] || git clone --depth 1 -b version-15 https://github.com/frappe/erpnext "$APPS/erpnext"
[ -d "$APPS/hrms" ]    || git clone --depth 1 -b version-15 https://github.com/frappe/hrms    "$APPS/hrms"

# 3) install python deps if present
[ -f "$APPS/erpnext/requirements.txt" ] && "$PIP" install -q -r "$APPS/erpnext/requirements.txt" || true
[ -f "$APPS/hrms/requirements.txt" ]    && "$PIP" install -q -r "$APPS/hrms/requirements.txt"    || true

# 4) create site (use managed DB user + existing DB name)
#    NOTE: we pass --db-name to use the precreated DB and the managed user creds.
if [ ! -f "$SITE_PATH/site_config.json" ]; then
  bench new-site "$SITE_NAME" \
    --db-name "$DB_NAME" \
    --db-host "$DB_HOST" --db-port "$DB_PORT" \
    --db-root-username "$DB_USER" \
    --mariadb-root-password "$DB_PASSWORD" \
    --no-mariadb-socket \
    --admin-password "$ADMIN_PASSWORD"

  bench --site "$SITE_NAME" install-app erpnext
  bench --site "$SITE_NAME" install-app hrms
fi

# 5) serve via gunicorn (single-container)
export FRAPPE_SITE="$SITE_NAME"
exec "$GUNICORN" \
  -b 0.0.0.0:"$PORT" -w 2 -k gevent --timeout 120 \
  --chdir /home/frappe/frappe-bench/apps/frappe \
  frappe.app:application
