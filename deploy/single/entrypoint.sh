#!/usr/bin/env bash
set -euo pipefail

# ===== Required env =====
: "${SITE_NAME:?SITE_NAME not set}"                 # set this to your Railway domain (e.g. extraordinary-grace-production.up.railway.app)
: "${ADMIN_PASSWORD:?ADMIN_PASSWORD not set}"
: "${DB_HOST:?DB_HOST not set}"                     # e.g. mariadb.railway.internal
: "${DB_PORT:?DB_PORT not set}"                     # e.g. 3306
: "${DB_ROOT_USER:?DB_ROOT_USER not set}"           # usually root
: "${DB_ROOT_PASSWORD:?DB_ROOT_PASSWORD not set}"
: "${DB_NAME:?DB_NAME not set}"                     # e.g. ATH_HRMS
: "${PORT:?PORT not set}"                           # Railway provides this

# Optional: if you provisioned Redis on Railway, pass full redis:// URLs.
REDIS_CACHE_URL="${REDIS_CACHE:-}"
REDIS_QUEUE_URL="${REDIS_QUEUE:-}"
REDIS_SOCKETIO_URL="${REDIS_SOCKETIO:-}"

BENCH=/home/frappe/frappe-bench
SITES="$BENCH/sites"
APPS="$BENCH/apps"
SITE_PATH="$SITES/$SITE_NAME"
VENV="$BENCH/env"
PIP="$VENV/bin/pip"
GUNICORN="$VENV/bin/gunicorn"

cd "$BENCH"

# --- Bench context ---
mkdir -p "$SITES"
[ -f ./apps.txt ] || : > ./apps.txt
[ -f "$SITES/apps.txt" ] || cp ./apps.txt "$SITES/apps.txt"
[ -f "$SITES/common_site_config.json" ] || echo '{}' > "$SITES/common_site_config.json"

# Wire Redis only if provided (don’t start local redis in Railway)
if [[ -n "$REDIS_CACHE_URL" || -n "$REDIS_QUEUE_URL" || -n "$REDIS_SOCKETIO_URL" ]]; then
  # Build a small JSON blob with only provided keys
  TMP=$(mktemp)
  echo '{}' > "$TMP"
  python3 - <<PY
import json, os, sys
p="$TMP"
d=json.load(open(p))
if os.getenv("REDIS_CACHE"):    d["redis_cache"]=os.environ["REDIS_CACHE"]
if os.getenv("REDIS_QUEUE"):    d["redis_queue"]=os.environ["REDIS_QUEUE"]
if os.getenv("REDIS_SOCKETIO"): d["redis_socketio"]=os.environ["REDIS_SOCKETIO"]
json.dump(d, open(p,"w"))
PY
  mv "$TMP" "$SITES/common_site_config.json"
fi

# --- Apps (ERPNext only for now; HRMS later once we move to py3.10 base) ---
if [ ! -d "$APPS/erpnext" ]; then
  git clone --depth 1 -b version-15 https://github.com/frappe/erpnext "$APPS/erpnext"
fi

# Install any app-specific Python deps (quietly; don’t fail the boot)
[ -f "$APPS/erpnext/requirements.txt" ] && "$PIP" install -q -r "$APPS/erpnext/requirements.txt" || true

# --- Site init / migrate ---
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
    --force || echo "new-site failed; continuing (DB may already exist or server settings differ)."

  # bind host header so public URL works even if name differs later
  if [ -f "$SITE_PATH/site_config.json" ]; then
    python3 - <<PY
import json,sys
p="$SITE_PATH/site_config.json"
d=json.load(open(p))
d["host_name"]="${SITE_NAME}"
json.dump(d, open(p,"w"))
PY
  fi

  # current site pointer
  echo "$SITE_NAME" > "$SITES/currentsite.txt"
else
  echo ">>> Site exists. Running migrate."
  bench --site "$SITE_NAME" migrate || echo "migrate failed; continuing."
fi

# --- Build frontend assets for frappe (needs yarn) ---
bench build || echo "bench build failed; serving anyway."

# --- Serve HTTP ---
export FRAPPE_SITE="$SITE_NAME"
exec "$GUNICORN" \
  -b 0.0.0.0:"$PORT" -w 2 -k gevent --timeout 120 \
  --chdir "$BENCH/apps/frappe" \
  frappe.app:application
