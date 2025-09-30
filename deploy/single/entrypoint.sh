#!/usr/bin/env bash
set -euo pipefail

# required env
: "${SITE_NAME:?SITE_NAME not set}"
: "${ADMIN_PASSWORD:?ADMIN_PASSWORD not set}"
: "${DB_HOST:?DB_HOST not set}"
: "${DB_PORT:?DB_PORT not set}"
: "${DB_NAME:?DB_NAME not set}"
: "${DB_USER:?DB_USER not set}"
: "${DB_PASSWORD:?DB_PASSWORD not set}"
: "${PORT:?PORT not set}"

BENCH=/home/frappe/frappe-bench
SITES="$BENCH/sites"
APPS="$BENCH/apps"
SITE_PATH="$SITES/$SITE_NAME"
VENV="$BENCH/env"
PIP="$VENV/bin/pip"
GUNICORN="$VENV/bin/gunicorn"

cd "$BENCH"

# ensure bench context
mkdir -p "$SITES" /home/frappe/redis "$SITE_PATH"
[ -f ./apps.txt ] || : > ./apps.txt
[ -f "$SITES/apps.txt" ] || cp ./apps.txt "$SITES/apps.txt"
echo "$SITE_NAME" > "$SITES/currentsite.txt"

# minimal local redis (no root paths)
REDIS_CFG=/home/frappe/redis/redis.conf
cat > "$REDIS_CFG" <<'EOF'
bind 127.0.0.1
port 6379
protected-mode no
save ""
appendonly no
dir /home/frappe/redis
pidfile /home/frappe/redis/redis.pid
daemonize yes
EOF
pgrep -x redis-server >/dev/null 2>&1 || redis-server "$REDIS_CFG"

# common site config (DB host/port + proper redis URL scheme)
cat > "$SITES/common_site_config.json" <<EOF
{
  "db_host": "$DB_HOST",
  "db_port": "$DB_PORT",
  "redis_cache": "redis://127.0.0.1:6379",
  "redis_queue": "redis://127.0.0.1:6379",
  "redis_socketio": "redis://127.0.0.1:6379"
}
EOF

# clone apps if missing
[ -d "$APPS/erpnext" ] || git clone --depth 1 -b version-15 https://github.com/frappe/erpnext "$APPS/erpnext"
[ -d "$APPS/hrms" ]    || git clone --depth 1 -b version-15 https://github.com/frappe/hrms    "$APPS/hrms"

# install python deps (best effort)
[ -f "$APPS/erpnext/requirements.txt" ] && "$PIP" install -q -r "$APPS/erpnext/requirements.txt" || true
[ -f "$APPS/hrms/requirements.txt" ]    && "$PIP" install -q -r "$APPS/hrms/requirements.txt"    || true

# write/merge site_config.json with Railway DB creds and host mapping
"$VENV/bin/python" - <<'PY' || true
import json, os
site = os.environ["SITE_NAME"]
site_path = f"/home/frappe/frappe-bench/sites/{site}"
cfg_path  = f"{site_path}/site_config.json"
data = {}
if os.path.exists(cfg_path):
    try:
        with open(cfg_path) as f: data = json.load(f)
    except Exception: data = {}
e=os.environ
data.update({
  "db_type": "mariadb",
  "db_name": e["DB_NAME"],
  "db_user": e["DB_USER"],
  "db_password": e["DB_PASSWORD"],
  "db_host": e["DB_HOST"],
  "db_port": e["DB_PORT"]
})
domain = os.environ.get("RAILWAY_PUBLIC_DOMAIN", "")
if domain:
    if not domain.startswith("http"): domain = "https://" + domain
    data["host_name"] = domain
os.makedirs(site_path, exist_ok=True)
with open(cfg_path, "w") as f: json.dump(data, f, indent=2)
PY

# migrate if possible; OK if it fails on first boot (schema not present)
set +e
bench --site "$SITE_NAME" migrate
bench --site "$SITE_NAME" install-app erpnext
bench --site "$SITE_NAME" install-app hrms
set -e

# serve
export FRAPPE_SITE="$SITE_NAME"
exec "$GUNICORN" \
  -b 0.0.0.0:"$PORT" -w 2 -k gevent --timeout 120 \
  --chdir "$BENCH/apps/frappe" \
  frappe.app:application
