#!/usr/bin/env bash
set -euo pipefail

# --- Required env (Railway App service) ---
: "${SITE_NAME:?SITE_NAME not set}"           # e.g. site1.local
: "${ADMIN_PASSWORD:?ADMIN_PASSWORD not set}" # ERPNext admin pwd
: "${DB_HOST:?DB_HOST not set}"               # mariadb.railway.internal
: "${DB_PORT:?DB_PORT not set}"               # 3306
: "${DB_ROOT_USER:?DB_ROOT_USER not set}"     # root
: "${DB_ROOT_PASSWORD:?DB_ROOT_PASSWORD not set}"
: "${DB_NAME:?DB_NAME not set}"               # e.g. ATH_HRMS
: "${PORT:?PORT not set}"
SKIP_MARIADB_SAFEGUARDS="${SKIP_MARIADB_SAFEGUARDS:-1}"

BENCH="/home/frappe/frappe-bench"
APPS="$BENCH/apps"
SITES="$BENCH/sites"
SITE_PATH="$SITES/$SITE_NAME"
VENV="$BENCH/env"
PIP="$VENV/bin/pip"
GUNICORN="$VENV/bin/gunicorn"

cd "$BENCH"

# --- Ensure base files ---
mkdir -p "$SITES"
[ -f "$SITES/common_site_config.json" ] || echo '{}' > "$SITES/common_site_config.json"

# --- Start local Redis (no config file, no root paths) ---
if ! pgrep -x redis-server >/dev/null 2>&1; then
  redis-server --daemonize yes --bind 127.0.0.1 --port 6379 --save "" --appendonly no --dir /home/frappe
fi

# --- Wire Redis URLs (schemed!) ---
cat > "$SITES/common_site_config.json" <<EOF
{
  "redis_cache":    "redis://127.0.0.1:6379/0",
  "redis_queue":    "redis://127.0.0.1:6379/1",
  "redis_socketio": "redis://127.0.0.1:6379/2"
}
EOF

# --- Fetch apps we need early (frappe already present in base image) ---
[ -d "$APPS/erpnext" ] || git clone --depth 1 -b version-15 https://github.com/frappe/erpnext "$APPS/erpnext"
# Clone HRMS now, but DO NOT register it yet in apps.txt (avoid import during new-site)
[ -d "$APPS/hrms" ] || git clone --depth 1 -b version-15 https://github.com/frappe/hrms "$APPS/hrms"

# --- Make sure Python can import apps even before bench massages paths ---
export PYTHONPATH="$APPS/frappe:$APPS/erpnext:$APPS/hrms:${PYTHONPATH:-}"

# --- Python deps for app repos (quietly) ---
[ -f "$APPS/erpnext/requirements.txt" ] && "$PIP" install -q -r "$APPS/erpnext/requirements.txt" || true
[ -f "$APPS/hrms/requirements.txt" ]    && "$PIP" install -q -r "$APPS/hrms/requirements.txt"    || true

# --- apps.txt: ONLY frappe + erpnext for site creation ---
printf "frappe\nerpnext\n" > "$BENCH/apps.txt"
cp "$BENCH/apps.txt" "$SITES/apps.txt"

# --- Create site if missing (install erpnext during creation) ---
if [ ! -f "$SITE_PATH/site_config.json" ]; then
  echo ">>> Initializing site $SITE_NAME with DB $DB_NAME"
  export DISABLE_MARIADB_SAFE_UPGRADE=$([ "$SKIP_MARIADB_SAFEGUARDS" = "1" ] && echo 1 || echo 0)

  if ! bench new-site "$SITE_NAME" \
      --db-name "$DB_NAME" \
      --db-host "$DB_HOST" --db-port "$DB_PORT" \
      --db-root-username "$DB_ROOT_USER" \
      --mariadb-root-password "$DB_ROOT_PASSWORD" \
      --no-mariadb-socket \
      --admin-password "$ADMIN_PASSWORD" \
      --install-app erpnext \
      --force; then
    echo "new-site failed; continuing (DB may already exist or MariaDB settings differ)."
  fi
else
  echo ">>> Site exists."
fi

# --- Now register HRMS and install it (after site exists) ---
if [ -f "$SITE_PATH/site_config.json" ]; then
  if ! grep -q '^hrms$' "$BENCH/apps.txt"; then
    echo "hrms" >> "$BENCH/apps.txt"
    cp "$BENCH/apps.txt" "$SITES/apps.txt"
  fi
  bench --site "$SITE_NAME" install-app hrms || echo ">>> hrms install failed; continue to build/serve."
fi

# --- Frontend deps then build (fixes 'fast-glob' & friends) ---
if command -v yarn >/dev/null 2>&1; then
  ( cd "$APPS/frappe" && yarn install --network-timeout 600000 ) || true
fi
bench build || true

# --- Serve HTTP ---
export FRAPPE_SITE="$SITE_NAME"
exec "$GUNICORN" -b 0.0.0.0:"$PORT" -w 2 -k gevent --timeout 120 \
  --chdir "$APPS/frappe" frappe.app:application
