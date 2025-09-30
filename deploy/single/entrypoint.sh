#!/usr/bin/env bash
set -euo pipefail
cd /home/frappe/frappe-bench

SITES=/home/frappe/frappe-bench/sites
SITE_PATH="$SITES/${SITE_NAME:-site1.local}"

mkdir -p "$SITES"

if [ ! -f "$SITE_PATH/site_config.json" ]; then
  bench new-site "${SITE_NAME:-site1.local}" \
    --mariadb-root-password "$DB_ROOT_PASSWORD" \
    --admin-password "$ADMIN_PASSWORD" \
    --db-host "$DB_HOST" --db-port "$DB_PORT"
  bench --site "${SITE_NAME:-site1.local}" install-app erpnext
  bench --site "${SITE_NAME:-site1.local}" install-app hrms
  bench build
fi

exec bench start
