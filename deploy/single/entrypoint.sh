#!/usr/bin/env bash
set -euo pipefail

# --- Required env ---
: "${SITE_NAME:?SITE_NAME not set}"
: "${ADMIN_PASSWORD:?ADMIN_PASSWORD not set}"
: "${DB_HOST:?DB_HOST not set}"
: "${DB_PORT:?DB_PORT not set}"
: "${DB_ROOT_USER:?DB_ROOT_USER not set}"
: "${DB_ROOT_PASSWORD:?DB_ROOT_PASSWORD not set}"
: "${DB_NAME:?DB_NAME not set}"
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
mkdir -p "$SITES"
[ -f "$SITES/common_site_config.json" ] || echo '{}' > "$SITES/common_site_config.json"

# --- Start local Redis (in-user, no root-only paths) ---
if ! pgrep -x redis-server >/dev/null 2>&1; then
  redis-server --daemonize yes --bind 127.0.0.1 --port 6379 --save "" --appendonly no --dir /home/frappe
fi

# --- Proper Redis URLs (schemed) ---
cat > "$SITES/common_site_config.json" <<EOF
{
  "redis_cache":    "redis://127.0.0.1:6379/0",
  "redis_queue":    "redis://127.0.0.1:6379/1",
  "redis_socketio": "redis://127.0.0.1:6379/2"
}
EOF

# --- Get ERPNext (leave HRMS for after site exists so imports don't run early) ---
[ -d "$APPS/erpnext" ] || git clone --depth 1 -b version-15 https://github.com/frappe/erpnext "$APPS/erpnext"
[ -f "$APPS/erpnext/requirements.txt" ] && "$PIP" install -q -r "$APPS/erpnext/requirements.txt" || true

# apps.txt ONLY frappe+erpnext for site creation
printf "frappe\nerpnext\n" > "$BENCH/apps.txt"
cp "$BENCH/apps.txt" "$SITES/apps.txt"

# --- Create site if missing (installs erpnext on creation) ---
if [ ! -f "$SITE_PATH/site_config.json" ]; then
  echo ">>> Initializing site $SITE_NAME with DB $DB_NAME"
  export DISABLE_MARIADB_SAFE_UPGRADE=$([ "$SKIP_MARIADB_SAFEGUARDS" = "1" ] && echo 1 || echo 0)

  bench new-site "$SITE_NAME" \
    --db-name "$DB_NAME" \
    --db-host "$DB_HOST" --db-port "$DB_PORT" \
    --db-root-username "$DB_ROOT_USER" \
    --mariadb-root-password "$DB_ROOT_PASSWORD" \
    --no-mariadb-socket \
    --admin-password "$ADMIN_PASSWORD" \
    --install-app erpnext \
    --force || echo "new-site failed; continuing (DB may already exist / settings differ)."
else
  echo ">>> Site exists."
fi

# --- Now add HRMS (Python 3.10 is available in this image) ---
if [ -f "$SITE_PATH/site_config.json" ]; then
  if [ ! -d "$APPS/hrms" ]; then
    git clone --depth 1 -b version-15 https://github.com/frappe/hrms "$APPS/hrms"
    [ -f "$APPS/hrms/requirements.txt" ] && "$PIP" install -q -r "$APPS/hrms/requirements.txt" || true
  fi
  if ! grep -q '^hrms$' "$BENCH/apps.txt"; then
    echo "hrms" >> "$BENCH/apps.txt"
    cp "$BENCH/apps.txt" "$SITES/apps.txt"
  fi
  bench --site "$SITE_NAME" install-app hrms || echo ">>> hrms install failed; will still build/serve."
fi

# --- Frontend deps + build ---
if command -v yarn >/dev/null 2>&1; then
  ( cd "$APPS/frappe" && yarn install --network-timeout 600000 ) || true
fi
bench build || true

# --- Serve ---
export FRAPPE_SITE="$SITE_NAME"
exec "$GUNICORN" -b 0.0.0.0:"$PORT" -w 2 -k gevent --timeout 120 \
  --chdir "$APPS/frappe" frappe.app:application
