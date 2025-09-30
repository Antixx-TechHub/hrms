#!/usr/bin/env bash
set -euo pipefail

# -------- required env (you already have these) --------
: "${SITE_NAME:?SITE_NAME not set}"
: "${ADMIN_PASSWORD:?ADMIN_PASSWORD not set}"
: "${DB_HOST:?DB_HOST not set}"
: "${DB_PORT:?DB_PORT not set}"
: "${DB_ROOT_USER:?DB_ROOT_USER not set}"
: "${DB_ROOT_PASSWORD:?DB_ROOT_PASSWORD not set}"
: "${PORT:?PORT not set}"                   # Railway routes to this

BENCH=/home/frappe/frappe-bench
SITES="$BENCH/sites"
APPS="$BENCH/apps"
SITE_PATH="$SITES/$SITE_NAME"
VENV="$BENCH/env"
PIP="$VENV/bin/pip"
GUNICORN="$VENV/bin/gunicorn"

cd "$BENCH"

# -------- bench context --------
mkdir -p "$SITES"
[ -f ./apps.txt ] || : > ./apps.txt
[ -f "$SITES/apps.txt" ] || cp ./apps.txt "$SITES/apps.txt"
[ -f "$SITES/common_site_config.json" ] || echo '{}' > "$SITES/common_site_config.json"

# -------- write redis endpoints if provided --------
if [ -n "${REDIS_CACHE:-}" ] || [ -n "${REDIS_QUEUE:-}" ] || [ -n "${REDIS_SOCKETIO:-}" ]; then
  tmp="$SITES/common_site_config.json.tmp"
  echo "{" > "$tmp"
  sep=""
  if [ -n "${REDIS_CACHE:-}" ];    then printf '  "redis_cache": "%s"'    "$REDIS_CACHE"    >> "$tmp"; sep=","; fi
  if [ -n "${REDIS_QUEUE:-}" ];    then printf '%s\n  "redis_queue": "%s"'    "$sep" "$REDIS_QUEUE"    >> "$tmp"; sep=","; fi
  if [ -n "${REDIS_SOCKETIO:-}" ]; then printf '%s\n  "redis_socketio": "%s"' "$sep" "$REDIS_SOCKETIO" >> "$tmp"; fi
  echo -e "\n}" >> "$tmp"
  mv "$tmp" "$SITES/common_site_config.json"
fi

# -------- get apps (no `bench get-app`) --------
[ -d "$APPS/erpnext" ] || git clone --depth 1 -b version-15 https://github.com/frappe/erpnext "$APPS/erpnext"
[ -d "$APPS/hrms" ]    || git clone --depth 1 -b version-15 https://github.com/frappe/hrms    "$APPS/hrms"

# -------- python deps (best effort) --------
[ -f "$APPS/erpnext/requirements.txt" ] && "$PIP" install -q -r "$APPS/erpnext/requirements.txt" || true
[ -f "$APPS/hrms/requirements.txt" ]    && "$PIP" install -q -r "$APPS/hrms/requirements.txt"    || true

# -------- create site once --------
if [ ! -f "$SITE_PATH/site_config.json" ]; then
  bench new-site "$SITE_NAME" \
    --db-host "$DB_HOST" --db-port "$DB_PORT" \
    --db-root-username "$DB_ROOT_USER" \
    --mariadb-root-password "$DB_ROOT_PASSWORD" \
    --no-mariadb-socket \
    --admin-password "$ADMIN_PASSWORD"

  bench --site "$SITE_NAME" install-app erpnext
  bench --site "$SITE_NAME" install-app hrms

  # build assets (command name differs across images; ignore failures)
  bench build || true
fi

# -------- run HTTP (worker image) --------
export FRAPPE_SITE="$SITE_NAME"
exec "$GUNICORN" \
  -b 0.0.0.0:"$PORT" -w 2 -k gevent --timeout 120 \
  --chdir "$BENCH/apps/frappe" \
  frappe.app:application
