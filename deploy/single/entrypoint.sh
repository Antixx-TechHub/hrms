#!/usr/bin/env bash
set -euo pipefail

# required
SITE_NAME="${SITE_NAME:-site1.local}"
DB_HOST="${DB_HOST:?set DB_HOST}"           # copy EXACT from Railway MariaDB card
DB_PORT="${DB_PORT:?set DB_PORT}"
DB_ROOT_USER="${DB_ROOT_USER:-root}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:?set DB_ROOT_PASSWORD}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:?set ADMIN_PASSWORD}"

BENCH=/home/frappe/frappe-bench
SITES="$BENCH/sites"
APPS="$BENCH/apps"
SITE_PATH="$SITES/$SITE_NAME"
PIP="$BENCH/env/bin/pip"

cd "$BENCH"

# 1) minimal bench context
mkdir -p "$SITES"
[ -f ./apps.txt ] || : > ./apps.txt
[ -f "$SITES/apps.txt" ] || cp ./apps.txt "$SITES/apps.txt"
[ -f "$SITES/common_site_config.json" ] || echo '{}' > "$SITES/common_site_config.json"

# 2) write redis endpoints if provided
if [ -n "${REDIS_CACHE:-}" ] || [ -n "${REDIS_QUEUE:-}" ] || [ -n "${REDIS_SOCKETIO:-}" ]; then
  # build json by hand to avoid jq
  tmp="$SITES/common_site_config.json.tmp"
  echo "{" > "$tmp"
  comma=""
  if [ -n "${REDIS_CACHE:-}" ];   then echo "  \"redis_cache\": \"${REDIS_CACHE}\""   >> "$tmp"; comma=","; fi
  if [ -n "${REDIS_QUEUE:-}" ];   then [ -n "$comma" ] && sed -i '$ s/$/,/' "$tmp"; echo "  \"redis_queue\": \"${REDIS_QUEUE}\""   >> "$tmp"; comma=","; fi
  if [ -n "${REDIS_SOCKETIO:-}" ];then [ -n "$comma" ] && sed -i '$ s/$/,/' "$tmp"; echo "  \"redis_socketio\": \"${REDIS_SOCKETIO}\"" >> "$tmp"; fi
  echo "}" >> "$tmp"
  mv "$tmp" "$SITES/common_site_config.json"
fi

# 3) fetch apps via git (no 'bench get-app' needed)
[ -d "$APPS/erpnext" ] || git clone --depth 1 -b version-15 https://github.com/frappe/erpnext "$APPS/erpnext"
[ -d "$APPS/hrms" ]    || git clone --depth 1 -b version-15 https://github.com/frappe/hrms    "$APPS/hrms"

# 4) python deps (ignore if files missing)
[ -f "$APPS/erpnext/requirements.txt" ] && "$PIP" install -q -r "$APPS/erpnext/requirements.txt" || true
[ -f "$APPS/hrms/requirements.txt" ]    && "$PIP" install -q -r "$APPS/hrms/requirements.txt"    || true

# 5) create site once, then install apps
if [ ! -f "$SITE_PATH/site_config.json" ]; then
  bench new-site "$SITE_NAME" \
    --mariadb-root-password "$DB_ROOT_PASSWORD" \
    --admin-password "$ADMIN_PASSWORD" \
    --db-host "$DB_HOST" --db-port "$DB_PORT" \
    --db-root-username "$DB_ROOT_USER"

  bench --site "$SITE_NAME" install-app erpnext
  bench --site "$SITE_NAME" install-app hrms
fi

# 6) start dev stack (Python on 8000)
exec bench start
