#!/usr/bin/env bash
set -euo pipefail

# required env
SITE_NAME="${SITE_NAME:-site1.local}"
DB_HOST="${DB_HOST:?set DB_HOST}"          # copy EXACTLY from Railway MariaDB card
DB_PORT="${DB_PORT:?set DB_PORT}"
DB_ROOT_USER="${DB_ROOT_USER:-root}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:?set DB_ROOT_PASSWORD}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:?set ADMIN_PASSWORD}"
PORT="${PORT:-8000}"                       # Railway routes to this

BENCH=/home/frappe/frappe-bench
SITES="$BENCH/sites"
APPS="$BENCH/apps"
SITE_PATH="$SITES/$SITE_NAME"
PIP="$BENCH/env/bin/pip"

cd "$BENCH"

# 1) minimal bench context so CLI doesn’t crash
mkdir -p "$SITES"
[ -f ./apps.txt ] || : > ./apps.txt
[ -f "$SITES/apps.txt" ] || cp ./apps.txt "$SITES/apps.txt"
[ -f "$SITES/common_site_config.json" ] || echo '{}' > "$SITES/common_site_config.json"

# 2) set redis endpoints directly (no jq)
if [ -n "${REDIS_CACHE:-}" ] || [ -n "${REDIS_QUEUE:-}" ] || [ -n "${REDIS_SOCKETIO:-}" ]; then
  {
    echo "{"
    first=1
    if [ -n "${REDIS_CACHE:-}" ]; then echo "  \"redis_cache\": \"${REDIS_CACHE}\""; first=0; fi
    if [ -n "${REDIS_QUEUE:-}" ]; then [ $first -eq 0 ] && echo ","; echo "  \"redis_queue\": \"${REDIS_QUEUE}\""; first=0; fi
    if [ -n "${REDIS_SOCKETIO:-}" ]; then [ $first -eq 0 ] && echo ","; echo "  \"redis_socketio\": \"${REDIS_SOCKETIO}\""; fi
    echo "}"
  } > "$SITES/common_site_config.json"
fi

# 3) fetch apps via git (avoid 'bench get-app')
[ -d "$APPS/erpnext" ] || git clone --depth 1 -b version-15 https://github.com/frappe/erpnext "$APPS/erpnext"
[ -d "$APPS/hrms" ]    || git clone --depth 1 -b version-15 https://github.com/frappe/hrms    "$APPS/hrms"

# 4) python deps (ignore if files missing)
[ -f "$APPS/erpnext/requirements.txt" ] && "$PIP" install -q -r "$APPS/erpnext/requirements.txt" || true
[ -f "$APPS/hrms/requirements.txt" ]    && "$PIP" install -q -r "$APPS/hrms/requirements.txt"    || true

# 5) create site and install apps once
if [ ! -f "$SITE_PATH/site_config.json" ]; then
  bench new-site "$SITE_NAME" \
    --mariadb-root-password "$DB_ROOT_PASSWORD" \
    --admin-password "$ADMIN_PASSWORD" \
    --db-host "$DB_HOST" --db-port "$DB_PORT" \
    --db-root-username "$DB_ROOT_USER"

  bench --site "$SITE_NAME" install-app erpnext
  bench --site "$SITE_NAME" install-app hrms
fi

# 6) serve HTTP with gunicorn (no nginx). Set FRAPPE_SITE so routing works.
export FRAPPE_SITE="$SITE_NAME"
exec /home/frappe/frappe-bench/env/bin/gunicorn \
  -b 0.0.0.0:"$PORT" -w 2 -k gevent --timeout 120 \
  --chdir /home/frappe/frappe-bench/apps/frappe \
  frappe.app:application
